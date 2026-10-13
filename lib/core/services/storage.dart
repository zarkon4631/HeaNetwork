import 'dart:convert';
import 'dart:io';

import '../models/profile.dart';
import '../models/settings.dart';

/// Everything the app persists, as JSON files in one directory.
class AppStore {
  AppStore(this.dir);

  final Directory dir;

  List<ProxyProfile> profiles = [];
  List<Subscription> subscriptions = [];
  AppSettings settings = AppSettings();
  RoutingSettings routing = RoutingSettings();

  File _file(String name) => File('${dir.path}${Platform.pathSeparator}$name');

  Future<Object?> _read(String name) async {
    final f = _file(name);
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString());
    } on FormatException {
      // A torn write must not brick the app.
      await _setAside(name);
      return null;
    } on FileSystemException {
      return null;
    }
  }

  /// Keeps a file the app cannot use for diagnosis, out of its own way.
  Future<void> _setAside(String name) async {
    final f = _file(name);
    try {
      await f.rename('${f.path}.corrupt');
    } on FileSystemException {
      // It is overwritten by the next save, then.
    }
  }

  /// The records of a list on disk. What is on disk is not always what this
  /// version wrote (another version did, or somebody's editor), so a record
  /// that cannot be read is left out rather than allowed to cost the rest,
  /// let alone the start of the app.
  static List<T> _records<T>(Object? json, T Function(Map<String, dynamic>) parse) {
    final out = <T>[];
    if (json is! List) return out;
    for (final e in json) {
      if (e is! Map) continue;
      try {
        out.add(parse(Map<String, dynamic>.from(e)));
      } on Object {
        // Left out.
      }
    }
    return out;
  }

  /// One object on disk, or null when the file holds something of another
  /// shape; it is then set aside like a torn one and the defaults apply.
  Future<T?> _object<T>(String name, Object? json, T Function(Map<String, dynamic>) parse) async {
    if (json is! Map) return null;
    try {
      return parse(Map<String, dynamic>.from(json));
    } on Object {
      await _setAside(name);
      return null;
    }
  }

  final _queues = <String, Future<void>>{};

  /// Set when the last write of some file failed (disk full, no access).
  Object? lastWriteError;

  /// Writes through a temp file so a crash mid-write leaves the old data.
  ///
  /// Saves of the same file are queued: callers fire them without awaiting,
  /// and two overlapping writes would fight over the temp file. [snapshot]
  /// is taken when the write actually runs, so a queued save stores the
  /// newest state. Never throws; see [lastWriteError].
  Future<void> _write(String name, Object Function() snapshot) {
    final next = (_queues[name] ?? Future<void>.value()).then((_) async {
      try {
        await dir.create(recursive: true);
        final tmp = _file('$name.tmp');
        await tmp.writeAsString(jsonEncode(snapshot()), flush: true);
        await tmp.rename(_file(name).path);
        lastWriteError = null;
      } on FileSystemException catch (e) {
        lastWriteError = e;
      }
    });
    _queues[name] = next;
    return next;
  }

  Future<void> load() async {
    profiles = _records(await _read('profiles.json'), ProxyProfile.fromJson);
    subscriptions = _records(await _read('subscriptions.json'), Subscription.fromJson);
    final st = await _read('settings.json');
    final stored = await _object('settings.json', st, AppSettings.fromJson);
    if (st is Map && stored != null) {
      settings = stored;
      // Up to 1.0.3 a whole subscription could be selected ("auto-select").
      // Such a setting turns into that subscription's fastest known server.
      final auto = st['selectedSubscriptionId'];
      if (auto is String) {
        int rank(ProxyProfile p) {
          final ms = p.latencyMs;
          return ms == null || ms < 0 ? 1 << 30 : ms;
        }

        ProxyProfile? best;
        for (final p in profiles.where((p) => p.subscriptionId == auto)) {
          if (best == null || rank(p) < rank(best)) best = p;
        }
        if (best != null) settings.selectedProfileId = best.id;
      }
    }
    routing = await _object(
            'routing.json', await _read('routing.json'), RoutingSettings.fromJson) ??
        routing;
  }

  Future<void> saveProfiles() =>
      _write('profiles.json', () => profiles.map((e) => e.toJson()).toList());
  Future<void> saveSubscriptions() => _write(
      'subscriptions.json', () => subscriptions.map((e) => e.toJson()).toList());
  Future<void> saveSettings() => _write('settings.json', settings.toJson);
  Future<void> saveRouting() => _write('routing.json', routing.toJson);

  /// Completes when every queued write has hit the disk.
  Future<void> flush() => Future.wait(_queues.values);
}

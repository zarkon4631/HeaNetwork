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
      // A torn write must not brick the app; keep the bad file for diagnosis.
      await f.rename('${f.path}.corrupt');
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
    final p = await _read('profiles.json');
    if (p is List) {
      profiles = p
          .map((e) => ProxyProfile.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    }
    final s = await _read('subscriptions.json');
    if (s is List) {
      subscriptions = s
          .map((e) => Subscription.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList();
    }
    final st = await _read('settings.json');
    if (st is Map) settings = AppSettings.fromJson(Map<String, dynamic>.from(st));
    final r = await _read('routing.json');
    if (r is Map) routing = RoutingSettings.fromJson(Map<String, dynamic>.from(r));
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

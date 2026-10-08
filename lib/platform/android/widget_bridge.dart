import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../core/models/profile.dart';
import '../../core/services/latency_tester.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';

/// Keeps the Android home-screen widget supplied with what it needs to work
/// while the app is closed: the list of configurations, which one is
/// selected, and a ready-to-run core config for each.
///
/// Layout under the app's files directory (read by `HeaWidgetProvider`):
///   `widget/state.json`: list, selection, labels, control port;
///   `widget/configs/ID.json`: the core config of that configuration.
class AndroidWidgetBridge with WidgetsBindingObserver {
  AndroidWidgetBridge(this.state) {
    state.addListener(_onStateChanged);
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  final AppState state;

  /// More than this many servers would mean megabytes of configs rewritten
  /// on every settings change; the widget steps through the first ones.
  static const maxProfiles = 60;
  static const _channel = MethodChannel('hea/core');

  int _exported = -1;
  String? _exportedLocale;
  Timer? _debounce;

  Directory get _dir =>
      Directory('${state.paths.support.path}${Platform.pathSeparator}widget');
  File get _stateFile => File('${_dir.path}${Platform.pathSeparator}state.json');

  void _onStateChanged() {
    // The state notifies every second while connected (traffic); only a
    // changed revision means the configs are stale.
    if (state.configRevision != _exported || state.settings.locale != _exportedLocale) {
      _schedule();
    }
  }

  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), export);
  }

  S get _strings {
    final locale = state.settings.locale;
    final code =
        locale == 'system' ? PlatformDispatcher.instance.locale.languageCode : locale;
    return code == 'ru' ? S.ru : S.en;
  }

  /// The servers the widget offers: what the list shows, in the same order.
  List<ProxyProfile> get _profiles => [
        ...state.profilesOf(null),
        for (final sub in state.subscriptions) ...state.profilesOf(sub.id),
      ].take(maxProfiles).toList();

  Future<void> export() async {
    final revision = state.configRevision;
    final locale = state.settings.locale;
    try {
      final configs = Directory('${_dir.path}${Platform.pathSeparator}configs');
      await configs.create(recursive: true);

      // One control port and secret for every pre-built config, so the app
      // can attach to a core the widget started.
      final clashPort = await freeTcpPort();
      final random = Random.secure();
      final secret =
          List.generate(24, (_) => random.nextInt(16).toRadixString(16)).join();

      final profiles = _profiles;
      final keep = <String>{};
      for (final p in profiles) {
        final file = File('${configs.path}${Platform.pathSeparator}${p.id}.json');
        keep.add(file.path);
        await file.writeAsString(jsonEncode(
            state.configFor([p], clashPort: clashPort, clashSecret: secret)));
      }
      await for (final entry in configs.list()) {
        if (entry is File && !keep.contains(entry.path)) await entry.delete();
      }

      final s = _strings;
      final tmp = File('${_stateFile.path}.tmp');
      await tmp.writeAsString(jsonEncode({
        'profiles': [
          for (final p in profiles) {'id': p.id, 'name': p.name},
        ],
        'selected': state.selectedProfile?.id ?? profiles.firstOrNull?.id,
        'clashPort': clashPort,
        'clashSecret': secret,
        'labels': {
          'connected': s.statusOn,
          'disconnected': s.statusOff,
          'connecting': s.statusConnecting,
          'empty': s.noServerHint,
        },
      }));
      await tmp.rename(_stateFile.path);
      _exported = revision;
      _exportedLocale = locale;
      await _channel.invokeMethod<void>('refreshWidget');
    } on Object {
      // The widget keeps working from the previous export.
    }
  }

  /// Picks up a server chosen with the widget's arrows while the app was in
  /// the background.
  Future<void> adoptSelection() async {
    try {
      final json = jsonDecode(await _stateFile.readAsString()) as Map;
      final id = json['selected'];
      if (id is String &&
          id != state.selectedProfile?.id &&
          state.profiles.any((p) => p.id == id)) {
        state.adoptExternalSelection(id);
      }
    } on Object {
      // Nothing exported yet.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) adoptSelection();
  }

  void dispose() {
    _debounce?.cancel();
    state.removeListener(_onStateChanged);
    WidgetsBinding.instance.removeObserver(this);
  }
}

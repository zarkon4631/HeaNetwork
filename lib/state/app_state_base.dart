import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../core/config/config_builder.dart';
import '../core/models/panel_routing.dart';
import '../core/models/profile.dart';
import '../core/models/settings.dart';
import '../core/services/core_controller.dart';
import '../core/services/device_identity.dart';
import '../core/services/latency_tester.dart';
import '../core/services/public_ip.dart';
import '../core/services/storage.dart';
import '../core/services/updater.dart';
import '../platform/windows/system_proxy.dart';
import '../platform/windows/win32.dart' as win32;
import 'app_paths.dart';

/// Thrown by [AppState.connect] when TUN mode needs administrator rights.
class ElevationRequired implements Exception {}

class ImportOutcome {
  ImportOutcome({
    this.added = 0,
    this.subscription,
    this.errors = const [],
    this.unsupported = const [],
    this.failure,
    this.routing,
  });

  /// Set when the text was a routing link (`happ://routing/...`): the
  /// profile that was imported, or an empty one for "routing off".
  final PanelRouting? routing;
  final int added;
  final Subscription? subscription;

  /// One message per entry that was skipped.
  final List<String> errors;

  /// Those of them that are servers the core cannot connect to.
  final List<SkippedServer> unsupported;

  /// Set when the whole import failed (a subscription could not be loaded).
  final Object? failure;
}

const bundledRuleSets = [ruleSetRuSite, ruleSetRuIp, ruleSetAds];

/// [AppState.error] when there is no server to connect to.
const errorNoServer = 'no-server';

/// [AppState.error] when the core did not come up in time; the number of
/// seconds it was given follows.
const errorStartTimeout = 'start-timeout:';

/// The state and services every facet of [AppState] builds on.
///
/// [AppState] adds five mixins — connection, panel routing, profiles and
/// subscriptions, latency, updates. Whatever one of them needs from another
/// is declared here, as shared state or as an abstract member the facet
/// implements, so the facets stay in separate files without exposing
/// anything more to the rest of the app.
abstract class AppStateBase extends ChangeNotifier {
  AppStateBase({
    required this.store,
    required this.core,
    required this.platform,
    required this.paths,
    required this.appVersion,
    this.systemProxy,
    this.autostart,
    this.device,
    this.httpClient,
    this.tcpProbe,
    this.publicIp,
    this.tunnelCheck,
    bool? elevated,
    Updater? updater,
  })  : elevated = elevated ??
            (platform == CorePlatform.windows && Platform.isWindows
                ? win32.isElevated()
                : false),
        updater = updater ?? Updater();

  final AppStore store;
  final CoreController core;
  final CorePlatform platform;
  final AppPaths paths;
  final String appVersion;
  final SystemProxy? systemProxy;
  final Autostart? autostart;
  final bool elevated;
  final Updater updater;

  /// Who this device says it is to subscription servers; detected at startup
  /// unless supplied.
  DeviceIdentity? device;

  /// Used for subscription requests; tests substitute a fake.
  final http.Client? httpClient;

  /// Opens the TCP connections of the delay test; tests substitute a fake.
  final TcpProbe? tcpProbe;

  /// Learns the address this device is seen under, which subscription
  /// requests then carry; null sends none.
  final PublicIp? publicIp;

  /// Finds out whether the running tunnel takes TCP connections (Windows);
  /// null skips the question.
  final Future<bool> Function()? tunnelCheck;

  bool get isWindows => platform == CorePlatform.windows;

  /// Xray-core ships next to the core (Windows): servers only it can reach,
  /// MASQUE and XDRIVE, are kept instead of skipped.
  bool get xrayAvailable => isWindows && paths.xrayPath != null;
  bool get isAndroid => platform == CorePlatform.android;

  /// A TV: driven by a remote, viewed from across the room.
  bool get isTv => device?.isTv ?? false;

  AppSettings get settings => store.settings;
  RoutingSettings get routing => store.routing;
  List<ProxyProfile> get profiles => store.profiles;
  List<Subscription> get subscriptions => store.subscriptions;

  /// The routing profile in force, if there is one and it is not switched
  /// off; implemented by the routing facet.
  PanelRouting? get panelRouting;

  /// The server a connection uses; implemented by the connection facet.
  ProxyProfile? get selectedProfile;

  /// The servers of one subscription, or of the user's own list for null;
  /// implemented by the connection facet.
  List<ProxyProfile> profilesOf(String? subscriptionId);

  CoreStatus get status => core.status;

  /// Shown on the home screen until the next connection attempt: the core's
  /// own words, or one of the two markers above, which the screen puts into
  /// the user's language.
  String? error;

  /// Bumped whenever something that goes into a core configuration changes
  /// (servers, settings, routing). Lets the Android widget know when the
  /// configurations it starts from are stale.
  int configRevision = 0;

  // ---- facets, implemented by the mixins --------------------------------

  /// The connection facet's listener for the core's state.
  void onCoreChanged();

  /// Tears down what [AppState.init] started; the connection facet's part
  /// of [AppState.dispose].
  void disposeConnection();

  /// Drops the live connection; the connection facet implements it.
  Future<void> disconnect();

  /// Looks for a newer release; the updates facet implements it.
  Future<void> checkForUpdate({bool silent = false});

  /// Background refresh of due subscriptions; the profiles facet implements
  /// it.
  Future<void> refreshDueSubscriptions();

  // ---- what the running core was started with ---------------------------

  /// What the running core was started with, as [coreFingerprint].
  String? appliedFingerprint;

  /// Everything that goes into the core's configuration, as one string.
  String? coreFingerprint() {
    final profile = selectedProfile;
    if (profile == null) return null;
    return jsonEncode(configFor(profile,
        clashPort: 0, clashSecret: '', mixedPort: settings.mixedPort));
  }

  /// The core configuration for connecting through [profile]; the
  /// connection facet implements it.
  Map<String, dynamic> configFor(
    ProxyProfile profile, {
    required int clashPort,
    required String clashSecret,
    int? mixedPort,
    int? xrayPort,
    bool plainRouting = false,
  });

  /// Called after something that may matter to the running core. A
  /// reconnect is asked for only when the configuration really differs
  /// from the one in use: choosing the value that is already set, or
  /// changing a setting and changing it back, asks for nothing.
  void noteCoreChange() {
    final applied = appliedFingerprint;
    pendingRestart = applied == null || coreFingerprint() != applied;
  }

  /// Settings changed while connected; a reconnect applies them.
  bool pendingRestart = false;

  // ---- settings plumbing -------------------------------------------------

  /// Called after something that may matter to the running core.
  void settingsChanged({required bool affectsCore}) {
    if (affectsCore && status != CoreStatus.stopped) noteCoreChange();
    configRevision++;
    unawaited(store.saveSettings());
    notifyListeners();
  }

  /// Mutates settings and persists them. [affectsCore] marks changes that
  /// only take effect after a reconnect.
  void updateSettings(void Function(AppSettings s) change,
      {bool affectsCore = true}) {
    change(settings);
    settingsChanged(affectsCore: affectsCore);
  }

  void updateRouting(void Function(RoutingSettings r) change) {
    change(routing);
    if (status != CoreStatus.stopped) noteCoreChange();
    configRevision++;
    unawaited(store.saveRouting());
    notifyListeners();
  }

  bool get compactView => settings.compactView;

  /// Set by the desktop shell, which resizes the window to match.
  void Function(bool compact)? onCompactViewChanged;

  void setCompactView(bool value) {
    updateSettings((s) => s.compactView = value, affectsCore: false);
    onCompactViewChanged?.call(value);
  }

  void setLaunchAtStartup(bool value) {
    autostart?.set(value);
    updateSettings((s) => s.launchAtStartup = value, affectsCore: false);
  }

  // ---- profiles plumbing -------------------------------------------------

  void profilesChanged() {
    configRevision++;
    unawaited(store.saveProfiles());
    notifyListeners();
  }

  void addProfiles(Iterable<ProxyProfile> list) {
    profiles.addAll(list);
    if (settings.selectedProfileId == null && profiles.isNotEmpty) {
      settings.selectedProfileId = profiles.first.id;
      unawaited(store.saveSettings());
    }
  }

  // ---- rule-sets ----------------------------------------------------------

  /// Lists on this device, by tag: the bundled ones and those fetched for
  /// the routing profiles.
  Set<String> ruleSets = {};

  bool _fetchingRuleSets = false;
  bool _ruleSetsAskedAgain = false;

  /// Loads rule-sets from the app bundle plus the lists fetched earlier.
  Future<void> extractRuleSets() async {
    final available = <String>{};
    try {
      await paths.ruleSets.create(recursive: true);
    } on FileSystemException {
      return;
    }
    for (final tag in bundledRuleSets) {
      final file = File('${paths.ruleSets.path}${Platform.pathSeparator}$tag.srs');
      try {
        final data = await rootBundle.load('assets/rulesets/$tag.srs');
        final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
        if (!file.existsSync() || file.lengthSync() != bytes.length) {
          await file.writeAsBytes(bytes, flush: true);
        }
        available.add(tag);
      } on Object {
        // A build without bundled rule-sets still works; the presets that
        // need them fall back to plain domain rules.
        if (file.existsSync()) available.add(tag);
      }
    }
    // Lists fetched earlier for a panel's routing profile.
    try {
      await for (final e in paths.ruleSets.list()) {
        final name = e.uri.pathSegments.last;
        if (e is File && name.endsWith('.srs')) {
          available.add(name.substring(0, name.length - 4));
        }
      }
    } on FileSystemException {
      // The bundled ones are enough to start with.
    }
    ruleSets = available;
  }

  /// Downloads the site and address lists the routing profiles refer to.
  /// A list that cannot be fetched is simply not applied until it can.
  Future<void> fetchPanelRuleSets() async {
    if (_fetchingRuleSets) {
      // What is wanted may have changed since the round under way began:
      // one more follows it.
      _ruleSetsAskedAgain = true;
      return;
    }
    final wanted = <String>{
      for (final s in subscriptions) ...?s.routing?.ruleSetTags,
      ...?routing.imported?.ruleSetTags,
    }.difference(ruleSets);
    if (wanted.isEmpty) return;
    _fetchingRuleSets = true;
    final client = httpClient ?? http.Client();
    var added = false;
    try {
      await paths.ruleSets.create(recursive: true);
      for (final tag in wanted) {
        try {
          final res = await client
              .get(Uri.parse(PanelRouting.ruleSetUrl(tag)))
              .timeout(const Duration(seconds: 30));
          // Binary rule-sets start with the magic "SRS".
          final b = res.bodyBytes;
          if (res.statusCode != 200 || b.length < 4 || b.length > 32 << 20) continue;
          if (b[0] != 0x53 || b[1] != 0x52 || b[2] != 0x53) continue;
          final file = File('${paths.ruleSets.path}${Platform.pathSeparator}$tag.srs');
          await file.writeAsBytes(b, flush: true);
          ruleSets = {...ruleSets, tag};
          added = true;
        } on Object {
          // Tried again at the next start or subscription refresh.
        }
      }
    } on Object {
      // No folder, no lists.
    } finally {
      if (httpClient == null) client.close();
      _fetchingRuleSets = false;
    }
    if (added) {
      if (status != CoreStatus.stopped && panelRouting != null) noteCoreChange();
      configRevision++;
      notifyListeners();
    }
    if (_ruleSetsAskedAgain) {
      _ruleSetsAskedAgain = false;
      unawaited(fetchPanelRuleSets());
    }
  }

  /// Throws away the lists of sites on disk and gets them again, after the
  /// core could not read one of them.
  Future<void> renewRuleSets() async {
    try {
      await for (final e in paths.ruleSets.list()) {
        if (e is File && e.path.endsWith('.srs')) await e.delete();
      }
    } on FileSystemException {
      // What stays is found out again by the next start.
    }
    await extractRuleSets();
    await fetchPanelRuleSets();
  }

  // ---- lifecycle ----------------------------------------------------------

  bool _disposed = false;

  /// Work started in the background (a download, a measurement) can end
  /// after the state is gone; then there is nobody left to tell.
  @override
  void notifyListeners() {
    if (_disposed) return;
    super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    core.removeListener(onCoreChanged);
    disposeConnection();
    updater.close();
    super.dispose();
  }
}

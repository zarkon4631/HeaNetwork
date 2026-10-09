import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/config/config_builder.dart';
import '../core/models/profile.dart';
import '../core/models/settings.dart';
import '../core/parsers/import_parser.dart';
import '../core/services/clash_api.dart';
import '../core/services/core_controller.dart';
import '../core/services/latency_tester.dart';
import '../core/services/storage.dart';
import '../core/services/subscription_service.dart';
import 'package:http/http.dart' as http;

import '../core/services/device_identity.dart';
import '../core/services/updater.dart';
import '../platform/windows/system_proxy.dart';
import '../platform/windows/win32.dart' as win32;

/// Where the app keeps its files and finds its bundled pieces.
class AppPaths {
  AppPaths({required this.support, this.corePath});

  final Directory support;

  /// Core executable (Windows only).
  final String? corePath;

  Directory get data => Directory('${support.path}${Platform.pathSeparator}data');
  Directory get run => Directory('${support.path}${Platform.pathSeparator}run');
  Directory get ruleSets =>
      Directory('${support.path}${Platform.pathSeparator}rulesets');
  Directory get downloads =>
      Directory('${support.path}${Platform.pathSeparator}downloads');
  File get proxyBackup =>
      File('${run.path}${Platform.pathSeparator}system-proxy.json');
  File get coreLog => File('${run.path}${Platform.pathSeparator}core.log');
}

/// Thrown by [AppState.connect] when TUN mode needs administrator rights.
class ElevationRequired implements Exception {}

class ImportOutcome {
  ImportOutcome({
    this.added = 0,
    this.subscription,
    this.errors = const [],
    this.failure,
  });
  final int added;
  final Subscription? subscription;

  /// One message per entry that was skipped.
  final List<String> errors;

  /// Set when the whole import failed (a subscription could not be loaded).
  final Object? failure;
}

const bundledRuleSets = [ruleSetRuSite, ruleSetRuIp, ruleSetAds];

class AppState extends ChangeNotifier {
  AppState({
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
    bool? elevated,
    Updater? updater,
  })  : elevated = elevated ??
            (platform == CorePlatform.windows && Platform.isWindows
                ? win32.isElevated()
                : false),
        _updater = updater ?? Updater() {
    core.addListener(_onCoreChanged);
  }

  final AppStore store;
  final CoreController core;
  final CorePlatform platform;
  final AppPaths paths;
  final String appVersion;
  final SystemProxy? systemProxy;
  final Autostart? autostart;
  final bool elevated;
  final Updater _updater;

  /// Who this device says it is to subscription servers; detected in [init]
  /// unless supplied.
  DeviceIdentity? device;

  /// Used for subscription requests; tests substitute a fake.
  final http.Client? httpClient;

  /// Opens the TCP connections of the delay test; tests substitute a fake.
  final TcpProbe? tcpProbe;

  bool get isWindows => platform == CorePlatform.windows;
  bool get isAndroid => platform == CorePlatform.android;

  /// A TV: driven by a remote, viewed from across the room.
  bool get isTv => device?.isTv ?? false;

  AppSettings get settings => store.settings;
  RoutingSettings get routing => store.routing;
  List<ProxyProfile> get profiles => store.profiles;
  List<Subscription> get subscriptions => store.subscriptions;

  // ---- connection state -------------------------------------------------

  CoreStatus get status => core.status;
  bool get isConnected => status == CoreStatus.running;
  bool get isBusy =>
      status == CoreStatus.starting || status == CoreStatus.stopping;

  DateTime? connectedSince;
  TrafficSample speed = const TrafficSample(0, 0);
  int totalUp = 0;
  int totalDown = 0;

  /// Shown on the home screen until the next connection attempt.
  String? error;

  /// Settings changed while connected; a reconnect applies them.
  bool pendingRestart = false;

  /// The mode the running core was started in.
  ConnectionMode? activeMode;

  /// In auto-select mode, the server the group currently uses.
  String? autoSelectedProfileId;

  ClashApi? _clash;
  StreamSubscription<TrafficSample>? _trafficSub;
  Timer? _groupTimer;
  Set<String> _ruleSets = {};
  CoreStatus _lastStatus = CoreStatus.stopped;

  // ---- selection --------------------------------------------------------

  Subscription? get autoSubscription {
    final id = settings.selectedSubscriptionId;
    if (id == null) return null;
    return subscriptions.where((s) => s.id == id).firstOrNull;
  }

  ProxyProfile? get selectedProfile {
    if (autoSubscription != null) return null;
    final id = settings.selectedProfileId;
    return profiles.where((p) => p.id == id).firstOrNull ??
        (profiles.isEmpty ? null : profiles.first);
  }

  List<ProxyProfile> profilesOf(String? subscriptionId) =>
      profiles.where((p) => p.subscriptionId == subscriptionId).toList();

  /// The servers a connection would use right now.
  List<ProxyProfile> get connectionProfiles {
    final sub = autoSubscription;
    if (sub != null) return profilesOf(sub.id);
    final p = selectedProfile;
    return p == null ? const [] : [p];
  }

  ProxyProfile? get activeProfile {
    if (autoSubscription == null) return selectedProfile;
    return profiles.where((p) => p.id == autoSelectedProfileId).firstOrNull;
  }

  void selectProfile(String id) {
    settings
      ..selectedProfileId = id
      ..selectedSubscriptionId = null;
    _settingsChanged(affectsCore: true);
  }

  /// Follows a server chosen outside the app (the home-screen widget), which
  /// has already moved the live connection, so no reconnect is pending.
  void adoptExternalSelection(String id) {
    settings
      ..selectedProfileId = id
      ..selectedSubscriptionId = null;
    unawaited(store.saveSettings());
    notifyListeners();
  }

  void selectAuto(String subscriptionId) {
    settings.selectedSubscriptionId = subscriptionId;
    _settingsChanged(affectsCore: true);
  }

  // ---- startup ----------------------------------------------------------

  /// Loads rule-sets from the app bundle, undoes leftovers of a crashed
  /// previous run, and connects if the user asked for that.
  Future<void> init({bool connect = false}) async {
    await _extractRuleSets();
    final c = core;
    if (c is ProcessCoreController) c.killOrphan();
    // A proxy setting that survived the app points at a dead port.
    systemProxy?.restore();
    // A VPN already up (started earlier, or by the widget) is picked up by
    // the status listener, which attaches the statistics to it.
    if (c is AndroidCoreController) await c.sync();
    if ((connect || settings.autoConnect) && status == CoreStatus.stopped) {
      try {
        await this.connect();
      } on ElevationRequired {
        // Never raise a UAC prompt unasked at startup.
      }
    }
    if (settings.checkUpdates) unawaited(checkForUpdate(silent: true));
    // Honour the refresh interval each panel asks for.
    unawaited(refreshDueSubscriptions());
    _subscriptionTimer = Timer.periodic(
        const Duration(minutes: 15), (_) => refreshDueSubscriptions());
  }

  Timer? _subscriptionTimer;

  Future<void> _extractRuleSets() async {
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
    _ruleSets = available;
  }

  // ---- connect / disconnect --------------------------------------------

  static String _newSecret() {
    final r = Random.secure();
    return List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  /// The core configuration for connecting through [using] with the current
  /// settings and routing.
  Map<String, dynamic> configFor(
    List<ProxyProfile> using, {
    required int clashPort,
    required String clashSecret,
    int? mixedPort,
  }) =>
      buildConfig(
        profiles: using,
        settings: settings,
        routing: routing,
        serverDomains: {
          for (final p in profiles)
            if (InternetAddress.tryParse(p.server) == null) p.server,
        },
        env: BuildEnv(
          platform: platform,
          ruleSetDir: paths.ruleSets.path.replaceAll('\\', '/'),
          cacheFile: '${paths.run.path}/cache.db'.replaceAll('\\', '/'),
          clashPort: clashPort,
          clashSecret: clashSecret,
          elevated: elevated,
          corePath: paths.corePath,
          mixedPort: mixedPort,
          ruleSets: _ruleSets,
          logFile: isAndroid ? paths.coreLog.path : null,
        ),
      );

  /// Bumped whenever something that goes into a core configuration changes
  /// (servers, settings, routing). Lets the Android widget know when the
  /// configurations it starts from are stale.
  int configRevision = 0;

  // On Android the VPN can be started by the home-screen widget while the
  // app is closed, so whoever starts it leaves a note on how to reach the
  // running core.
  File get _activeFile => File('${paths.run.path}${Platform.pathSeparator}active.json');

  Future<void> _writeActive(String? profileId, int clashPort, String secret) async {
    try {
      await paths.run.create(recursive: true);
      await _activeFile.writeAsString(jsonEncode(
          {'profileId': profileId, 'clashPort': clashPort, 'clashSecret': secret}));
    } on FileSystemException {
      // Only costs the statistics after an app restart.
    }
  }

  /// Hooks the traffic statistics up to a VPN that was already running when
  /// the app started.
  Future<void> _attachToRunning() async {
    try {
      final note = jsonDecode(await _activeFile.readAsString()) as Map;
      final port = (note['clashPort'] as num?)?.toInt() ?? 0;
      final secret = '${note['clashSecret'] ?? ''}';
      if (port <= 0) return;
      final id = note['profileId'];
      if (id is String && profiles.any((p) => p.id == id)) {
        settings
          ..selectedProfileId = id
          ..selectedSubscriptionId = null;
      }
      activeMode = ConnectionMode.tun;
      _clash = ClashApi(port, secret);
      _startStats(false);
    } on Object {
      // No note or an unreadable one: connected, just without live numbers.
      connectedSince = DateTime.now();
    }
    notifyListeners();
  }

  /// Set while [connect] is at work, including the moment before the core
  /// reports that it is starting.
  DateTime? _connectingSince;

  Future<void> connect() async {
    if (status != CoreStatus.stopped || _connectingSince != null) return;
    error = null;
    final using = connectionProfiles;
    if (using.isEmpty) {
      error = 'no-server';
      notifyListeners();
      return;
    }
    if (isWindows && settings.mode == ConnectionMode.tun && !elevated) {
      throw ElevationRequired();
    }

    _connectingSince = DateTime.now();
    try {
      final mixedPort = await freeTcpPort(settings.mixedPort);
      final clashPort = await freeTcpPort();
      final secret = _newSecret();
      final config = configFor(using,
          clashPort: clashPort, clashSecret: secret, mixedPort: mixedPort);
      pendingRestart = false;
      activeMode = isAndroid ? ConnectionMode.tun : settings.mode;
      _startingHere = true;
      try {
        await core.start(config);
      } finally {
        _startingHere = false;
      }

      if (isWindows && settings.mode == ConnectionMode.systemProxy) {
        systemProxy?.enable(mixedPort);
      }
      if (isAndroid) {
        await _writeActive(using.length == 1 ? using.single.id : null, clashPort, secret);
      }
      _clash = ClashApi(clashPort, secret);
      _startStats(using.length > 1);
    } on CoreCancelled {
      // Called off by the user: nothing went wrong, nothing to report.
      activeMode = null;
    } on CoreStartTimeout catch (e) {
      error = 'start-timeout:${e.limit.inSeconds}';
      activeMode = null;
    } on CoreException catch (e) {
      error = e.message;
      activeMode = null;
    } on Object catch (e) {
      error = '$e';
      activeMode = null;
    } finally {
      _connectingSince = null;
    }
    notifyListeners();
  }

  /// Disconnects, or calls off a connection that is still being set up.
  Future<void> disconnect() async {
    _stopStats();
    systemProxy?.restore();
    await core.stop();
    activeMode = null;
    pendingRestart = false;
    notifyListeners();
  }

  /// A connection is being set up and can be called off.
  bool get canCancel => status == CoreStatus.starting;

  /// What the connect button does: connect, disconnect, or call off a
  /// connection in progress.
  Future<void> toggle() async {
    if (status == CoreStatus.stopped) return connect();
    // The second click of a double click on "connect" lands while it is
    // already starting, and must not undo the first.
    final since = _connectingSince;
    if (status == CoreStatus.starting &&
        since != null &&
        DateTime.now().difference(since) < const Duration(milliseconds: 700)) {
      return;
    }
    return disconnect();
  }

  /// Applies changed settings to a live connection.
  Future<void> reconnect() async {
    if (status != CoreStatus.running) return;
    await disconnect();
    await connect();
  }

  void _startStats(bool autoGroup) {
    connectedSince = DateTime.now();
    totalUp = totalDown = 0;
    speed = const TrafficSample(0, 0);
    _trafficSub = _clash!.traffic().listen((s) {
      speed = s;
      totalUp += s.up;
      totalDown += s.down;
      notifyListeners();
    }, onError: (_) {}, cancelOnError: true);
    if (autoGroup) {
      Future<void> poll() async {
        final now = await _clash?.currentOf(tagProxy);
        final id = now?.startsWith('p-') == true ? now!.substring(2) : null;
        if (id != autoSelectedProfileId) {
          autoSelectedProfileId = id;
          notifyListeners();
        }
      }

      unawaited(poll());
      _groupTimer = Timer.periodic(const Duration(seconds: 10), (_) => poll());
    }
  }

  void _stopStats() {
    _trafficSub?.cancel();
    _trafficSub = null;
    _groupTimer?.cancel();
    _groupTimer = null;
    _clash?.close();
    _clash = null;
    connectedSince = null;
    autoSelectedProfileId = null;
    speed = const TrafficSample(0, 0);
  }

  /// True while [connect] itself is bringing the core up, as opposed to the
  /// home-screen widget doing so behind the app's back.
  bool _startingHere = false;

  void _onCoreChanged() {
    final now = core.status;
    if (isAndroid &&
        now == CoreStatus.running &&
        _lastStatus != CoreStatus.running &&
        !_startingHere) {
      // Started or switched by the widget: follow it.
      _stopStats();
      unawaited(_attachToRunning());
    }
    if (_lastStatus == CoreStatus.running && now == CoreStatus.stopped) {
      // The core died under us: do not leave the system pointing at it.
      _stopStats();
      systemProxy?.restore();
      activeMode = null;
      if (core.lastError != null) error = core.lastError;
    }
    _lastStatus = now;
    notifyListeners();
  }

  /// The folder holding the core's log files, where they are kept on disk
  /// (Windows: `core.log` for this run, `core.prev.log` for the one before).
  String? get coreLogDirectory =>
      core is ProcessCoreController ? paths.run.path : null;

  void openCoreLogDirectory() {
    final dir = coreLogDirectory;
    if (dir != null && Platform.isWindows) win32.shellExecute(dir);
  }

  /// Delay of the live connection, measured through the running core.
  Future<int?> measureActiveDelay() async =>
      await _clash?.delay(tagProxy, url: urlTestTarget);

  // ---- settings ---------------------------------------------------------

  void _settingsChanged({required bool affectsCore}) {
    if (affectsCore && status != CoreStatus.stopped) pendingRestart = true;
    configRevision++;
    unawaited(store.saveSettings());
    notifyListeners();
  }

  /// Mutates settings and persists them. [affectsCore] marks changes that
  /// only take effect after a reconnect.
  void updateSettings(void Function(AppSettings s) change,
      {bool affectsCore = true}) {
    change(settings);
    _settingsChanged(affectsCore: affectsCore);
  }

  void updateRouting(void Function(RoutingSettings r) change) {
    change(routing);
    if (status != CoreStatus.stopped) pendingRestart = true;
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

  // ---- profiles and subscriptions --------------------------------------

  void _profilesChanged() {
    configRevision++;
    unawaited(store.saveProfiles());
    notifyListeners();
  }

  void _addProfiles(Iterable<ProxyProfile> list) {
    profiles.addAll(list);
    if (settings.selectedProfileId == null &&
        settings.selectedSubscriptionId == null &&
        profiles.isNotEmpty) {
      settings.selectedProfileId = profiles.first.id;
      unawaited(store.saveSettings());
    }
  }

  /// Imports whatever [text] holds: links, a config file, or a
  /// subscription URL (which is fetched right away).
  Future<ImportOutcome> importText(String text) async {
    final parsed = parseImportText(text);
    if (parsed.subscriptionUrl != null) {
      try {
        final sub = await addSubscription(parsed.subscriptionUrl!);
        return ImportOutcome(added: profilesOf(sub.id).length, subscription: sub);
      } on Object catch (e) {
        return ImportOutcome(failure: e);
      }
    }
    if (parsed.profiles.isNotEmpty) {
      _addProfiles(parsed.profiles);
      _profilesChanged();
    }
    return ImportOutcome(added: parsed.profiles.length, errors: parsed.errors);
  }

  void addProfile(ProxyProfile p) {
    _addProfiles([p]);
    _profilesChanged();
  }

  void renameProfile(ProxyProfile p, String name) {
    p.name = name;
    _profilesChanged();
  }

  void replaceOutbound(ProxyProfile p, Map<String, dynamic> outbound) {
    p.outbound = outbound;
    if (status != CoreStatus.stopped) pendingRestart = true;
    _profilesChanged();
  }

  void deleteProfile(ProxyProfile p) {
    profiles.remove(p);
    if (settings.selectedProfileId == p.id) {
      settings.selectedProfileId = profiles.isEmpty ? null : profiles.first.id;
      unawaited(store.saveSettings());
    }
    _profilesChanged();
  }

  Future<SubscriptionResult> _fetch(String url) => fetchSubscription(
        url,
        client: httpClient,
        userAgent: 'HeaNetwork/$appVersion',
        deviceHeaders:
            settings.sendHwid ? (device?.headers ?? const {}) : const {},
      );

  Future<Subscription> addSubscription(String url, {String? name}) async {
    final sub = Subscription(name: name ?? '', url: url.trim());
    final result = await _fetch(sub.url);
    _applySubscription(sub, result);
    if (sub.name.isEmpty) {
      sub.name = result.title ?? Uri.tryParse(sub.url)?.host ?? sub.url;
    }
    subscriptions.add(sub);
    unawaited(store.saveSubscriptions());
    _profilesChanged();
    return sub;
  }

  Future<void> refreshSubscription(Subscription sub) async {
    final result = await _fetch(sub.url);
    _applySubscription(sub, result);
    unawaited(store.saveSubscriptions());
    _profilesChanged();
  }

  bool refreshingSubscriptions = false;

  /// Reloads every subscription. Returns one message per failure, prefixed
  /// with the subscription's name.
  Future<List<SubscriptionException>> refreshAllSubscriptions(
      {bool onlyDue = false}) async {
    if (refreshingSubscriptions) return const [];
    final now = DateTime.now();
    final targets =
        subscriptions.where((s) => !onlyDue || s.isDue(now)).toList();
    if (targets.isEmpty) return const [];
    refreshingSubscriptions = true;
    notifyListeners();
    final failures = <SubscriptionException>[];
    try {
      for (final sub in targets) {
        try {
          await refreshSubscription(sub);
        } on SubscriptionException catch (e) {
          failures.add(SubscriptionException('${sub.name}: ${e.message}', code: e.code));
        } on Object catch (e) {
          failures.add(SubscriptionException('${sub.name}: $e'));
        }
      }
    } finally {
      refreshingSubscriptions = false;
      notifyListeners();
    }
    return failures;
  }

  /// Background refresh of subscriptions whose panel-requested interval has
  /// passed. Failures are ignored: the next tick tries again.
  Future<void> refreshDueSubscriptions() => refreshAllSubscriptions(onlyDue: true);

  static String _fingerprint(ProxyProfile p) => jsonEncode(p.outbound);

  void _applySubscription(Subscription sub, SubscriptionResult result) {
    final old = profilesOf(sub.id);
    final activeBefore = activeProfile;
    final activeFingerprint =
        activeBefore == null ? null : _fingerprint(activeBefore);

    // A server that is still in the list keeps its identity, so the
    // selection, its measured delay and anything else keyed by id survive.
    final unmatched = List.of(old);
    final fresh = <ProxyProfile>[];
    for (final p in result.profiles) {
      final index = unmatched
          .indexWhere((o) => o.name == p.name && o.server == p.server && o.type == p.type);
      final before = index < 0 ? null : unmatched.removeAt(index);
      fresh.add(ProxyProfile(
        id: before?.id,
        name: p.name,
        type: p.type,
        outbound: p.outbound,
        link: p.link,
        subscriptionId: sub.id,
        latencyMs: before?.latencyMs,
      ));
    }

    final selectedGone = unmatched.any((o) => o.id == settings.selectedProfileId);
    profiles.removeWhere((p) => p.subscriptionId == sub.id);
    _addProfiles(fresh);
    if (selectedGone) {
      settings.selectedProfileId = (fresh.firstOrNull ?? profiles.firstOrNull)?.id;
      unawaited(store.saveSettings());
    }

    sub
      ..updatedAt = DateTime.now()
      ..uploadBytes = result.upload
      ..downloadBytes = result.download
      ..totalBytes = result.total
      ..expireAt = result.expire
      ..updateIntervalHours = result.updateIntervalHours
      ..supportUrl = result.supportUrl
      ..webPageUrl = result.webPageUrl
      ..announce = result.announce;

    // Only bother the user about reconnecting when the server in use
    // actually changed; a routine refresh must not nag.
    if (status != CoreStatus.stopped) {
      final activeAfter = activeProfile;
      final changed = autoSubscription?.id == sub.id ||
          (activeBefore?.subscriptionId == sub.id &&
              (activeAfter == null || _fingerprint(activeAfter) != activeFingerprint));
      if (changed) pendingRestart = true;
    }
  }

  /// Folds or unfolds a group of the list: [sub], or the user's own servers
  /// when it is null.
  void toggleCollapsed(Subscription? sub) {
    if (sub == null) {
      settings.ownServersCollapsed = !settings.ownServersCollapsed;
      unawaited(store.saveSettings());
    } else {
      sub.collapsed = !sub.collapsed;
      unawaited(store.saveSubscriptions());
    }
    notifyListeners();
  }

  void renameSubscription(Subscription sub, String name) {
    sub.name = name;
    unawaited(store.saveSubscriptions());
    notifyListeners();
  }

  void deleteSubscription(Subscription sub) {
    profiles.removeWhere((p) => p.subscriptionId == sub.id);
    subscriptions.remove(sub);
    if (settings.selectedSubscriptionId == sub.id) {
      settings.selectedSubscriptionId = null;
    }
    if (!profiles.any((p) => p.id == settings.selectedProfileId)) {
      settings.selectedProfileId = profiles.firstOrNull?.id;
    }
    unawaited(store.saveSettings());
    unawaited(store.saveSubscriptions());
    _profilesChanged();
  }

  // ---- latency ----------------------------------------------------------

  bool testingLatency = false;

  TcpProbe _platformTcpProbe() {
    if (isAndroid) return androidTcpProbe;
    // Looked up once per run: the adapter does not change within seconds.
    final source = isWindows && Platform.isWindows ? win32.defaultRouteAddress() : null;
    return (host, port, timeout) =>
        dartTcpProbe(host, port, timeout, sourceAddress: source);
  }

  Future<void> testLatency([List<ProxyProfile>? only]) async {
    if (testingLatency) return;
    final targets = List.of(only ?? profiles);
    if (targets.isEmpty) return;
    testingLatency = true;
    for (final p in targets) {
      p.latencyMs = null;
    }
    notifyListeners();
    try {
      // Only Windows ships a core that can be run a second time on the side.
      final corePath = paths.corePath;
      final UrlTest? urlTest = isWindows && corePath != null
          ? (list, onResult) => LatencyTester(corePath: corePath, workDir: paths.run)
              .test(list, antiDpi: settings.antiDpi, elevated: elevated, onResult: onResult)
          : null;
      await measureLatency(
        targets,
        mode: settings.pingMode,
        tcp: tcpProbe ?? _platformTcpProbe(),
        urlTest: urlTest,
        onResult: (p, ms) {
          p.latencyMs = ms;
          notifyListeners();
        },
      );
    } on Object catch (e) {
      error = '$e';
    } finally {
      testingLatency = false;
      unawaited(store.saveProfiles());
      notifyListeners();
    }
  }

  // ---- updates ----------------------------------------------------------

  ReleaseInfo? availableUpdate;
  bool checkingUpdate = false;
  double? updateProgress;
  String? updateError;

  /// The last check reached GitHub, so "no update" really means up to date.
  bool lastUpdateCheckOk = false;

  static const _installChannel = MethodChannel('hea/core');

  Future<List<String>> _assetSuffixes() async {
    if (isWindows) {
      // Only a copy that the installer put there can be updated by running
      // the installer again; a portable copy just links to the release page.
      final sep = Platform.pathSeparator;
      final uninstaller =
          '${File(Platform.resolvedExecutable).parent.path}${sep}unins000.exe';
      return File(uninstaller).existsSync()
          ? const ['windows-x64-setup.exe']
          : const [];
    }
    try {
      final abi = await _installChannel.invokeMethod<String>('abi');
      return [if (abi != null) 'android-$abi.apk', 'android-universal.apk'];
    } on Object {
      return const ['android-universal.apk'];
    }
  }

  /// Looks for a newer release. With [silent] set, failures are swallowed
  /// (the periodic background check must not nag about being offline).
  Future<void> checkForUpdate({bool silent = false}) async {
    if (checkingUpdate) return;
    checkingUpdate = true;
    updateError = null;
    notifyListeners();
    try {
      availableUpdate = await _updater.check(appVersion,
          assetSuffixes: await _assetSuffixes());
      lastUpdateCheckOk = true;
    } on Object catch (e) {
      lastUpdateCheckOk = false;
      if (!silent) updateError = '$e';
    } finally {
      checkingUpdate = false;
      notifyListeners();
    }
  }

  /// Downloads the update, verifies it and hands it to the OS installer.
  /// On Windows the app exits so the installer can replace its files.
  Future<void> installUpdate() async {
    final release = availableUpdate;
    if (release == null || !release.canInstall || updateProgress != null) return;
    updateError = null;
    updateProgress = 0;
    notifyListeners();
    try {
      final file = await _updater.download(release, paths.downloads,
          onProgress: (p) {
        updateProgress = p;
        notifyListeners();
      });
      if (isWindows) {
        await disconnect();
        await store.flush();
        if (!win32.shellExecute(file.path, args: '/SILENT /RELAUNCH=1')) {
          throw UpdateException('could not start the installer');
        }
        exit(0);
      } else {
        await _installChannel.invokeMethod<void>('installApk', {'path': file.path});
      }
    } on Object catch (e) {
      updateError = '$e';
    } finally {
      updateProgress = null;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    core.removeListener(_onCoreChanged);
    _subscriptionTimer?.cancel();
    _stopStats();
    _updater.close();
    super.dispose();
  }
}

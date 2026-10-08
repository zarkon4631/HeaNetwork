import 'dart:async';
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
  ImportOutcome({this.added = 0, this.subscription, this.errors = const []});
  final int added;
  final Subscription? subscription;
  final List<String> errors;
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

  bool get isWindows => platform == CorePlatform.windows;
  bool get isAndroid => platform == CorePlatform.android;

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
    if (c is AndroidCoreController) {
      await c.sync();
      if (c.status == CoreStatus.running) connectedSince = DateTime.now();
    }
    if ((connect || settings.autoConnect) && status == CoreStatus.stopped) {
      try {
        await this.connect();
      } on ElevationRequired {
        // Never raise a UAC prompt unasked at startup.
      }
    }
    if (settings.checkUpdates) unawaited(checkForUpdate(silent: true));
  }

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

  Future<void> connect() async {
    if (status != CoreStatus.stopped) return;
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

    try {
      final mixedPort = await freeTcpPort(settings.mixedPort);
      final clashPort = await freeTcpPort();
      final secret = _newSecret();
      final config = buildConfig(
        profiles: using,
        settings: settings,
        routing: routing,
        env: BuildEnv(
          platform: platform,
          ruleSetDir: paths.ruleSets.path.replaceAll('\\', '/'),
          cacheFile: '${paths.run.path}/cache.db'.replaceAll('\\', '/'),
          clashPort: clashPort,
          clashSecret: secret,
          elevated: elevated,
          corePath: paths.corePath,
          mixedPort: mixedPort,
          ruleSets: _ruleSets,
          logFile: isAndroid ? paths.coreLog.path : null,
        ),
      );
      pendingRestart = false;
      activeMode = isAndroid ? ConnectionMode.tun : settings.mode;
      await core.start(config);

      if (isWindows && settings.mode == ConnectionMode.systemProxy) {
        systemProxy?.enable(mixedPort);
      }
      _clash = ClashApi(clashPort, secret);
      _startStats(using.length > 1);
    } on CoreException catch (e) {
      error = e.message;
      activeMode = null;
    } on Object catch (e) {
      error = '$e';
      activeMode = null;
    }
    notifyListeners();
  }

  Future<void> disconnect() async {
    _stopStats();
    systemProxy?.restore();
    await core.stop();
    activeMode = null;
    pendingRestart = false;
    notifyListeners();
  }

  Future<void> toggle() =>
      status == CoreStatus.stopped ? connect() : disconnect();

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

  void _onCoreChanged() {
    final now = core.status;
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

  /// Delay of the live connection, measured through the running core.
  Future<int?> measureActiveDelay() async =>
      await _clash?.delay(tagProxy, url: urlTestTarget);

  // ---- settings ---------------------------------------------------------

  void _settingsChanged({required bool affectsCore}) {
    if (affectsCore && status != CoreStatus.stopped) pendingRestart = true;
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
    unawaited(store.saveRouting());
    notifyListeners();
  }

  void setLaunchAtStartup(bool value) {
    autostart?.set(value);
    updateSettings((s) => s.launchAtStartup = value, affectsCore: false);
  }

  // ---- profiles and subscriptions --------------------------------------

  void _profilesChanged() {
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
      } on SubscriptionException catch (e) {
        return ImportOutcome(errors: [e.message]);
      } on Object catch (e) {
        return ImportOutcome(errors: ['$e']);
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

  Future<Subscription> addSubscription(String url, {String? name}) async {
    final sub = Subscription(name: name ?? '', url: url.trim());
    final result = await fetchSubscription(sub.url, userAgent: 'HeaNetwork/$appVersion');
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
    final result = await fetchSubscription(sub.url, userAgent: 'HeaNetwork/$appVersion');
    _applySubscription(sub, result);
    unawaited(store.saveSubscriptions());
    _profilesChanged();
  }

  void _applySubscription(Subscription sub, SubscriptionResult result) {
    final old = profilesOf(sub.id);
    final selected = old.where((p) => p.id == settings.selectedProfileId).firstOrNull;
    profiles.removeWhere((p) => p.subscriptionId == sub.id);
    for (final p in result.profiles) {
      p.subscriptionId = sub.id;
      // Keep the measured delay of servers that are still in the list.
      final before = old.where((o) => o.name == p.name && o.server == p.server);
      if (before.isNotEmpty) p.latencyMs = before.first.latencyMs;
    }
    _addProfiles(result.profiles);
    if (selected != null) {
      // The selected server got a new id; follow it by name.
      final again = result.profiles
          .where((p) => p.name == selected.name && p.server == selected.server)
          .firstOrNull;
      settings.selectedProfileId =
          (again ?? result.profiles.firstOrNull ?? profiles.firstOrNull)?.id;
      unawaited(store.saveSettings());
    }
    sub
      ..updatedAt = DateTime.now()
      ..uploadBytes = result.upload
      ..downloadBytes = result.download
      ..totalBytes = result.total
      ..expireAt = result.expire;
    if (status != CoreStatus.stopped) pendingRestart = true;
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
      final corePath = paths.corePath;
      if (isWindows && corePath != null) {
        await LatencyTester(corePath: corePath, workDir: paths.run).test(
          targets,
          antiDpi: settings.antiDpi,
          elevated: elevated,
          onResult: (p, ms) {
            p.latencyMs = ms;
            notifyListeners();
          },
        );
      } else {
        // Without a spare core, fall back to a TCP connect probe.
        await Future.wait(targets.map((p) async {
          p.latencyMs = await tcpPing(p);
          notifyListeners();
        }));
      }
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
    if (isWindows) return const ['windows-x64-setup.exe'];
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
    _stopStats();
    _updater.close();
    super.dispose();
  }
}

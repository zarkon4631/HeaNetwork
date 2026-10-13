import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../core/config/config_builder.dart';
import '../core/config/rule_values.dart';
import '../core/models/panel_routing.dart';
import '../core/models/profile.dart';
import '../core/models/settings.dart';
import '../core/parsers/import_parser.dart';
import '../core/services/clash_api.dart';
import '../core/services/core_controller.dart';
import '../core/services/latency_tester.dart';
import '../core/services/public_ip.dart';
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

/// How much of a session's traffic went through the VPN and how much went
/// out directly, plus how many connections are open now.
class RouteTraffic {
  const RouteTraffic({
    this.vpnUp = 0,
    this.vpnDown = 0,
    this.directUp = 0,
    this.directDown = 0,
    this.open = 0,
  });

  final int vpnUp;
  final int vpnDown;
  final int directUp;
  final int directDown;
  final int open;

  int get vpn => vpnUp + vpnDown;
  int get direct => directUp + directDown;

  /// Adds what the [connections] carried since they were last [seen], and
  /// updates [seen]. A connection goes "direct" when its chain ends at the
  /// direct outbound, otherwise through the VPN.
  RouteTraffic add(
    List<({String id, List<String> chains, int up, int down})> connections,
    Map<String, (int up, int down)> seen,
  ) {
    var vu = vpnUp, vd = vpnDown, du = directUp, dd = directDown;
    final alive = <String>{};
    for (final c in connections) {
      alive.add(c.id);
      final before = seen[c.id] ?? (0, 0);
      final up = c.up > before.$1 ? c.up - before.$1 : 0;
      final down = c.down > before.$2 ? c.down - before.$2 : 0;
      seen[c.id] = (c.up, c.down);
      if (c.chains.contains('direct')) {
        du += up;
        dd += down;
      } else {
        vu += up;
        vd += down;
      }
    }
    seen.removeWhere((id, _) => !alive.contains(id));
    return RouteTraffic(
        vpnUp: vu, vpnDown: vd, directUp: du, directDown: dd, open: connections.length);
  }
}

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
    this.publicIp,
    this.tunnelCheck,
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

  /// Learns the address this device is seen under, which subscription
  /// requests then carry; null sends none.
  final PublicIp? publicIp;

  /// Finds out whether the running tunnel takes TCP connections (Windows);
  /// null skips the question.
  final Future<bool> Function()? tunnelCheck;

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

  /// Why this connection was made without the site rules and the panel's
  /// routing, in the core's words; null while they are in force.
  String? routingProblem;

  /// This connection found the tunnel taking nothing on the configured
  /// network stack and moved to gVisor, which is now the setting.
  bool stackSwitched = false;

  /// Settings changed while connected; a reconnect applies them.
  bool pendingRestart = false;

  /// The mode the running core was started in.
  ConnectionMode? activeMode;

  ClashApi? _clash;
  StreamSubscription<TrafficSample>? _trafficSub;
  Set<String> _ruleSets = {};
  CoreStatus _lastStatus = CoreStatus.stopped;

  // ---- selection --------------------------------------------------------

  /// The server a connection uses.
  ProxyProfile? get selectedProfile {
    final id = settings.selectedProfileId;
    return profiles.where((p) => p.id == id).firstOrNull ??
        (profiles.isEmpty ? null : profiles.first);
  }

  List<ProxyProfile> profilesOf(String? subscriptionId) =>
      profiles.where((p) => p.subscriptionId == subscriptionId).toList();

  void selectProfile(String id) {
    settings.selectedProfileId = id;
    _settingsChanged(affectsCore: true);
  }

  /// Follows a server chosen outside the app (the home-screen widget), which
  /// has already moved the live connection, so no reconnect is pending.
  void adoptExternalSelection(String id) {
    settings.selectedProfileId = id;
    unawaited(store.saveSettings());
    notifyListeners();
  }

  // ---- startup ----------------------------------------------------------

  /// Loads rule-sets from the app bundle, undoes leftovers of a crashed
  /// previous run, and connects if the user asked for that.
  Future<void> init({bool connect = false}) async {
    await _extractRuleSets();
    if (routing.seedDefaults(
        windows: isWindows, exists: (path) => File(path).existsSync())) {
      unawaited(store.saveRouting());
    }
    unawaited(_fetchPanelRuleSets());
    final c = core;
    if (c is ProcessCoreController) c.killOrphan();
    // A proxy setting that survived the app points at a dead port.
    _restoreProxy();
    // A VPN already up (started earlier, by the widget or by the quick
    // settings tile) is picked up by the status listener, which attaches the
    // statistics to it.
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
    _ruleSets = available;
  }

  // ---- routing from the panel ------------------------------------------

  /// The routing profile in force: the one the selected server's
  /// subscription came with, else one imported from a link; null when the
  /// user switched this off or there is none.
  PanelRouting? get panelRouting {
    if (!routing.usePanelRouting) return null;
    return availablePanelRouting;
  }

  /// The same, whether or not it is switched on.
  PanelRouting? get availablePanelRouting {
    final subId = selectedProfile?.subscriptionId;
    final fromSub =
        subscriptions.where((s) => s.id == subId).firstOrNull?.routing;
    return fromSub ?? routing.imported;
  }

  /// True when [availablePanelRouting] came with the subscription rather
  /// than from a link the user added.
  bool get panelRoutingFromSubscription {
    final subId = selectedProfile?.subscriptionId;
    return subscriptions.where((s) => s.id == subId).firstOrNull?.routing != null;
  }

  /// Lists a routing profile names that are not on this device yet.
  Set<String> get missingPanelRuleSets =>
      (availablePanelRouting?.ruleSetTags ?? const <String>{}).difference(_ruleSets);

  bool _fetchingRuleSets = false;

  /// Downloads the site and address lists the routing profiles refer to.
  /// A list that cannot be fetched is simply not applied until it can.
  Future<void> _fetchPanelRuleSets() async {
    if (_fetchingRuleSets) return;
    final wanted = <String>{
      for (final s in subscriptions) ...?s.routing?.ruleSetTags,
      ...?routing.imported?.ruleSetTags,
    }.difference(_ruleSets);
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
          _ruleSets = {..._ruleSets, tag};
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
      if (status != CoreStatus.stopped && panelRouting != null) _noteCoreChange();
      configRevision++;
      notifyListeners();
    }
  }

  /// Unfolds or folds the list of executables of a group rule. Only how the
  /// page looks: nothing about the connection changes.
  void toggleAppExpanded(AppRule rule) {
    rule.expanded = !rule.expanded;
    unawaited(store.saveRouting());
    notifyListeners();
  }

  void setUsePanelRouting(bool value) =>
      updateRouting((r) => r.usePanelRouting = value);

  /// Forgets a routing profile that was imported from a link.
  void removeImportedRouting() => updateRouting((r) => r.imported = null);

  // ---- connect / disconnect --------------------------------------------

  static String _newSecret() {
    final r = Random.secure();
    return List.generate(24, (_) => r.nextInt(16).toRadixString(16)).join();
  }

  /// The core configuration for connecting through [profile] with the
  /// current settings and routing.
  ///
  /// With [plainRouting] the site rules, the panel's profile and every list
  /// of sites are left out. What remains cannot be malformed, so the core
  /// starts on it whatever state the rules are in.
  Map<String, dynamic> configFor(
    ProxyProfile profile, {
    required int clashPort,
    required String clashSecret,
    int? mixedPort,
    bool plainRouting = false,
  }) =>
      buildConfig(
        profile: profile,
        settings: settings,
        routing: plainRouting
            ? (RoutingSettings.fromJson(routing.toJson())..domains = [])
            : routing,
        panel: plainRouting ? null : panelRouting,
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
          ruleSets: plainRouting ? const {} : _ruleSets,
          logFile: isAndroid ? paths.coreLog.path : null,
        ),
      );

  /// Bumped whenever something that goes into a core configuration changes
  /// (servers, settings, routing). Lets the Android widget know when the
  /// configurations it starts from are stale.
  int configRevision = 0;

  // On Android the VPN can be started by the home-screen widget or the quick
  // settings tile while the app is closed, so whoever starts it leaves a note
  // on how to reach the running core.
  File get _activeFile => File('${paths.run.path}${Platform.pathSeparator}active.json');

  Future<void> _writeActive(String profileId, int clashPort, String secret) async {
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
        settings.selectedProfileId = id;
      }
      activeMode = ConnectionMode.tun;
      _clash = ClashApi(port, secret);
      _startStats();
    } on Object {
      // No note or an unreadable one: connected, just without live numbers.
      connectedSince = DateTime.now();
    }
    notifyListeners();
  }

  /// Set while [connect] is at work, including the moment before the core
  /// reports that it is starting.
  DateTime? _connectingSince;

  /// VPN mode on Windows cannot be started by a copy of the app that is not
  /// running as administrator.
  bool get _needsElevation =>
      isWindows && settings.mode == ConnectionMode.tun && !elevated;

  Future<void> connect() async {
    if (status != CoreStatus.stopped || _connectingSince != null) return;
    error = null;
    final profile = selectedProfile;
    if (profile == null) {
      error = 'no-server';
      notifyListeners();
      return;
    }
    if (_needsElevation) throw ElevationRequired();

    _connectingSince = DateTime.now();
    var connected = false;
    try {
      final mixedPort = await freeTcpPort(settings.mixedPort);
      final clashPort = await freeTcpPort();
      final secret = _newSecret();
      final config = configFor(profile,
          clashPort: clashPort, clashSecret: secret, mixedPort: mixedPort);
      pendingRestart = false;
      _appliedFingerprint = _coreFingerprint();
      activeMode = isAndroid ? ConnectionMode.tun : settings.mode;
      _startingHere = true;
      try {
        try {
          await core.start(config);
          routingProblem = null;
        } on CoreException catch (e) {
          if (!isRoutingComplaint(e.message)) rethrow;
          // The core will not start on these rules. A connection without
          // them beats no connection at all: go on with what cannot be
          // malformed, and say so.
          routingProblem = e.message;
          if (e.message.contains('rule-set')) unawaited(_renewRuleSets());
          try {
            await core.start(configFor(profile,
                clashPort: clashPort,
                clashSecret: secret,
                mixedPort: mixedPort,
                plainRouting: true));
          } on Object {
            routingProblem = null;
            rethrow;
          }
        }
      } finally {
        _startingHere = false;
      }

      stackSwitched = false;
      if (await _tunnelTakesNothing()) {
        // The tunnel's default stack hands every TCP connection to Windows
        // as an incoming one, and a firewall that blocks incoming
        // connections (Portmaster does by default) then lets none through:
        // connected, and nothing works. gVisor needs nothing from the
        // system, so the core is started again on it.
        final configured = settings.tunStack;
        settings.tunStack = 'gvisor';
        var better = false;
        try {
          await core.stop();
          activeMode = settings.mode;
          _startingHere = true;
          try {
            await core.start(configFor(profile,
                clashPort: clashPort,
                clashSecret: secret,
                mixedPort: mixedPort,
                plainRouting: routingProblem != null));
          } finally {
            _startingHere = false;
          }
          better = await tunnelCheck!();
        } finally {
          // Kept only when it helped; otherwise the choice stays the user's.
          if (!better) settings.tunStack = configured;
          _appliedFingerprint = _coreFingerprint();
        }
        if (better) {
          stackSwitched = true;
          configRevision++;
          unawaited(store.saveSettings());
        }
      }

      if (isWindows && settings.mode == ConnectionMode.systemProxy) {
        systemProxy?.enable(mixedPort);
      }
      if (isAndroid) await _writeActive(profile.id, clashPort, secret);
      _clash = ClashApi(clashPort, secret);
      _startStats();
      connected = true;
    } on CoreCancelled {
      // Called off by the user: nothing went wrong, nothing to report.
    } on CoreStartTimeout catch (e) {
      error = 'start-timeout:${e.limit.inSeconds}';
    } on CoreException catch (e) {
      error = e.message;
    } on Object catch (e) {
      error = '$e';
    } finally {
      _connectingSince = null;
    }
    if (!connected) {
      activeMode = null;
      // The core came up and a later step failed: it does not stay up behind
      // the error, with the system half pointed at it.
      if (status == CoreStatus.running) await _abandon();
    }
    notifyListeners();
  }

  /// Takes down a connection that was only half made.
  Future<void> _abandon() async {
    _stopStats();
    _restoreProxy();
    try {
      await core.stop();
    } on Object {
      // The core says for itself whether it is still up.
    }
  }

  /// Puts the system's proxy setting back. Failing at that must not get in
  /// the way of what it is a part of (stopping the core, starting the app):
  /// the backup stays where it is, and the next launch tries again.
  void _restoreProxy() {
    try {
      systemProxy?.restore();
    } on Object {
      // See above.
    }
  }

  /// True when the core runs a tunnel on a stack that depends on Windows
  /// accepting connections, and a connection made into it gets nowhere.
  Future<bool> _tunnelTakesNothing() async {
    final check = tunnelCheck;
    if (check == null ||
        !isWindows ||
        settings.mode != ConnectionMode.tun ||
        settings.tunStack == 'gvisor') {
      return false;
    }
    return !await check();
  }

  /// Throws away the lists of sites on disk and gets them again, after the
  /// core could not read one of them.
  Future<void> _renewRuleSets() async {
    try {
      await for (final e in paths.ruleSets.list()) {
        if (e is File && e.path.endsWith('.srs')) await e.delete();
      }
    } on FileSystemException {
      // What stays is found out again by the next start.
    }
    await _extractRuleSets();
    await _fetchPanelRuleSets();
  }

  /// Disconnects, or calls off a connection that is still being set up.
  Future<void> disconnect() async {
    routingProblem = null;
    stackSwitched = false;
    _stopStats();
    _restoreProxy();
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

  /// Applies changed settings to a live connection. When the new connection
  /// could not be made for want of administrator rights, the one in use is
  /// left alone and [ElevationRequired] is thrown.
  Future<void> reconnect() async {
    if (status != CoreStatus.running) return;
    if (_needsElevation) throw ElevationRequired();
    await disconnect();
    await connect();
  }

  void _startStats() {
    connectedSince = DateTime.now();
    totalUp = totalDown = 0;
    speed = const TrafficSample(0, 0);
    routeTraffic = const RouteTraffic();
    _seenConnections.clear();
    _trafficSub = _clash!.traffic().listen((s) {
      speed = s;
      totalUp += s.up;
      totalDown += s.down;
      notifyListeners();
    }, onError: (_) {}, cancelOnError: true);
    _routeTimer?.cancel();
    _routeTimer =
        Timer.periodic(const Duration(seconds: 1), (_) => _pollRouteTraffic());
  }

  /// Traffic of this session split by where it went.
  RouteTraffic routeTraffic = const RouteTraffic();
  Timer? _routeTimer;
  bool _pollingRoutes = false;

  // Bytes already counted per open connection: the core reports running
  // totals for each, so only the growth since the last look is added.
  final Map<String, (int up, int down)> _seenConnections = {};

  Future<void> _pollRouteTraffic() async {
    final clash = _clash;
    if (clash == null || _pollingRoutes) return;
    _pollingRoutes = true;
    try {
      final list = await clash.connections();
      if (list == null || !identical(clash, _clash)) return;
      routeTraffic = routeTraffic.add(list, _seenConnections);
      notifyListeners();
    } finally {
      _pollingRoutes = false;
    }
  }

  void _stopStats() {
    _routeTimer?.cancel();
    _routeTimer = null;
    _seenConnections.clear();
    _trafficSub?.cancel();
    _trafficSub = null;
    _clash?.close();
    _clash = null;
    connectedSince = null;
    speed = const TrafficSample(0, 0);
  }

  /// True while [connect] itself is bringing the core up, as opposed to the
  /// home-screen widget or the quick settings tile doing so behind the app's
  /// back.
  bool _startingHere = false;

  void _onCoreChanged() {
    final now = core.status;
    if (isAndroid &&
        now == CoreStatus.running &&
        _lastStatus != CoreStatus.running &&
        !_startingHere) {
      // Started or switched by the widget or the tile: follow it.
      _stopStats();
      unawaited(_attachToRunning());
    }
    if (_lastStatus == CoreStatus.running && now == CoreStatus.stopped) {
      // The core died under us: do not leave the system pointing at it.
      _stopStats();
      _restoreProxy();
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

  /// What the running core was started with, as [_coreFingerprint].
  String? _appliedFingerprint;

  /// Everything that goes into the core's configuration, as one string.
  String? _coreFingerprint() {
    final profile = selectedProfile;
    if (profile == null) return null;
    return jsonEncode(configFor(profile,
        clashPort: 0, clashSecret: '', mixedPort: settings.mixedPort));
  }

  /// Called after something that may matter to the running core. A
  /// reconnect is asked for only when the configuration really differs
  /// from the one in use: choosing the value that is already set, or
  /// changing a setting and changing it back, asks for nothing.
  void _noteCoreChange() {
    final applied = _appliedFingerprint;
    pendingRestart = applied == null || _coreFingerprint() != applied;
  }

  void _settingsChanged({required bool affectsCore}) {
    if (affectsCore && status != CoreStatus.stopped) _noteCoreChange();
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
    if (status != CoreStatus.stopped) _noteCoreChange();
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
    if (settings.selectedProfileId == null && profiles.isNotEmpty) {
      settings.selectedProfileId = profiles.first.id;
      unawaited(store.saveSettings());
    }
  }

  /// Imports whatever [text] holds: links, a config file, or a
  /// subscription URL (which is fetched right away).
  Future<ImportOutcome> importText(String text) async {
    if (PanelRouting.isLink(text)) {
      final profile = PanelRouting.parseLink(text);
      if (profile == null && !text.trim().startsWith('happ://routing/off')) {
        return ImportOutcome(errors: const ['routing link']);
      }
      updateRouting((r) {
        r.imported = profile;
        if (profile != null) r.usePanelRouting = true;
      });
      unawaited(_fetchPanelRuleSets());
      return ImportOutcome(routing: profile ?? PanelRouting());
    }
    final parsed = parseImportText(text);
    if (parsed.subscriptionUrl != null) {
      try {
        final sub = await addSubscription(parsed.subscriptionUrl!);
        return ImportOutcome(
            added: profilesOf(sub.id).length,
            subscription: sub,
            unsupported: sub.unsupported);
      } on Object catch (e) {
        return ImportOutcome(failure: e);
      }
    }
    if (parsed.profiles.isNotEmpty) {
      _addProfiles(parsed.profiles);
      _profilesChanged();
    }
    return ImportOutcome(
        added: parsed.profiles.length,
        errors: parsed.errors,
        unsupported: parsed.skipped);
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
    if (status != CoreStatus.stopped) _noteCoreChange();
    _profilesChanged();
  }

  void deleteProfile(ProxyProfile p) {
    profiles.remove(p);
    _reselectAfterRemoval();
    _profilesChanged();
  }

  /// Moves the selection off a server that is gone. A connection running
  /// through that server goes on until the reconnect this asks for.
  void _reselectAfterRemoval() {
    if (profiles.any((p) => p.id == settings.selectedProfileId)) return;
    settings.selectedProfileId = profiles.firstOrNull?.id;
    unawaited(store.saveSettings());
    if (status != CoreStatus.stopped) _noteCoreChange();
  }

  /// One request to a subscription server. With device identification on it
  /// names the device and the address it is seen under, which a server
  /// behind a proxy, or one reached through the tunnel, cannot tell itself.
  Future<SubscriptionResult> _fetch(String url) async {
    final identify = settings.sendHwid;
    return fetchSubscription(
      url,
      client: httpClient,
      userAgent: 'HeaNetwork/$appVersion',
      deviceHeaders: {
        if (identify) ...?device?.headers,
        if (identify) ...addressHeaders(await publicIp?.current()),
      },
    );
  }

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
    final activeBefore = selectedProfile;
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
        description: p.description,
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
      ..announce = result.announce
      ..unsupported = List.of(result.unsupported);

    // The panel's routing rules travel with the subscription: no header
    // means the administrator took them away.
    final routingBefore = jsonEncode(sub.routing?.toJson());
    sub.routing = result.routing;
    final routingChanged = jsonEncode(sub.routing?.toJson()) != routingBefore;
    if (routingChanged) {
      configRevision++;
      if (status != CoreStatus.stopped &&
          routing.usePanelRouting &&
          activeBefore?.subscriptionId == sub.id) {
        _noteCoreChange();
      }
    }
    unawaited(_fetchPanelRuleSets());

    // Only bother the user about reconnecting when the server in use
    // actually changed; a routine refresh must not nag.
    if (status != CoreStatus.stopped) {
      final activeAfter = selectedProfile;
      final changed = activeBefore?.subscriptionId == sub.id &&
          (activeAfter == null || _fingerprint(activeAfter) != activeFingerprint);
      if (changed) _noteCoreChange();
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
    _reselectAfterRemoval();
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
    core.removeListener(_onCoreChanged);
    _subscriptionTimer?.cancel();
    _stopStats();
    _updater.close();
    super.dispose();
  }
}

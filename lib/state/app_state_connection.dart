import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/config/config_builder.dart';
import '../core/config/rule_values.dart';
import '../core/models/profile.dart';
import '../core/models/settings.dart';
import '../core/services/clash_api.dart';
import '../core/services/core_controller.dart';
import '../core/services/latency_tester.dart';
import '../core/models/route_traffic.dart';
import '../platform/windows/elevation.dart';
import '../platform/windows/win32.dart' as win32;
import 'app_state_base.dart';

/// Selection, startup, and the life of the connection itself: bringing the
/// core up, keeping it up, statistics, taking it down.
mixin AppStateConnection on AppStateBase {
  DateTime? connectedSince;
  TrafficSample speed = const TrafficSample(0, 0);
  int totalUp = 0;
  int totalDown = 0;

  /// Why this connection was made without the site rules and the panel's
  /// routing, in the core's words; null while they are in force.
  String? routingProblem;

  /// Bumped on every traffic sample while connected. The live numbers are
  /// the one thing that changes every second; carrying them on the state
  /// itself would rebuild every page at that rate, so they ride here and
  /// only the views that show them listen.
  final trafficTick = ValueNotifier<int>(0);

  /// This connection found the tunnel taking nothing on the configured
  /// network stack and moved to gVisor, which is now the setting.
  bool stackSwitched = false;

  /// The mode the running core was started in.
  ConnectionMode? activeMode;

  ClashApi? _clash;
  StreamSubscription<TrafficSample>? _trafficSub;
  CoreStatus _lastStatus = CoreStatus.stopped;
  Timer? _subscriptionTimer;

  bool get isConnected => status == CoreStatus.running;
  bool get isBusy =>
      status == CoreStatus.starting || status == CoreStatus.stopping;

  // ---- selection ----------------------------------------------------------

  /// The server a connection uses.
  @override
  ProxyProfile? get selectedProfile {
    final id = settings.selectedProfileId;
    return profiles.where((p) => p.id == id).firstOrNull ??
        (profiles.isEmpty ? null : profiles.first);
  }

  @override
  List<ProxyProfile> profilesOf(String? subscriptionId) =>
      profiles.where((p) => p.subscriptionId == subscriptionId).toList();

  void selectProfile(String id) {
    settings.selectedProfileId = id;
    settingsChanged(affectsCore: true);
  }

  /// Follows a server chosen outside the app (the home-screen widget), which
  /// has already moved the live connection, so no reconnect is pending.
  void adoptExternalSelection(String id) {
    settings.selectedProfileId = id;
    unawaited(store.saveSettings());
    notifyListeners();
  }

  // ---- startup ------------------------------------------------------------

  /// Loads rule-sets from the app bundle, undoes leftovers of a crashed
  /// previous run, and connects if the user asked for that.
  Future<void> init({bool connect = false}) async {
    await extractRuleSets();
    if (routing.seedDefaults(
        windows: isWindows, exists: (path) => File(path).existsSync())) {
      unawaited(store.saveRouting());
    }
    unawaited(fetchPanelRuleSets());
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
    unawaited(updater.clearInstalled(paths.downloads, appVersion));
    if (settings.checkUpdates) unawaited(checkForUpdate(silent: true));
    // Honour the refresh interval each panel asks for.
    unawaited(refreshDueSubscriptions());
    _subscriptionTimer = Timer.periodic(
        const Duration(minutes: 15), (_) => refreshDueSubscriptions());
  }

  /// The connection facet's part of [AppState.dispose]: the periodic
  /// subscription refresh and the statistics stop with the state.
  @override
  void disposeConnection() {
    _subscriptionTimer?.cancel();
    _stopStats();
    trafficTick.dispose();
  }

  // ---- connect / disconnect ------------------------------------------------

  /// The core configuration for connecting through [profile] with the
  /// current settings and routing.
  ///
  /// With [plainRouting] the site rules, the panel's profile and every list
  /// of sites are left out. What remains cannot be malformed, so the core
  /// starts on it whatever state the rules are in.
  @override
  Map<String, dynamic> configFor(
    ProxyProfile profile, {
    required int clashPort,
    required String clashSecret,
    int? mixedPort,
    int? xrayPort,
    bool plainRouting = false,
    String? tunStackOverride,
  }) =>
      buildConfig(
        profile: profile,
        settings: tunStackOverride == null
            ? settings
            : (AppSettings.fromJson(settings.toJson())..tunStack = tunStackOverride),
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
          xrayPath: paths.xrayPath,
          xrayPort: xrayPort,
          mixedPort: mixedPort,
          ruleSets: plainRouting ? const {} : ruleSets,
          logFile: isAndroid ? paths.coreLog.path : null,
        ),
      );

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
        unawaited(store.saveSettings());
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

  /// The [connect] under way, if any: a second call waits for it instead of
  /// piling a second connection onto it.
  Future<void>? _connecting;

  /// Bumped by [disconnect]. A [connect] that is still mid-flight — waiting
  /// on the tunnel check, say — checks this at every step and gives up
  /// instead of bringing the core back up after the user turned it off.
  int _connectGen = 0;

  /// VPN mode on Windows cannot be started by a copy of the app that is not
  /// running as administrator.
  bool get _needsElevation =>
      isWindows && settings.mode == ConnectionMode.tun && !elevated;

  Future<void> connect() {
    final running = _connecting;
    if (running != null) return running;
    // Claimed synchronously: a connect that lands between this and the
    // first await inside would otherwise start the core a second time.
    final done = Completer<void>();
    _connecting = done.future;
    return _connect(done);
  }

  Future<void> _connect(Completer<void> done) async {
    try {
      await _connectInner();
    } finally {
      _connectingSince = null;
      _connecting = null;
      done.complete();
    }
  }

  Future<void> _connectInner() async {
    if (status == CoreStatus.stopping) {
      // A connect that lands while the core is stopping would otherwise be
      // dropped on the floor. [CoreController.stop] waits for the stop.
      await core.stop();
    }
    if (status != CoreStatus.stopped) return;
    error = null;
    final profile = selectedProfile;
    if (profile == null) {
      error = errorNoServer;
      notifyListeners();
      return;
    }
    if (_needsElevation) throw ElevationRequired();

    _connectingSince = DateTime.now();
    final gen = _connectGen;
    var connected = false;
    try {
      final mixedPort = await freeTcpPort(settings.mixedPort);
      final clashPort = await freeTcpPort();
      final xrayPort = profile.viaXray ? await freeTcpPort() : null;
      final secret = newApiSecret();
      // The config of this connection, as the settings are when it is asked
      // for; [plain] leaves the routing rules out of it, [stack] builds it
      // with another network stack than the setting says.
      Map<String, dynamic> config({bool plain = false, String? stack}) =>
          configFor(profile,
              clashPort: clashPort,
              clashSecret: secret,
              mixedPort: mixedPort,
              xrayPort: xrayPort,
              plainRouting: plain,
              tunStackOverride: stack);

      pendingRestart = false;
      appliedFingerprint = coreFingerprint();
      activeMode = isAndroid ? ConnectionMode.tun : settings.mode;
      await _startDespiteRouting(config);
      await _leaveDeafStack(config, gen);
      if (gen != _connectGen) throw CoreCancelled();

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
      error = '$errorStartTimeout${e.limit.inSeconds}';
    } on CoreException catch (e) {
      error = e.message;
    } on Object catch (e) {
      // Not the core's own complaint: without this line it would be shown to
      // the user and nowhere else, leaving no way to look into it.
      debugPrint('HeaNetwork: connect failed: $e');
      error = '$e';
    }
    if (!connected) {
      activeMode = null;
      // The core came up and a later step failed: it does not stay up behind
      // the error, with the system half pointed at it.
      if (status == CoreStatus.running) await _abandon();
    }
    notifyListeners();
  }

  /// Brings the core up for [connect], which tells this start apart from
  /// one made by the home-screen widget or the quick settings tile.
  Future<void> _startCore(Map<String, dynamic> config) async {
    _startingHere = true;
    try {
      await core.start(config);
    } finally {
      _startingHere = false;
    }
  }

  /// Starts the core with the routing rules, and without them when it will
  /// not start on them: a connection without the rules beats no connection
  /// at all. [routingProblem] then holds what the core objected to.
  Future<void> _startDespiteRouting(
      Map<String, dynamic> Function({bool plain}) config) async {
    try {
      await _startCore(config());
      routingProblem = null;
    } on CoreException catch (e) {
      if (!isRoutingComplaint(e.message)) rethrow;
      routingProblem = e.message;
      if (e.message.contains('rule-set')) unawaited(renewRuleSets());
      try {
        // What is left cannot be malformed.
        await _startCore(config(plain: true));
      } on Object {
        routingProblem = null;
        rethrow;
      }
    }
  }

  /// Moves a tunnel that takes no connections to gVisor.
  ///
  /// The tunnel's default stack hands every TCP connection to Windows as an
  /// incoming one, and a firewall that blocks incoming connections
  /// (Portmaster does by default) then lets none through: connected, and
  /// nothing works. gVisor needs nothing from the system, so the core is
  /// started again on it. The retry runs on the overridden stack alone: the
  /// setting follows only when that helped, so no save in between can make
  /// the temporary value stick.
  Future<void> _leaveDeafStack(
      Map<String, dynamic> Function({bool plain, String? stack}) config,
      int gen) async {
    stackSwitched = false;
    if (!await _tunnelTakesNothing()) return;
    if (gen != _connectGen) throw CoreCancelled();
    var better = false;
    try {
      await core.stop();
      if (gen != _connectGen) throw CoreCancelled();
      activeMode = settings.mode;
      await _startCore(config(plain: routingProblem != null, stack: 'gvisor'));
      better = await tunnelCheck!();
    } finally {
      if (better) {
        stackSwitched = true;
        settings.tunStack = 'gvisor';
        configRevision++;
        unawaited(store.saveSettings());
      }
      appliedFingerprint = coreFingerprint();
    }
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

  /// Disconnects, or calls off a connection that is still being set up.
  @override
  Future<void> disconnect() async {
    // Whatever [connect] is still mid-flight stops at its next step instead
    // of bringing the core back up behind the user's back.
    final gen = ++_connectGen;
    routingProblem = null;
    stackSwitched = false;
    _stopStats();
    _restoreProxy();
    await core.stop();
    activeMode = null;
    pendingRestart = false;
    if (isAndroid) {
      // The note about the running core is only good while one runs; it
      // must not outlive the connection it described. (It does survive the
      // app being killed with the VPN up — which is exactly when a
      // restarted app needs it — because this path does not run then.)
      // Not awaited: it is only read long after, at the next attach, and a
      // connect that starts now writes a note of its own, which this must
      // not delete from under it.
      unawaited(() async {
        if (gen != _connectGen) return;
        try {
          if (await _activeFile.exists()) await _activeFile.delete();
        } on FileSystemException {
          // Only costs the statistics after the next attach.
        }
      }());
    }
    notifyListeners();
  }

  /// A connection is being set up and can be called off.
  bool get canCancel => status == CoreStatus.starting;

  /// Restarts the app with administrator rights and connects; the elevated
  /// copy takes over and this one goes away.
  ///
  /// Asking whether to is the interface's business; the sequence itself is
  /// app lifecycle policy, so it lives here — every path that runs into
  /// [ElevationRequired], the tray and autostart included, uses this one.
  /// `--elevated` lets the new copy past the single-instance guard while
  /// this one is still closing.
  Future<void> restartElevated() async {
    // A connection in use is taken down first, so that the two do not share
    // a core, and the settings are flushed so that it starts with what is
    // on screen.
    await disconnect();
    await store.flush();
    if (win32.shellExecute(Platform.resolvedExecutable,
        verb: 'runas', args: elevatedArguments(const [], connect: true))) {
      exit(0);
    }
  }

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
    // A [connect] this one just called off may still be finishing; let it
    // end before a new one starts, or the new one would wait behind it and
    // do nothing.
    final windingDown = _connecting;
    if (windingDown != null) await windingDown;
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
      trafficTick.value++;
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
      trafficTick.value++;
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

  @override
  void onCoreChanged() {
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
}

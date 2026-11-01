import 'app_state_base.dart';
import 'app_state_connection.dart';
import 'app_state_latency.dart';
import 'app_state_profiles.dart';
import 'app_state_routing.dart';
import 'app_state_updates.dart';

export '../core/models/route_traffic.dart';
export 'app_paths.dart';
export 'app_state_base.dart';

/// The state of the app: settings, servers, subscriptions, routing, the
/// connection itself, latency, updates.
///
/// The state and services live in [AppStateBase]; each facet of the state
/// is a mixin in its own file under `lib/state/`.
class AppState extends AppStateBase
    with
        AppStateConnection,
        AppStateRouting,
        AppStateProfiles,
        AppStateLatency,
        AppStateUpdates {
  AppState({
    required super.store,
    required super.core,
    required super.platform,
    required super.paths,
    required super.appVersion,
    super.systemProxy,
    super.autostart,
    super.device,
    super.httpClient,
    super.tcpProbe,
    super.publicIp,
    super.tunnelCheck,
    super.elevated,
    super.updater,
  }) {
    core.addListener(onCoreChanged);
  }
}

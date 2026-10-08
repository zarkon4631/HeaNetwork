import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

import 'app.dart';
import 'core/config/config_builder.dart';
import 'core/services/core_controller.dart';
import 'core/services/device_identity.dart';
import 'core/services/storage.dart';
import 'platform/android/widget_bridge.dart';
import 'platform/windows/desktop_shell.dart';
import 'platform/windows/system_proxy.dart';
import 'state/app_state.dart';

/// The bundled core sits next to the executable; a development checkout
/// uses the copy fetched by tool/fetch_assets.ps1.
String _findCore() {
  final sep = Platform.pathSeparator;
  final bundled =
      '${File(Platform.resolvedExecutable).parent.path}${sep}core${sep}sing-box.exe';
  if (File(bundled).existsSync()) return bundled;
  final override = Platform.environment['HEA_CORE'];
  if (override != null && File(override).existsSync()) return override;
  return '${Directory.current.path}$sep.cache${sep}core${sep}sing-box.exe';
}

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  final info = await PackageInfo.fromPlatform();
  final support = await getApplicationSupportDirectory();
  final windows = Platform.isWindows;
  final paths = AppPaths(support: support, corePath: windows ? _findCore() : null);

  final store = AppStore(paths.data);
  await store.load();
  // Known before the first frame: a TV gets a different layout.
  final device = await DeviceIdentity.detect(installId: store.settings.installId);

  final state = AppState(
    store: store,
    core: windows
        ? ProcessCoreController(corePath: paths.corePath!, runDir: paths.run)
        : AndroidCoreController(logFile: paths.coreLog),
    platform: windows ? CorePlatform.windows : CorePlatform.android,
    paths: paths,
    appVersion: info.version,
    systemProxy: windows ? SystemProxy(paths.proxyBackup) : null,
    autostart: windows ? const Autostart() : null,
    device: device,
  );
  // The install id is generated on first launch; keep it.
  unawaited(store.saveSettings());

  if (windows) {
    await DesktopShell.init(state, startHidden: args.contains(Autostart.flag));
  }
  runApp(HeaApp(state: state));
  await state.init(connect: args.contains('--connect'));
  if (Platform.isAndroid) {
    // Kept alive for the life of the app: it feeds the home-screen widget.
    await AndroidWidgetBridge(state).adoptSelection();
  }
}

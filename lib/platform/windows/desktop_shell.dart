import 'dart:io';
import 'dart:ui';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../app.dart' show appNavigatorKey;
import '../../core/services/core_controller.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import '../../ui/home_page.dart' show connectWithPrompts;

/// Window and tray behaviour on Windows: close-to-tray, a tray menu to
/// connect and quit, and a clean shutdown that restores the system proxy.
class DesktopShell with WindowListener, TrayListener {
  DesktopShell._(this.state);

  final AppState state;
  CoreStatus? _shownStatus;
  String? _shownLocale;

  static Future<DesktopShell> init(AppState state, {bool startHidden = false}) async {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(980, 720),
      minimumSize: Size(400, 620),
      center: true,
      title: 'HeaNetwork',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      if (!startHidden) {
        await windowManager.show();
        await windowManager.focus();
      }
    });
    // Closing is intercepted so it can mean "hide to tray".
    await windowManager.setPreventClose(true);

    final shell = DesktopShell._(state);
    windowManager.addListener(shell);
    trayManager.addListener(shell);
    await shell._refreshTray();
    state.addListener(shell._refreshTray);
    return shell;
  }

  S get _s {
    final locale = state.settings.locale;
    final code =
        locale == 'system' ? PlatformDispatcher.instance.locale.languageCode : locale;
    return code == 'ru' ? S.ru : S.en;
  }

  Future<void> _refreshTray() async {
    final status = state.status;
    final locale = state.settings.locale;
    if (status == _shownStatus && locale == _shownLocale) return;
    _shownStatus = status;
    _shownLocale = locale;
    final s = _s;
    final on = status == CoreStatus.running;
    try {
      await trayManager
          .setIcon(on ? 'assets/icons/tray_on.ico' : 'assets/icons/tray_off.ico');
      await trayManager.setToolTip('HeaNetwork · ${on ? s.statusOn : s.statusOff}');
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: s.trayShow),
        MenuItem(
          key: 'toggle',
          label: status == CoreStatus.stopped ? s.trayConnect : s.trayDisconnect,
          disabled: state.isBusy,
        ),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: s.trayQuit),
      ]));
    } on Object {
      // The tray is a convenience; the app must work without it.
    }
  }

  Future<void> _show() async {
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> quit() async {
    await state.disconnect();
    await state.store.flush();
    try {
      await trayManager.destroy();
    } on Object {
      // Already gone.
    }
    await windowManager.destroy();
    exit(0);
  }

  @override
  void onWindowClose() {
    if (state.settings.minimizeToTray) {
      windowManager.hide();
    } else {
      quit();
    }
  }

  @override
  void onTrayIconMouseDown() => _show();

  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        _show();
      case 'toggle':
        _toggle();
      case 'quit':
        quit();
    }
  }

  Future<void> _toggle() async {
    try {
      await state.toggle();
    } on ElevationRequired {
      // Needs a dialog, which needs the window.
      await _show();
      final context = appNavigatorKey.currentContext;
      if (context != null && context.mounted) await connectWithPrompts(context);
    }
  }
}

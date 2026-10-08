import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../../app.dart' show appNavigatorKey;
import '../../core/models/settings.dart';
import '../../core/services/core_controller.dart';
import '../../l10n/strings.dart';
import '../../state/app_state.dart';
import '../../ui/home_page.dart' show connectWithPrompts;

const _fullSize = Size(1000, 700);
const _fullMinimum = Size(380, 560);
const _compactSize = Size(340, 290);

/// Asks what closing the window should do. Returns [CloseAction.tray] or
/// [CloseAction.exit], or null when the user cancelled. `remember` tells
/// whether the answer should become the setting.
Future<(CloseAction, bool remember)?> askCloseAction(BuildContext context) {
  final s = S.of(context);
  var remember = false;
  return showDialog<(CloseAction, bool)>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(s.closeTitle),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.closeBody),
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                title: Text(s.rememberChoice),
                value: remember,
                onChanged: (v) => setState(() => remember = v ?? false),
              ),
            ],
          ),
        ),
        actionsOverflowButtonSpacing: 4,
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(s.cancel)),
          OutlinedButton(
            onPressed: () => Navigator.pop(context, (CloseAction.exit, remember)),
            child: Text(s.closeQuit),
          ),
          FilledButton(
            autofocus: true,
            onPressed: () => Navigator.pop(context, (CloseAction.tray, remember)),
            child: Text(s.closeToTray),
          ),
        ],
      ),
    ),
  );
}

/// Window and tray behaviour on Windows: what closing does, the compact
/// window, a tray menu to connect and quit, and a clean shutdown that
/// restores the system proxy.
class DesktopShell with WindowListener, TrayListener {
  DesktopShell._(this.state);

  final AppState state;
  CoreStatus? _shownStatus;
  String? _shownLocale;
  var _askingToClose = false;

  static Future<DesktopShell> init(AppState state, {bool startHidden = false}) async {
    await windowManager.ensureInitialized();
    final compact = state.compactView;
    final options = WindowOptions(
      size: compact ? _compactSize : _fullSize,
      minimumSize: compact ? _compactSize : _fullMinimum,
      center: true,
      title: 'HeaNetwork',
      alwaysOnTop: compact,
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      if (!startHidden) {
        await windowManager.show();
        await windowManager.focus();
      }
    });
    // Closing is intercepted so it can ask, or mean "hide to tray".
    await windowManager.setPreventClose(true);

    final shell = DesktopShell._(state);
    windowManager.addListener(shell);
    trayManager.addListener(shell);
    await shell._refreshTray();
    state.addListener(shell._refreshTray);
    state.onCompactViewChanged = shell._applyCompact;
    return shell;
  }

  /// Shrinks the window to a small always-on-top card, or restores it.
  Future<void> _applyCompact(bool compact) async {
    try {
      if (compact) {
        await windowManager.setMinimumSize(_compactSize);
        await windowManager.setSize(_compactSize);
        await windowManager.setAlwaysOnTop(true);
      } else {
        await windowManager.setAlwaysOnTop(false);
        await windowManager.setMinimumSize(_fullMinimum);
        await windowManager.setSize(_fullSize);
        await windowManager.center();
      }
    } on Object {
      // The layout already switched; a window that kept its size is fine.
    }
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
  void onWindowClose() => _onClose();

  Future<void> _onClose() async {
    var action = state.settings.closeAction;
    if (action == CloseAction.ask) {
      if (_askingToClose) return;
      // The overlay's context sits below the navigator, which dialogs need.
      final context = appNavigatorKey.currentState?.overlay?.context;
      if (context == null || !context.mounted) {
        action = CloseAction.tray;
      } else {
        _askingToClose = true;
        final answer = await askCloseAction(context);
        _askingToClose = false;
        if (answer == null) return;
        final (chosen, remember) = answer;
        action = chosen;
        if (remember) {
          state.updateSettings((s) => s.closeAction = chosen, affectsCore: false);
        }
      }
    }
    if (action == CloseAction.exit) {
      await quit();
    } else {
      await windowManager.hide();
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
      final context = appNavigatorKey.currentState?.overlay?.context;
      if (context != null && context.mounted) await connectWithPrompts(context);
    }
  }
}

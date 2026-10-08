// Pumps every screen on desktop, phone and TV sized surfaces in both
// languages and themes. Any overflow or build error fails the test.
//
// With HEA_SCREENSHOTS=1 the rendered screens are also written to
// docs/screenshots, which is how the images in the README are produced:
//   $env:HEA_SCREENSHOTS=1; flutter test test/screens_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/app.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/services/app_catalog.dart';
import 'package:heanetwork/core/services/clash_api.dart';
import 'package:heanetwork/core/services/updater.dart';
import 'package:heanetwork/platform/windows/desktop_shell.dart';
import 'package:heanetwork/state/app_state.dart';
import 'package:heanetwork/ui/home_page.dart';
import 'package:heanetwork/ui/settings_page.dart';
import 'package:heanetwork/ui/shell.dart';

import 'support.dart';

final saveShots = Platform.environment['HEA_SCREENSHOTS'] == '1';

const desktop = Size(1000, 668);
const phone = Size(400, 860);

/// Android TV at 1080p reports 960 x 540 logical pixels.
const tv = Size(960, 540);
const compact = Size(324, 250);

Future<void> shoot(WidgetTester tester, String name) async {
  if (!saveShots) return;
  // App icons are decoded off the test's fake clock.
  await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 400)));
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(const ValueKey('shot')));
  final bytes = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  });
  final file = File('docs/screenshots/$name.png');
  file.parent.createSync(recursive: true);
  file.writeAsBytesSync(bytes!);
}

Future<void> pumpApp(
  WidgetTester tester,
  AppState state, {
  required Size size,
  int tab = ShellTab.home,
  Widget? home,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  // Icons come from a real decoder, so resolve them before the fake clock
  // takes over; the widgets then find them already cached.
  await tester.runAsync(() => Future.wait([
        for (final a in state.routing.apps)
          AppCatalog.icon(processPath: a.processPath, packageName: a.packageName),
      ]));
  await tester.pumpWidget(RepaintBoundary(
    key: const ValueKey('shot'),
    child: HeaApp(state: state, home: home ?? Shell(initialTab: tab)),
  ));
  // The logo is an image asset, decoded asynchronously like the icons.
  await tester.runAsync(() => precacheImage(
      const AssetImage('assets/icons/app.png'), tester.element(find.byType(HeaApp))));
  await tester.pump(const Duration(milliseconds: 600));
}

void connectedSample(AppState state) {
  state
    ..connectedSince = DateTime.now().subtract(const Duration(minutes: 83, seconds: 12))
    ..speed = const TrafficSample(182 * 1024, 4 * 1024 * 1024 + 300000)
    ..totalUp = 96 * 1024 * 1024
    ..totalDown = 1560 * 1024 * 1024
    ..updateSettings((_) {}, affectsCore: false);
}

void main() {
  setUpAll(loadTestFonts);

  for (final (label, size) in [('desktop', desktop), ('phone', phone), ('tv', tv)]) {
    final platform = label == 'desktop' ? CorePlatform.windows : CorePlatform.android;
    final isTv = label == 'tv';
    // Desktop screens use Windows typography, the others Android's.
    final variant = TargetPlatformVariant.only(
        label == 'desktop' ? TargetPlatform.windows : TargetPlatform.android);

    group(label, () {
      testWidgets('home lists the configurations, disconnected', (tester) async {
        final state = makeState(platform: platform, tv: isTv);
        state.settings
          ..locale = 'ru'
          ..themeMode = 'dark';
        await pumpApp(tester, state, size: size);
        expect(find.text('Отключено'), findsOneWidget);
        // The selected server shows in the panel and in the list.
        expect(find.text('Нидерланды · Reality'), findsNWidgets(2));
        expect(find.text('Домашний AmneziaWG'), findsOneWidget);
        expect(find.text('Hea Premium'), findsOneWidget);
        // The mode switch exists only where there is a choice of mode.
        expect(find.byIcon(Icons.shield_rounded),
            platform == CorePlatform.windows ? findsOneWidget : findsNothing);
        await shoot(tester, '${label}_home_off');
      }, variant: variant);

      testWidgets('home, connected, light theme', (tester) async {
        final state = makeState(platform: platform, elevated: true, tv: isTv);
        state.settings
          ..locale = 'ru'
          ..themeMode = 'light'
          ..mode = ConnectionMode.tun;
        await pumpApp(tester, state, size: size);
        // Connecting probes for free ports, which is real I/O that the
        // widget tester's fake clock would never complete.
        await tester.runAsync(state.connect);
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('Подключено'), findsOneWidget);
        expect((state.core as FakeCore).lastConfig, isNotNull);
        connectedSample(state);
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('4.29 MB/s'), findsOneWidget);
        await shoot(tester, '${label}_home_on_light');
        await state.disconnect();
        await tester.pump(const Duration(milliseconds: 100));
      }, variant: variant);

      testWidgets('home, connected, dark theme', (tester) async {
        final state = makeState(platform: platform, elevated: true, tv: isTv);
        state.settings
          ..locale = 'ru'
          ..themeMode = 'dark'
          ..mode = ConnectionMode.tun;
        await pumpApp(tester, state, size: size);
        await tester.runAsync(state.connect);
        connectedSample(state);
        // One frame to start the transitions, one to finish them.
        await tester.pump(const Duration(milliseconds: 100));
        await tester.pump(const Duration(milliseconds: 1500));
        expect(find.text('Подключено'), findsOneWidget);
        await shoot(tester, '${label}_home_on');
        await state.disconnect();
        await tester.pump(const Duration(milliseconds: 100));
      }, variant: variant);

      testWidgets('home, english, empty and error states', (tester) async {
        final state = makeState(platform: platform, populated: false, tv: isTv);
        state.settings.locale = 'en';
        await pumpApp(tester, state, size: size);
        expect(find.text('Disconnected'), findsOneWidget);
        expect(find.text('No servers yet'), findsOneWidget);
        // A TV is offered the phone route first; everything else the clipboard.
        expect(find.text('Receive from a phone (QR)'), isTv ? findsOneWidget : findsNothing);
        expect(find.text('Paste from clipboard'), isTv ? findsNothing : findsOneWidget);
        await tester.tap(find.byIcon(Icons.power_settings_new_rounded));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('No server selected'), findsOneWidget);
      }, variant: variant);

      testWidgets('groups fold down to their header and back', (tester) async {
        final state = makeState(platform: platform, tv: isTv);
        state.settings
          ..locale = 'ru'
          ..themeMode = 'dark';
        await pumpApp(tester, state, size: size);
        final sub = state.subscriptions.single;
        expect(find.text('Германия · XHTTP'), findsOneWidget);
        // Each group says how many servers it holds.
        expect(find.text('5'), findsOneWidget);
        expect(find.text('2'), findsOneWidget);

        Future<void> tapHeader(String title) async {
          await tester.ensureVisible(find.text(title));
          await tester.pump(const Duration(milliseconds: 300));
          await tester.tap(find.text(title));
          await tester.pump(const Duration(milliseconds: 300));
        }

        await tapHeader('Hea Premium');
        expect(sub.collapsed, isTrue);
        expect(find.text('Германия · XHTTP'), findsNothing);
        expect(find.text('США · Trojan'), findsNothing);
        // The selected server sits in the folded group, so the header keeps
        // naming it (next to the connection panel, which always does).
        expect(find.text('Нидерланды · Reality'), findsNWidgets(2));
        expect(find.text('Домашний AmneziaWG'), findsOneWidget,
            reason: 'the other group is untouched');
        await shoot(tester, '${label}_home_folded');

        await tapHeader('Мои серверы');
        expect(state.settings.ownServersCollapsed, isTrue);
        expect(find.text('Домашний AmneziaWG'), findsNothing);
        expect(find.text('Hea Premium'), findsOneWidget);
        expect(tester.takeException(), isNull);

        await tapHeader('Hea Premium');
        expect(sub.collapsed, isFalse);
        expect(find.text('Германия · XHTTP'), findsOneWidget);
      }, variant: variant);

      testWidgets('a folded group still answers its own buttons', (tester) async {
        final state = makeState(platform: platform, tv: isTv);
        state.settings.locale = 'ru';
        state.subscriptions.single.collapsed = true;
        // Auto-select over the folded subscription is named in its header.
        state.selectAuto(state.subscriptions.single.id);
        await pumpApp(tester, state, size: size);
        expect(find.text('Германия · XHTTP'), findsNothing);
        expect(find.text('Автовыбор'), findsWidgets);

        // The menu button inside the header opens the menu, not the group.
        await tester.ensureVisible(find.text('Hea Premium'));
        await tester.pump(const Duration(milliseconds: 300));
        final header = find.ancestor(
            of: find.text('Hea Premium'), matching: find.byType(InkWell));
        await tester.tap(find.descendant(
            of: header.first, matching: find.byIcon(Icons.more_vert)));
        await tester.pumpAndSettle();
        expect(find.text('Переименовать'), findsOneWidget);
        expect(state.subscriptions.single.collapsed, isTrue);
      }, variant: variant);

      testWidgets('add menu', (tester) async {
        final state = makeState(platform: platform, tv: isTv);
        state.settings
          ..locale = 'ru'
          ..themeMode = 'dark';
        await pumpApp(tester, state, size: size);
        await tester.tap(find.byIcon(Icons.add_rounded));
        await tester.pumpAndSettle();
        expect(find.text('Вставить из буфера'), findsOneWidget);
        expect(find.text('Получить с телефона (QR)'), findsOneWidget);
        await shoot(tester, '${label}_add');
      }, variant: variant);

      testWidgets('theme toggle switches between light and dark', (tester) async {
        final state = makeState(platform: platform, tv: isTv);
        state.settings.themeMode = 'dark';
        await pumpApp(tester, state, size: size);
        await tester.tap(find.byIcon(Icons.light_mode_outlined));
        await tester.pumpAndSettle();
        expect(state.settings.themeMode, 'light');
        expect(find.byIcon(Icons.dark_mode_outlined), findsOneWidget);
      }, variant: variant);

      testWidgets('routing', (tester) async {
        final state = makeState(platform: platform, tv: isTv);
        state.settings
          ..locale = 'ru'
          ..themeMode = 'dark'
          ..mode = ConnectionMode.tun;
        await pumpApp(tester, state, size: size, tab: ShellTab.routing);
        expect(find.text('Всё через VPN'), findsOneWidget);
        await shoot(tester, '${label}_routing');

        // Changing a rule's action is persisted in the model.
        final rule = state.routing.apps.first;
        expect(rule.action, RouteAction.direct);
        await tester.ensureVisible(find.text('Блок').first);
        await tester.pump(const Duration(milliseconds: 300));
        await tester.tap(find.text('Блок').first);
        await tester.pump(const Duration(milliseconds: 300));
        expect(rule.action, RouteAction.block);
      }, variant: variant);

      testWidgets('settings', (tester) async {
        final state = makeState(platform: platform, tv: isTv);
        state.settings
          ..locale = 'ru'
          ..themeMode = 'dark';
        await pumpApp(tester, state, size: size, tab: ShellTab.settings);
        expect(find.textContaining('Защита от блокировок'), findsOneWidget);
        await shoot(tester, '${label}_settings');

        await tester.tap(find.text('Вручную'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(state.settings.antiDpi.preset, AntiDpiPreset.custom);
        // "Custom" starts from what the previous preset was doing.
        expect(state.settings.antiDpi.tlsRecordFragment, isTrue);
        expect(state.settings.antiDpi.tlsFragment, isFalse);

        // The device id that goes to the panel is shown to the user.
        await tester.dragUntilVisible(find.text('Отправлять HWID в панель'),
            find.byType(Scrollable).last, const Offset(0, -250));
        expect(find.textContaining(state.device!.hwid), findsOneWidget);
      }, variant: variant);

      testWidgets('settings in english with an update available', (tester) async {
        final state = makeState(platform: platform, tv: isTv);
        state.settings.locale = 'en';
        state.availableUpdate = ReleaseInfo(
          version: '1.1.0',
          notes: '- Faster connect\n- AmneziaWG fixes',
          pageUrl: releasesPage,
        );
        await pumpApp(tester, state, size: size, tab: ShellTab.settings);
        expect(find.text('Version 1.1.0 is available'), findsWidgets);
        await tester.dragUntilVisible(find.text('What’s new'),
            find.byType(Scrollable).last, const Offset(0, -300));
        expect(find.text('Open the download page'), findsOneWidget);
      }, variant: variant);

      testWidgets('log page', (tester) async {
        final state = makeState(platform: platform, tv: isTv);
        (state.core as FakeCore)
          ..log('INFO sing-box started (0.03s)')
          ..log('ERROR outbound/vless[proxy]: dial tcp: i/o timeout');
        await pumpApp(tester, state, size: size, home: const LogsPage());
        expect(find.textContaining('i/o timeout'), findsOneWidget);
      }, variant: variant);
    });
  }

  group('windows only', () {
    final variant = TargetPlatformVariant.only(TargetPlatform.windows);

    testWidgets('the mode switch flips between system proxy and VPN', (tester) async {
      final state = makeState();
      state.settings.locale = 'ru';
      await pumpApp(tester, state, size: desktop);
      expect(state.settings.mode, ConnectionMode.systemProxy);
      expect(find.text('Прокси'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.shield_rounded));
      await tester.pumpAndSettle();
      expect(state.settings.mode, ConnectionMode.tun);
      expect(find.text('VPN'), findsOneWidget);
    }, variant: variant);

    testWidgets('the mode switch says what system proxy mode leaves out', (tester) async {
      final state = makeState();
      state.settings
        ..locale = 'ru'
        ..themeMode = 'dark';
      await pumpApp(tester, state, size: desktop);
      final mouse = await tester.createGesture(kind: ui.PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byIcon(Icons.shield_rounded)));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      // Command-line tools ignore the Windows proxy setting; say so up front.
      expect(find.textContaining('консольные программы'), findsOneWidget);
      expect(find.textContaining('включите режим VPN'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: variant);

    testWidgets('folding animates when animations are on', (tester) async {
      final state = makeState();
      state.settings
        ..locale = 'ru'
        ..animations = true;
      await pumpApp(tester, state, size: desktop);
      await tester.tap(find.text('Hea Premium'));
      // Mid-flight the group is on its way out; afterwards it is gone.
      await tester.pump(const Duration(milliseconds: 60));
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Германия · XHTTP'), findsNothing);
      await tester.tap(find.text('Hea Premium'));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('Германия · XHTTP'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }, variant: variant);

    testWidgets('the ping method is chosen in settings', (tester) async {
      final state = makeState();
      state.settings.locale = 'ru';
      await pumpApp(tester, state, size: desktop, tab: ShellTab.settings);
      await tester.dragUntilVisible(find.text('Пинг серверов'),
          find.byType(Scrollable).last, const Offset(0, -250));
      expect(state.settings.pingMode, PingMode.tcp);
      expect(find.textContaining('Время соединения с самим сервером'), findsOneWidget);
      await tester.tap(find.byType(DropdownButton<PingMode>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Через сервер').last);
      await tester.pumpAndSettle();
      expect(state.settings.pingMode, PingMode.url);
      expect(find.textContaining('Время ответа сайта'), findsOneWidget);
      // A display preference: nothing about the connection has to restart.
      expect(state.pendingRestart, isFalse);
    }, variant: variant);

    testWidgets('compact view shows only the essentials and can be left', (tester) async {
      final state = makeState(elevated: true);
      state.settings
        ..locale = 'ru'
        ..themeMode = 'dark'
        ..compactView = true;
      final resizedTo = <bool>[];
      state.onCompactViewChanged = resizedTo.add;
      await pumpApp(tester, state, size: compact);
      await tester.runAsync(state.connect);
      connectedSample(state);
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 600));
      expect(find.text('Подключено'), findsOneWidget);
      expect(find.text('4.29 MB/s'), findsOneWidget);
      expect(find.text('Hea Premium'), findsNothing, reason: 'no list in compact view');
      expect(find.text('Маршруты'), findsNothing, reason: 'no navigation either');
      await shoot(tester, 'desktop_compact');

      await tester.tap(find.byIcon(Icons.open_in_full_rounded));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.compactView, isFalse);
      expect(resizedTo, [false], reason: 'the window is told to grow back');
      await state.disconnect();
      await tester.pump(const Duration(milliseconds: 100));
    }, variant: variant);

    testWidgets('a very small window still lays out', (tester) async {
      final state = makeState();
      await pumpApp(tester, state, size: const Size(380, 520));
      expect(tester.takeException(), isNull);
      await pumpApp(tester, state, size: const Size(700, 420));
      expect(tester.takeException(), isNull);
    }, variant: variant);

    testWidgets('closing asks: cancel, quit or tray', (tester) async {
      final state = makeState();
      state.settings
        ..locale = 'ru'
        ..themeMode = 'dark';
      await pumpApp(tester, state, size: desktop);
      final context = tester.element(find.byType(Shell));

      var answer = askCloseAction(context);
      await tester.pumpAndSettle();
      expect(find.text('Отмена'), findsOneWidget);
      expect(find.text('Закрыть полностью'), findsOneWidget);
      expect(find.text('Свернуть в трей'), findsOneWidget);
      await shoot(tester, 'desktop_close_dialog');
      await tester.tap(find.text('Отмена'));
      await tester.pumpAndSettle();
      expect(await answer, isNull);

      answer = askCloseAction(context);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Закрыть полностью'));
      await tester.pumpAndSettle();
      expect(await answer, (CloseAction.exit, false));

      answer = askCloseAction(context);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Запомнить выбор'));
      await tester.pump();
      await tester.tap(find.text('Свернуть в трей'));
      await tester.pumpAndSettle();
      expect(await answer, (CloseAction.tray, true));
    }, variant: variant);
  });

  group('tv', () {
    final variant = TargetPlatformVariant.only(TargetPlatform.android);

    testWidgets('the remote can reach the power button and the list', (tester) async {
      final state = makeState(platform: CorePlatform.android, tv: true);
      state.settings.locale = 'ru';
      await pumpApp(tester, state, size: tv);
      // The power button takes focus on its own, so OK connects right away
      // without hunting for it with the arrows.
      final before = FocusManager.instance.primaryFocus;
      final focused = before!.context!;
      expect(
        find.ancestor(
            of: find.byElementPredicate((e) => e == focused),
            matching: find.byType(PowerButton)),
        findsOneWidget,
      );

      // Walking right lands on something focusable in the list column.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump(const Duration(milliseconds: 300));
      expect(FocusManager.instance.primaryFocus, isNot(same(before)));
    }, variant: variant);
  });
}

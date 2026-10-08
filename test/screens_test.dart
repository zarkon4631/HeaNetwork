// Pumps every screen on a desktop-sized and a phone-sized surface in both
// languages. Any overflow or build error fails the test.
//
// With HEA_SCREENSHOTS=1 the rendered screens are also written to
// docs/screenshots, which is how the images in the README are produced:
//   $env:HEA_SCREENSHOTS=1; flutter test test/screens_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/app.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/services/app_catalog.dart';
import 'package:heanetwork/core/services/clash_api.dart';
import 'package:heanetwork/core/services/updater.dart';
import 'package:heanetwork/state/app_state.dart';
import 'package:heanetwork/ui/settings_page.dart';
import 'package:heanetwork/ui/shell.dart';

import 'support.dart';

final saveShots = Platform.environment['HEA_SCREENSHOTS'] == '1';

const desktop = Size(1040, 760);
const phone = Size(400, 860);

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
  await tester.pump(const Duration(milliseconds: 600));
}

void main() {
  setUpAll(loadTestFonts);

  for (final (label, size) in [('desktop', desktop), ('phone', phone)]) {
    final platform = label == 'desktop' ? CorePlatform.windows : CorePlatform.android;
    // Desktop screens use Windows typography, phone screens Android's.
    final variant = TargetPlatformVariant.only(
        label == 'desktop' ? TargetPlatform.windows : TargetPlatform.android);

    group(label, () {

      testWidgets('home, disconnected', (tester) async {
        final state = makeState(platform: platform);
        state.settings.locale = 'ru';
        await pumpApp(tester, state, size: size);
        expect(find.text('Отключено'), findsOneWidget);
        expect(find.text('Нидерланды · Reality'), findsOneWidget);
        await shoot(tester, '${label}_home_off');
      }, variant: variant);

      testWidgets('home, connected', (tester) async {
        final state = makeState(platform: platform, elevated: true);
        state.settings
          ..locale = 'ru'
          ..mode = ConnectionMode.tun;
        await pumpApp(tester, state, size: size);
        // Connecting probes for free ports, which is real I/O that the
        // widget tester's fake clock would never complete.
        await tester.runAsync(state.connect);
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.text('Подключено'), findsOneWidget);
        expect((state.core as FakeCore).lastConfig, isNotNull);
        state
          ..connectedSince = DateTime.now().subtract(const Duration(minutes: 83, seconds: 12))
          ..speed = const TrafficSample(182 * 1024, 4 * 1024 * 1024 + 300000)
          ..totalUp = 96 * 1024 * 1024
          ..totalDown = 1560 * 1024 * 1024
          ..updateSettings((_) {}, affectsCore: false);
        await tester.pump(const Duration(milliseconds: 600));
        await shoot(tester, '${label}_home_on');
        await state.disconnect();
        await tester.pump(const Duration(milliseconds: 100));
      }, variant: variant);

      testWidgets('home, english, error and empty states', (tester) async {
        final state = makeState(platform: platform, populated: false);
        state.settings.locale = 'en';
        await pumpApp(tester, state, size: size);
        expect(find.text('Disconnected'), findsOneWidget);
        await tester.tap(find.byIcon(Icons.power_settings_new_rounded));
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.text('No server selected'), findsWidgets);
      }, variant: variant);

      testWidgets('servers', (tester) async {
        final state = makeState(platform: platform);
        state.settings.locale = 'ru';
        await pumpApp(tester, state, size: size, tab: ShellTab.servers);
        expect(find.text('Hea Premium'), findsOneWidget);
        expect(find.text('Домашний AmneziaWG'), findsOneWidget);
        await shoot(tester, '${label}_servers');

        await tester.tap(find.text('Добавить').first);
        await tester.pumpAndSettle();
        expect(find.text('Вставить из буфера'), findsOneWidget);
        await shoot(tester, '${label}_servers_add');
      }, variant: variant);

      testWidgets('servers, empty', (tester) async {
        final state = makeState(platform: platform, populated: false);
        state.settings.locale = 'en';
        await pumpApp(tester, state, size: size, tab: ShellTab.servers);
        expect(find.text('No servers yet'), findsOneWidget);
      }, variant: variant);

      testWidgets('routing', (tester) async {
        final state = makeState(platform: platform);
        state.settings
          ..locale = 'ru'
          ..mode = ConnectionMode.tun;
        await pumpApp(tester, state, size: size, tab: ShellTab.routing);
        expect(find.text('Всё через VPN'), findsOneWidget);
        expect(find.text('Российские сайты напрямую'), findsOneWidget);
        await shoot(tester, '${label}_routing');

        // Changing a rule's action is persisted in the model.
        final rule = state.routing.apps.first;
        expect(rule.action, RouteAction.direct);
        await tester.tap(find.text('Блок').first);
        await tester.pump(const Duration(milliseconds: 300));
        expect(rule.action, RouteAction.block);
      }, variant: variant);

      testWidgets('settings', (tester) async {
        final state = makeState(platform: platform);
        state.settings.locale = 'ru';
        await pumpApp(tester, state, size: size, tab: ShellTab.settings);
        expect(find.textContaining('Защита от блокировок'), findsOneWidget);
        await shoot(tester, '${label}_settings');

        await tester.tap(find.text('Вручную'));
        await tester.pump(const Duration(milliseconds: 300));
        expect(state.settings.antiDpi.preset, AntiDpiPreset.custom);
        expect(find.text('Дробить TCP-пакеты'), findsOneWidget);
        // "Custom" starts from what the previous preset was doing.
        expect(state.settings.antiDpi.tlsRecordFragment, isTrue);
        expect(state.settings.antiDpi.tlsFragment, isFalse);
      }, variant: variant);

      testWidgets('settings in english with an update available', (tester) async {
        final state = makeState(platform: platform);
        state.settings.locale = 'en';
        state.availableUpdate = ReleaseInfo(
          version: '0.2.0',
          notes: '- Faster connect\n- AmneziaWG fixes',
          pageUrl: releasesPage,
        );
        await pumpApp(tester, state, size: size, tab: ShellTab.settings);
        expect(find.text('Version 0.2.0 is available'), findsWidgets);
        await tester.dragUntilVisible(find.text('What’s new'),
            find.byType(Scrollable).last, const Offset(0, -300));
        expect(find.text('Open the download page'), findsOneWidget);
      }, variant: variant);

      testWidgets('log page', (tester) async {
        final state = makeState(platform: platform);
        (state.core as FakeCore)
          ..log('INFO sing-box started (0.03s)')
          ..log('ERROR outbound/vless[proxy]: dial tcp: i/o timeout');
        await pumpApp(tester, state, size: size, home: const LogsPage());
        expect(find.textContaining('i/o timeout'), findsOneWidget);
      }, variant: variant);
    });
  }
}

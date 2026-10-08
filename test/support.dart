import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/profile.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/parsers/import_parser.dart';
import 'package:heanetwork/core/services/core_controller.dart';
import 'package:heanetwork/core/services/device_identity.dart';
import 'package:heanetwork/core/services/storage.dart';
import 'package:heanetwork/core/services/updater.dart';
import 'package:heanetwork/state/app_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';

/// A core that "starts" instantly, for driving the UI without a process.
class FakeCore extends CoreController {
  Map<String, dynamic>? lastConfig;
  CoreException? failWith;

  @override
  Future<void> start(Map<String, dynamic> config) async {
    final failure = failWith;
    if (failure != null) throw failure;
    lastConfig = config;
    setStatus(CoreStatus.running);
  }

  @override
  Future<void> stop() async => setStatus(CoreStatus.stopped);

  void log(String line) => addLog(line);
}

/// Real fonts, so rendered screens show text instead of placeholder boxes.
Future<void> loadTestFonts() async {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return;
  final dir = Directory('$root/bin/cache/artifacts/material_fonts');
  if (!dir.existsSync()) return;
  Future<ByteData> read(String name) async =>
      ByteData.sublistView(await File('${dir.path}/$name').readAsBytes());
  final roboto = FontLoader('Roboto');
  for (final f in ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf']) {
    roboto.addFont(read(f));
  }
  await roboto.load();
  final icons = FontLoader('MaterialIcons')..addFont(read('materialicons-regular.otf'));
  await icons.load();

  // On a Windows host, also load the real desktop UI font so desktop
  // screens render exactly as the shipped app does.
  final windir = Platform.environment['WINDIR'];
  if (windir == null) return;
  final segoe = FontLoader('Segoe UI');
  var found = false;
  for (final f in ['segoeui.ttf', 'seguisb.ttf', 'segoeuib.ttf']) {
    final file = File('$windir/Fonts/$f');
    if (!file.existsSync()) continue;
    found = true;
    segoe.addFont(file.readAsBytes().then(ByteData.sublistView));
  }
  if (found) await segoe.load();
}

http.Client offlineClient() =>
    MockClient((_) async => http.Response('offline', 503));

/// An [AppState] over a temp directory and a [FakeCore], optionally filled
/// with a realistic set of servers and rules.
AppState makeState({
  CorePlatform platform = CorePlatform.windows,
  bool populated = true,
  bool elevated = false,
  bool tv = false,
  http.Client? client,
  http.Client? subscriptionClient,
}) {
  final dir = Directory.systemTemp.createTempSync('hea_ui_');
  addTearDown(() {
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Still locked by a pending write; the OS temp cleaner will get it.
    }
  });
  final store = AppStore(Directory('${dir.path}/data'));
  // A moving background never settles, which pumpAndSettle waits for.
  store.settings.animations = false;

  if (populated) {
    final sub = Subscription(
      name: 'Hea Premium',
      url: 'https://panel.example.com/sub/abc',
      updatedAt: DateTime(2026, 10, 8, 21, 40),
      uploadBytes: 3 * 1024 * 1024 * 1024,
      downloadBytes: 41 * 1024 * 1024 * 1024,
      totalBytes: 200 * 1024 * 1024 * 1024,
      expireAt: DateTime(2026, 12, 31),
    );
    store.subscriptions.add(sub);
    ProxyProfile p(String key, String name, int? ms, {String? subId}) =>
        parseLink(sampleLinks[key]!)
          ..name = name
          ..latencyMs = ms
          ..subscriptionId = subId;
    store.profiles.addAll([
      p('vless-reality-vision', 'Нидерланды · Reality', 48, subId: sub.id),
      p('vless-xhttp-reality', 'Германия · XHTTP', 71, subId: sub.id),
      p('hysteria2', 'Финляндия · Hysteria 2', 356, subId: sub.id),
      p('trojan-ws', 'США · Trojan', 912, subId: sub.id),
      p('tuic', 'Япония · TUIC', -1, subId: sub.id),
      parseImportText(amneziaConf).profiles.single
        ..name = 'Домашний AmneziaWG'
        ..latencyMs = 39,
      p('ss-2022', 'Резервный Shadowsocks', null),
    ]);
    store.settings.selectedProfileId = store.profiles.first.id;

    final windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    if (platform == CorePlatform.windows) {
      store.routing.apps.addAll([
        AppRule(
            name: 'Проводник',
            processName: 'explorer.exe',
            processPath: '$windir\\explorer.exe',
            action: RouteAction.direct),
        AppRule(
            name: 'Блокнот',
            processName: 'notepad.exe',
            processPath: '$windir\\System32\\notepad.exe',
            action: RouteAction.proxy),
        AppRule(
            name: 'Диспетчер задач',
            processName: 'Taskmgr.exe',
            processPath: '$windir\\System32\\Taskmgr.exe',
            action: RouteAction.block),
      ]);
    } else {
      store.routing.apps.addAll([
        AppRule(name: 'СберБанк', packageName: 'ru.sberbankmobile'),
        AppRule(
            name: 'Telegram',
            packageName: 'org.telegram.messenger',
            action: RouteAction.proxy),
      ]);
    }
    store.routing
      ..ruDirect = true
      ..domains.addAll([
        DomainRule.guess('youtube.com', RouteAction.proxy),
        DomainRule.guess('192.168.88.0/24', RouteAction.direct),
      ]);
  }

  final state = AppState(
    store: store,
    core: FakeCore(),
    platform: platform,
    paths: AppPaths(support: dir, corePath: r'C:\none\sing-box.exe'),
    appVersion: '1.0.1',
    elevated: elevated,
    updater: Updater(client: client ?? offlineClient()),
    httpClient: subscriptionClient,
    device: DeviceIdentity(
      hwid: DeviceIdentity.hash('test-device'),
      os: tv ? 'Android TV' : (platform == CorePlatform.windows ? 'Windows' : 'Android'),
      osVersion: '14',
      model: 'Test Device',
      isTv: tv,
    ),
  );
  addTearDown(state.dispose);
  return state;
}

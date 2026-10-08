import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/models/profile.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/services/core_controller.dart';
import 'package:heanetwork/core/services/storage.dart';
import 'package:heanetwork/core/services/subscription_service.dart';
import 'package:heanetwork/core/services/updater.dart';
import 'package:heanetwork/platform/windows/system_proxy.dart';
import 'package:heanetwork/platform/windows/win32.dart';
import 'package:heanetwork/state/app_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';
import 'support.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('hea_svc_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('updater', () {
    test('version ordering', () {
      expect(compareVersions('1.10.0', '1.9.3'), greaterThan(0));
      expect(compareVersions('v1.2.0', '1.2'), 0);
      expect(compareVersions('0.1.0', '0.1.1'), lessThan(0));
      expect(compareVersions('1.0.0-beta.1', '1.0.0'), lessThan(0));
      expect(compareVersions('1.0.0+7', '1.0.0+3'), 0);
    });

    test('checksum lookup', () {
      final sums = 'aa${'0' * 62}  one.exe\nbb${'1' * 62} *two.apk\n';
      expect(checksumFor(sums, 'two.apk'), 'bb${'1' * 62}');
      expect(checksumFor(sums, 'three.zip'), isNull);
    });

    final installer = utf8.encode('pretend installer bytes');
    const name = 'HeaNetwork-0.2.0-windows-x64-setup.exe';

    http.Client github({String? sums, String tag = 'v0.2.0'}) => MockClient((req) async {
          if (req.url.path.endsWith('/releases/latest')) {
            return http.Response(
                jsonEncode({
                  'tag_name': tag,
                  'body': 'notes',
                  'html_url': 'https://example.com/release',
                  'assets': [
                    {
                      'name': name,
                      'size': installer.length,
                      'browser_download_url': 'https://example.com/$name',
                    },
                    {
                      'name': 'HeaNetwork-0.2.0-android-universal.apk',
                      'size': 1,
                      'browser_download_url': 'https://example.com/u.apk',
                    },
                    if (sums != null)
                      {
                        'name': 'SHA256SUMS.txt',
                        'size': sums.length,
                        'browser_download_url': 'https://example.com/sums',
                      },
                  ],
                }),
                200);
          }
          if (req.url.path == '/sums') return http.Response(sums!, 200);
          if (req.url.path == '/$name') return http.Response.bytes(installer, 200);
          return http.Response('not found', 404);
        });

    test('offers a newer release and picks the right asset', () async {
      final u = Updater(client: github(sums: ''));
      final r = await u.check('0.1.0', assetSuffixes: ['windows-x64-setup.exe']);
      expect(r!.version, '0.2.0');
      expect(r.assetName, name);
      // The ABI-specific APK is missing, so the universal one is the fallback.
      final apk = await u.check('0.1.0',
          assetSuffixes: ['android-arm64-v8a.apk', 'android-universal.apk']);
      expect(apk!.assetName, 'HeaNetwork-0.2.0-android-universal.apk');
      expect(await u.check('0.2.0', assetSuffixes: ['windows-x64-setup.exe']), isNull);
      expect(await u.check('0.3.0', assetSuffixes: ['windows-x64-setup.exe']), isNull);
    });

    test('downloads and verifies against SHA256SUMS', () async {
      final good = '${sha256.convert(installer)}  $name\n';
      final u = Updater(client: github(sums: good));
      final r = (await u.check('0.1.0', assetSuffixes: ['windows-x64-setup.exe']))!;
      final progress = <double>[];
      final file = await u.download(r, tmp, onProgress: progress.add);
      expect(file.readAsBytesSync(), installer);
      expect(progress.last, 1.0);
    });

    test('refuses a tampered download and deletes it', () async {
      final bad = '${sha256.convert(utf8.encode('something else'))}  $name\n';
      final u = Updater(client: github(sums: bad));
      final r = (await u.check('0.1.0', assetSuffixes: ['windows-x64-setup.exe']))!;
      await expectLater(u.download(r, tmp), throwsA(isA<UpdateException>()));
      expect(File('${tmp.path}/$name').existsSync(), isFalse);
    });

    test('refuses a release without checksums', () async {
      final u = Updater(client: github());
      final r = (await u.check('0.1.0', assetSuffixes: ['windows-x64-setup.exe']))!;
      await expectLater(u.download(r, tmp), throwsA(isA<UpdateException>()));
    });
  });

  group('subscription', () {
    test('parses body and usage headers', () async {
      final body = base64.encode(utf8.encode(
          '${sampleLinks['vless-reality-vision']}\n${sampleLinks['hysteria2']}'));
      final client = MockClient((req) async {
        expect(req.headers['User-Agent'], 'HeaNetwork/1.2.3');
        return http.Response(body, 200, headers: {
          'subscription-userinfo':
              'upload=100; download=200; total=1000; expire=1767139200',
          'profile-title': 'base64:${base64.encode(utf8.encode('Мой VPN'))}',
        });
      });
      final r = await fetchSubscription('https://panel.example/sub',
          client: client, userAgent: 'HeaNetwork/1.2.3');
      expect(r.profiles, hasLength(2));
      expect(r.title, 'Мой VPN');
      expect((r.upload, r.download, r.total), (100, 200, 1000));
      expect(r.expire!.toUtc().year, 2025);
    });

    test('reports HTTP errors and empty bodies', () async {
      await expectLater(
          fetchSubscription('https://x.example/s',
              client: MockClient((_) async => http.Response('', 403))),
          throwsA(isA<SubscriptionException>()));
      await expectLater(
          fetchSubscription('https://x.example/s',
              client: MockClient((_) async => http.Response('<html>login</html>', 200))),
          throwsA(isA<SubscriptionException>()));
    });
  });

  test('store round-trips everything and survives a corrupt file', () async {
    final store = AppStore(tmp)
      ..profiles.add(ProxyProfile(
          name: 'A', type: Protocol.vless, outbound: {'type': 'vless', 'server': 's'}))
      ..subscriptions.add(Subscription(name: 'S', url: 'https://x', autoSelect: true))
      ..settings.mode = ConnectionMode.tun
      ..settings.antiDpi.preset = AntiDpiPreset.strong
      ..settings.portForwards
          .add(PortForward(listenPort: 1, targetHost: 'h', targetPort: 2))
      ..routing.apps.add(AppRule(name: 'App', processName: 'a.exe', matchByPath: true))
      ..routing.domains.add(DomainRule.guess('a.com', RouteAction.block));
    await store.saveProfiles();
    await store.saveSubscriptions();
    await store.saveSettings();
    await store.saveRouting();

    final again = AppStore(tmp);
    await again.load();
    expect(again.profiles.single.name, 'A');
    expect(again.subscriptions.single.autoSelect, isTrue);
    expect(again.settings.mode, ConnectionMode.tun);
    expect(again.settings.antiDpi.preset, AntiDpiPreset.strong);
    expect(again.settings.portForwards.single.targetHost, 'h');
    expect(again.routing.apps.single.matchByPath, isTrue);
    expect(again.routing.domains.single.action, RouteAction.block);

    File('${tmp.path}/settings.json').writeAsStringSync('{ not json');
    final broken = AppStore(tmp);
    await broken.load();
    expect(broken.settings.mode, ConnectionMode.systemProxy, reason: 'defaults');
    expect(File('${tmp.path}/settings.json.corrupt').existsSync(), isTrue);
  });

  test('overlapping saves are queued and the newest state wins', () async {
    final store = AppStore(tmp);
    for (var port = 3000; port < 3020; port++) {
      store.settings.mixedPort = port;
      // Fired without awaiting, exactly as the UI does on every change.
      store.saveSettings();
    }
    await store.flush();
    expect(store.lastWriteError, isNull);
    final again = AppStore(tmp);
    await again.load();
    expect(again.settings.mixedPort, 3019);
    expect(File('${tmp.path}/settings.json.tmp').existsSync(), isFalse);
  });

  test('core failure summary prefers the fatal line', () {
    expect(
        summarizeCoreFailure([
          'INFO starting',
          'FATAL[0000] start service: listen tcp 127.0.0.1:2080: bind: address in use',
          'INFO bye',
        ]),
        'start service: listen tcp 127.0.0.1:2080: bind: address in use');
    expect(summarizeCoreFailure(['just a line']), 'just a line');
    expect(summarizeCoreFailure([]), contains('without output'));
  });

  test('app state: import, selection, connect builds a config', () async {
    final state = makeState(populated: false);
    final outcome = await state.importText(
        '${sampleLinks['vless-reality-vision']}\nnot-a-link://x\n${sampleLinks['tuic']}');
    expect(outcome.added, 2);
    expect(outcome.errors, hasLength(1));
    expect(state.selectedProfile, state.profiles.first);

    state.selectProfile(state.profiles.last.id);
    await state.connect();
    expect(state.isConnected, isTrue);
    final config = (state.core as FakeCore).lastConfig!;
    expect((config['outbounds'] as List).first['type'], 'tuic');

    // A change while connected is flagged rather than silently ignored.
    state.updateRouting((r) => r.ruDirect = true);
    expect(state.pendingRestart, isTrue);
    await state.reconnect();
    expect(state.pendingRestart, isFalse);
    await state.disconnect();
    expect(state.isConnected, isFalse);

    // Deleting the selected server moves the selection instead of dangling.
    state.deleteProfile(state.profiles.last);
    expect(state.selectedProfile, state.profiles.single);
  });

  test('app state: a core error is surfaced', () async {
    final state = makeState();
    (state.core as FakeCore).failWith = CoreException('bind: address in use');
    await state.connect();
    expect(state.isConnected, isFalse);
    expect(state.error, 'bind: address in use');
  });

  test('app state: TUN without admin asks for elevation instead of failing', () async {
    final state = makeState();
    state.settings.mode = ConnectionMode.tun;
    await expectLater(state.connect(), throwsA(isA<ElevationRequired>()));
    expect(state.isConnected, isFalse);
    expect((state.core as FakeCore).lastConfig, isNull);
  });

  group('windows system proxy', () {
    const key = r'Software\HeaNetworkTest\Proxy';
    tearDown(() {
      for (final n in ['ProxyEnable', 'ProxyServer', 'ProxyOverride', 'HeaNetwork']) {
        RegistryValue(key, n).delete();
      }
      deleteRegistryKey(key);
      deleteRegistryKey(r'Software\HeaNetworkTest');
    });

    test('enable then restore puts the previous settings back', () {
      const enable = RegistryValue(key, 'ProxyEnable');
      const server = RegistryValue(key, 'ProxyServer');
      const bypass = RegistryValue(key, 'ProxyOverride');
      enable.writeInt(1);
      server.writeString('corp-proxy:8080');

      final proxy =
          SystemProxy(File('${tmp.path}/backup.json'), keyPath: key, notify: false);
      expect(proxy.isOurs, isFalse);
      proxy.enable(2080);
      expect(proxy.isOurs, isTrue);
      expect(server.readString(), '127.0.0.1:2080');
      expect(bypass.readString(), contains('<local>'));

      // Enabling again (reconnect on another port) keeps the original backup.
      proxy.enable(2081);
      expect(server.readString(), '127.0.0.1:2081');

      proxy.restore();
      expect(proxy.isOurs, isFalse);
      expect(enable.readInt(), 1);
      expect(server.readString(), 'corp-proxy:8080');
      expect(bypass.read(), isNull);
      proxy.restore(); // no-op
    });

    test('restore after a crash turns a proxy that was off back off', () {
      final backup = File('${tmp.path}/backup.json');
      SystemProxy(backup, keyPath: key, notify: false).enable(2080);
      // A new process (the next launch) finds the leftover backup.
      SystemProxy(backup, keyPath: key, notify: false).restore();
      expect(const RegistryValue(key, 'ProxyEnable').readInt(), 0);
      expect(const RegistryValue(key, 'ProxyServer').read(), isNull);
    });

    test('autostart writes and removes the Run entry', () {
      const autostart = Autostart(keyPath: key);
      expect(autostart.isEnabled, isFalse);
      autostart.set(true, executable: r'C:\Apps\Hea Network\heanetwork.exe');
      expect(const RegistryValue(key, 'HeaNetwork').readString(),
          r'"C:\Apps\Hea Network\heanetwork.exe" --autostart');
      autostart.set(false);
      expect(autostart.isEnabled, isFalse);
    });
  }, skip: Platform.isWindows ? null : 'Windows only');
}

// Subscriptions as a 3x-ui panel serves them: device identification (HWID),
// the device limit, the metadata headers, and what a refresh may and may not
// disturb in the app.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/services/device_identity.dart';
import 'package:heanetwork/core/services/lan_receiver.dart';
import 'package:heanetwork/core/services/subscription_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'fixtures.dart';
import 'support.dart';

String body(Iterable<String> links) => base64.encode(utf8.encode(links.join('\n')));

void main() {
  group('device identity', () {
    test('the id is a stable hash, never the raw machine id', () {
      final a = DeviceIdentity.hash('5d6f2c1e-machine-guid');
      expect(a, DeviceIdentity.hash('5d6f2c1e-machine-guid'));
      expect(a, isNot(DeviceIdentity.hash('another-machine')));
      expect(a, hasLength(32));
      expect(a, isNot(contains('machine')));
      // 3x-ui ignores ids shorter than six characters.
      expect(a.length, greaterThanOrEqualTo(6));
    });

    test('windows version string', () {
      expect(DeviceIdentity.windowsVersion('"Windows 11 Pro" 10.0 (Build 26100)'),
          '10.0.26100');
      expect(DeviceIdentity.windowsVersion('something else'), 'something else');
    });

    test('headers use the names 3x-ui reads', () {
      const d = DeviceIdentity(
          hwid: 'abc123abc123', os: 'Windows', osVersion: '10.0.26100', model: 'PC-1');
      expect(d.headers, {
        'X-HWID': 'abc123abc123',
        'X-Device-OS': 'Windows',
        'X-Ver-OS': '10.0.26100',
        'X-Device-Model': 'PC-1',
      });
    });

    test('detection on this machine yields a usable identity', () async {
      final d = await DeviceIdentity.detect(installId: 'install-id-fallback');
      expect(d.hwid, hasLength(32));
      expect(d.os, isNotEmpty);
      // The same machine must always present the same id.
      expect((await DeviceIdentity.detect(installId: 'other')).hwid,
          Platform.isWindows ? d.hwid : isNot(d.hwid));
    });
  });

  group('fetch', () {
    test('sends the device headers and reads the panel metadata', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(body([sampleLinks['vless-reality-vision']!]), 200, headers: {
          'subscription-userinfo': 'upload=10; download=20; total=100; expire=0',
          'profile-update-interval': '12',
          'profile-title': 'base64:${base64.encode(utf8.encode('Мой VPN'))}',
          'support-url': 'https://t.me/support',
          'profile-web-page-url': 'https://panel.example/sub/abc',
          'announce': 'base64:${base64.encode(utf8.encode('Работы 12 мая'))}',
          'routing-enable': 'true',
          'x-hwid-active': 'true',
        });
      });
      final r = await fetchSubscription(
        'https://panel.example/sub/abc',
        client: client,
        userAgent: 'HeaNetwork/1.0.1',
        deviceHeaders: const DeviceIdentity(
                hwid: 'abc123abc123', os: 'Android', osVersion: '14', model: 'Pixel 8')
            .headers,
      );
      expect(seen.headers['X-HWID'], 'abc123abc123');
      expect(seen.headers['X-Device-OS'], 'Android');
      expect(seen.headers['X-Ver-OS'], '14');
      expect(seen.headers['X-Device-Model'], 'Pixel 8');
      expect(seen.headers['User-Agent'], 'HeaNetwork/1.0.1');

      expect(r.profiles, hasLength(1));
      expect(r.title, 'Мой VPN');
      expect(r.updateIntervalHours, 12);
      expect(r.supportUrl, 'https://t.me/support');
      expect(r.webPageUrl, 'https://panel.example/sub/abc');
      expect(r.announce, 'Работы 12 мая');
      expect(r.expire, isNull, reason: 'expire=0 means "never"');
    });

    test('a full device limit is told apart from other failures', () async {
      Future<SubscriptionException> failure(Map<String, String> headers, int status) async {
        try {
          await fetchSubscription('https://panel.example/sub/abc',
              client: MockClient((_) async => http.Response('', status, headers: headers)));
        } on SubscriptionException catch (e) {
          return e;
        }
        fail('expected a failure');
      }

      expect((await failure({'x-hwid-max-devices-reached': 'true'}, 404)).code,
          SubscriptionError.deviceLimit);
      expect((await failure({'x-hwid-limit': 'true'}, 404)).code,
          SubscriptionError.deviceLimit);
      expect((await failure({'x-hwid-not-supported': 'true'}, 404)).code,
          SubscriptionError.deviceIdRequired);
      expect((await failure({}, 404)).code, SubscriptionError.other);
      expect((await failure({}, 500)).message, contains('500'));
    });

    test('a javascript: or other odd support url is not kept', () async {
      final r = await fetchSubscription('https://panel.example/sub/abc',
          client: MockClient((_) async => http.Response(
              body([sampleLinks['tuic']!]), 200,
              headers: {'support-url': 'javascript:alert(1)'})));
      expect(r.supportUrl, isNull);
    });
  });

  group('app state', () {
    http.Client panel(List<List<String>> responses, {Map<String, String>? headers, List<http.Request>? log}) {
      var call = 0;
      return MockClient((req) async {
        log?.add(req);
        final links = responses[call < responses.length ? call : responses.length - 1];
        call++;
        return http.Response(body(links), 200, headers: headers ?? const {});
      });
    }

    test('the HWID goes out only while the setting is on', () async {
      final log = <http.Request>[];
      final state = makeState(
          populated: false,
          subscriptionClient: panel([
            [sampleLinks['vless-reality-vision']!],
          ], log: log));
      final sub = await state.addSubscription('https://panel.example/sub/abc');
      expect(log.last.headers['X-HWID'], state.device!.hwid);
      expect(log.last.headers['User-Agent'], 'HeaNetwork/${state.appVersion}');

      state.updateSettings((s) => s.sendHwid = false, affectsCore: false);
      await state.refreshSubscription(sub);
      expect(log.last.headers.containsKey('X-HWID'), isFalse);
      expect(log.last.headers.containsKey('X-Device-Model'), isFalse);
    });

    test('a refresh keeps the selection and the measured delay', () async {
      final a = sampleLinks['vless-reality-vision']!;
      final b = sampleLinks['trojan-tls']!;
      final c = sampleLinks['tuic']!;
      final state = makeState(
          populated: false,
          subscriptionClient: panel([
            [a, b],
            [c, b, a], // reordered, one added
            [a], // the selected one removed
          ]));
      final sub = await state.addSubscription('https://panel.example/sub/abc');
      final trojan = state.profiles.firstWhere((p) => p.name == 'Trojan');
      state.selectProfile(trojan.id);
      trojan.latencyMs = 77;

      await state.refreshSubscription(sub);
      expect(state.profilesOf(sub.id).map((p) => p.name), ['TUIC', 'Trojan', 'VLESS Reality']);
      // Same server, same identity: nothing the user did is lost.
      expect(state.selectedProfile!.id, trojan.id);
      expect(state.selectedProfile!.latencyMs, 77);

      await state.refreshSubscription(sub);
      expect(state.selectedProfile!.name, 'VLESS Reality',
          reason: 'the selection moves on when its server disappears');
    });

    test('a routine refresh does not ask for a reconnect', () async {
      final a = sampleLinks['vless-reality-vision']!;
      final changed = a.replaceFirst('www.microsoft.com', 'www.apple.com');
      final state = makeState(
          populated: false,
          subscriptionClient: panel([
            [a],
            [a], // identical
            [changed], // the server in use changed
          ]));
      final sub = await state.addSubscription('https://panel.example/sub/abc');
      await state.connect();
      expect(state.isConnected, isTrue);

      await state.refreshSubscription(sub);
      expect(state.pendingRestart, isFalse, reason: 'nothing changed for the live server');

      await state.refreshSubscription(sub);
      expect(state.pendingRestart, isTrue, reason: 'its settings did change');
      await state.disconnect();
    });

    test('only subscriptions whose interval elapsed are refreshed on a timer', () async {
      final log = <http.Request>[];
      final state = makeState(
          populated: false,
          subscriptionClient: panel([
            [sampleLinks['tuic']!],
          ], headers: {'profile-update-interval': '6'}, log: log));
      final sub = await state.addSubscription('https://panel.example/sub/abc');
      expect(sub.updateIntervalHours, 6);
      expect(log, hasLength(1));

      await state.refreshDueSubscriptions();
      expect(log, hasLength(1), reason: 'just updated');

      sub.updatedAt = DateTime.now().subtract(const Duration(hours: 7));
      await state.refreshDueSubscriptions();
      expect(log, hasLength(2));
      expect(sub.isDue(DateTime.now()), isFalse);
    });

    test('refresh-all reports which subscription failed and why', () async {
      var healthy = true;
      final state = makeState(
          populated: false,
          subscriptionClient: MockClient((req) async => healthy
              ? http.Response(body([sampleLinks['tuic']!]), 200)
              : http.Response('', 404, headers: {'x-hwid-max-devices-reached': 'true'})));
      final sub = await state.addSubscription('https://panel.example/sub/abc');
      state.renameSubscription(sub, 'Работа');
      expect(await state.refreshAllSubscriptions(), isEmpty);

      healthy = false;
      final failures = await state.refreshAllSubscriptions();
      expect(failures.single.code, SubscriptionError.deviceLimit);
      expect(failures.single.message, startsWith('Работа:'));
      // The servers that were there stay usable.
      expect(state.profilesOf(sub.id), hasLength(1));
      expect(state.refreshingSubscriptions, isFalse);
    });

    test('settings survive with the new fields', () {
      final s = AppSettings(closeAction: CloseAction.exit, compactView: true, sendHwid: false);
      final again = AppSettings.fromJson(jsonDecode(jsonEncode(s.toJson())) as Map<String, dynamic>);
      expect(again.closeAction, CloseAction.exit);
      expect(again.compactView, isTrue);
      expect(again.sendHwid, isFalse);
      expect(again.installId, s.installId);
      // A settings file from 0.1 has none of them.
      final old = AppSettings.fromJson({'minimizeToTray': false});
      expect(old.closeAction, CloseAction.ask);
      expect(old.sendHwid, isTrue);
      expect(old.installId, isNotEmpty);
    });
  });

  group('receiving from a phone', () {
    test('picks a reachable address, never a tunnel', () {
      InternetAddress ip(String a) => InternetAddress(a);
      expect(
          pickLanAddress([
            ('tun_ihwslhcbo', ip('172.19.0.1')),
            ('tun0', ip('172.29.117.1')),
            ('Ethernet', ip('10.100.21.30')),
          ]),
          '10.100.21.30');
      expect(
          pickLanAddress([
            ('rmnet0', ip('10.20.30.40')),
            ('wlan0', ip('192.168.1.23')),
          ]),
          '192.168.1.23',
          reason: 'Wi-Fi before mobile data');
      expect(pickLanAddress([('eth0', ip('203.0.113.5'))]), isNull,
          reason: 'a public address is not a LAN');
      expect(pickLanAddress([('tun0', ip('10.0.0.2'))]), isNull);
    });

    test('pairing links are told apart from subscriptions', () {
      expect(isPairingUrl('http://192.168.1.23:40123/hea/k3j4h5k3j4h5k3j4h5k3'), isTrue);
      expect(isPairingUrl('https://panel.example/sub/abc'), isFalse);
      expect(isPairingUrl('http://192.168.1.23:40123/sub/abc'), isFalse);
      expect(isPairingUrl('vless://x@y:1'), isFalse);
    });

    test('the page accepts a submission only with the token', () async {
      final receiver = (await LanReceiver.start(address: '127.0.0.1'))!;
      addTearDown(receiver.close);
      expect(isPairingUrl(receiver.url), isTrue);
      final got = <String>[];
      receiver.received.listen(got.add);

      final page = await http.get(Uri.parse(receiver.url));
      expect(page.statusCode, 200);
      expect(page.body, contains('<textarea'));
      expect(page.headers['content-type'], contains('text/html'));

      // What the phone app sends after scanning the code.
      await sendToDevice(receiver.url, 'https://panel.example/sub/abc\nvless://x');
      // What the browser form sends.
      final form = await http.post(Uri.parse(receiver.url),
          body: {'text': sampleLinks['tuic']!});
      expect(form.statusCode, 200);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(got, ['https://panel.example/sub/abc\nvless://x', sampleLinks['tuic']!]);

      // A guess at the address without the token gets nothing in.
      final wrong = Uri.parse(receiver.url.replaceFirst(RegExp(r'[^/]+$'), 'wrong-token-wrong-token'));
      expect((await http.get(wrong)).statusCode, 404);
      expect((await http.post(wrong, body: {'text': 'vless://evil'})).statusCode, 404);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(got, hasLength(2));

      // Oversized bodies are refused rather than buffered.
      final big = await http.post(Uri.parse(receiver.url), body: 'x' * (300 * 1024));
      expect(big.statusCode, 413);
    });
  });
}

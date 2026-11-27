import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/app.dart';
import 'package:heanetwork/core/config/config_builder.dart';
import 'package:heanetwork/core/models/settings.dart';
import 'package:heanetwork/core/models/ssh.dart';
import 'package:heanetwork/core/services/ssh_connector.dart';
import 'package:heanetwork/core/services/ssh_transfer.dart';
import 'package:heanetwork/platform/windows/win32.dart' as win32;
import 'package:heanetwork/ui/shell.dart';
import 'package:heanetwork/ui/ssh_themes.dart';

import 'support.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  group('SSH models and store', () {
    test('feature flag defaults to false and persists', () {
      final s = AppSettings();
      expect(s.sshClientEnabled, isFalse);
      expect(s.sshRouteViaProxy, isFalse);
      expect(s.sshTerminalTheme, 'default');

      s
        ..sshClientEnabled = true
        ..sshRouteViaProxy = true
        ..sshTerminalTheme = 'dracula';
      final restored = AppSettings.fromJson(s.toJson());
      expect(restored.sshClientEnabled, isTrue);
      expect(restored.sshRouteViaProxy, isTrue);
      expect(restored.sshTerminalTheme, 'dracula');
    });

    test('terminal theme presets have 10 unique entries and safe fallback', () {
      expect(sshTerminalThemes, hasLength(10));
      final ids = {for (final t in sshTerminalThemes) t.id};
      expect(ids, hasLength(10));
      expect(sshTerminalThemeById('dracula').name, 'Dracula');
      expect(sshTerminalThemeById('nonexistent').id, 'default');
    });

    test('SshStore saves metadata and encrypted secrets separately', () async {
      final dir = Directory.systemTemp.createTempSync('hea_ssh_store_');
      addTearDown(() => dir.deleteSync(recursive: true));

      final xorCodec = SshSecretCodec(
        protect: (b) => Uint8List.fromList([for (final x in b) x ^ 0x5A]),
        unprotect: (b) => Uint8List.fromList([for (final x in b) x ^ 0x5A]),
      );

      final store = SshStore(dir, codec: xorCodec);
      await store.load();
      final host = SshHost(
        id: 'h1',
        name: 'VPS',
        host: '1.2.3.4',
        port: 2222,
        username: 'admin',
      );
      store.data.hosts.add(host);
      store.data.snippets.add(SshSnippet(
        id: 's1',
        name: 'Restart',
        command: 'systemctl restart x-ui',
      ));
      store.secrets.passwords['h1'] = 'super-secret';
      await store.save();

      // Metadata file must not contain the secret.
      final metaText = File('${dir.path}${Platform.pathSeparator}ssh.json')
          .readAsStringSync();
      expect(metaText, isNot(contains('super-secret')));

      final reloaded = SshStore(dir, codec: xorCodec);
      await reloaded.load();
      expect(reloaded.data.hosts.single.host, '1.2.3.4');
      expect(reloaded.data.hosts.single.port, 2222);
      expect(reloaded.data.snippets.single.command, 'systemctl restart x-ui');
      expect(reloaded.secrets.passwords['h1'], 'super-secret');
    });

    test('Windows DPAPI round-trips secrets', () {
      final plain = Uint8List.fromList(utf8.encode('dpapi-secret-value'));
      final cipher = win32.dpapiProtect(plain);
      expect(cipher, isNotNull);
      expect(cipher, isNot(equals(plain)));
      final decrypted = win32.dpapiUnprotect(cipher!);
      expect(decrypted, equals(plain));
    }, skip: !Platform.isWindows);
  });

  group('SSH connector & Ed25519 keygen', () {
    test('generateEd25519KeyPair produces a PEM readable by dartssh2',
        () async {
      final pair = await generateEd25519KeyPair(comment: 'test@hea');
      expect(pair.privateKey, contains('BEGIN OPENSSH PRIVATE KEY'));
      expect(pair.publicKey, startsWith('ssh-ed25519 '));
      expect(pair.publicKey, endsWith(' test@hea'));

      final parsed = SSHKeyPair.fromPem(pair.privateKey);
      expect(parsed, hasLength(1));
      expect(parsed.first.type, 'ssh-ed25519');
      expect(extractPublicKeyFromPem(pair.privateKey),
          startsWith('ssh-ed25519 '));
    });

    test('connectViaSocks5 completes handshake and preserves trailing bytes',
        () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(server.close);

      final receivedTarget = Completer<String>();
      server.listen((client) {
        final buf = <int>[];
        var stage = 0;
        client.listen((chunk) {
          buf.addAll(chunk);
          if (stage == 0 && buf.length >= 3) {
            expect(buf.sublist(0, 3), [0x05, 0x01, 0x00]);
            buf.removeRange(0, 3);
            stage = 1;
            client.add([0x05, 0x00]);
          }
          if (stage == 1 && buf.length >= 5) {
            final len = buf[4];
            if (buf.length >= 5 + len + 2) {
              final host = utf8.decode(buf.sublist(5, 5 + len));
              final port = (buf[5 + len] << 8) | buf[6 + len];
              receivedTarget.complete('$host:$port');
              stage = 2;
              // Send SOCKS5 OK reply plus immediate SSH banner in one write.
              client.add([
                0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0, 22,
                ...utf8.encode('SSH-2.0-Fake\r\n'),
              ]);
            }
          }
        });
      });

      final sshSock = await connectViaSocks5(
        proxyHost: '127.0.0.1',
        proxyPort: server.port,
        targetHost: 'example.org',
        targetPort: 2222,
      );
      addTearDown(sshSock.destroy);

      expect(await receivedTarget.future, 'example.org:2222');
      final firstChunk = await sshSock.stream.first;
      expect(utf8.decode(firstChunk), 'SSH-2.0-Fake\r\n');
    });
  });

  group('SSH encrypted transfer (bundle & LAN)', () {
    test('encode/decode round-trip, wrong PIN rejected, merge avoids dupes',
        () async {
      final srcData = SshData(
        hosts: [
          SshHost(
            id: 'h1',
            name: 'Server 1',
            host: '10.0.0.1',
            authType: SshAuthType.key,
            keyId: 'k1',
            linkedProfileId: 'vpn-1',
          ),
        ],
        keys: [SshKey(id: 'k1', name: 'Main Key', publicKey: 'ssh-ed25519 AA')],
        snippets: [
          SshSnippet(id: 'sn1', name: 'Status', command: 'uptime'),
        ],
      );
      final srcSecrets = SshSecrets(
        privateKeys: {'k1': 'PRIVATE-KEY-DATA'},
      );

      final payload = buildTransferPayload(
        data: srcData,
        secrets: srcSecrets,
        hostIds: {'h1'},
        keyIds: {}, // k1 must be pulled automatically because h1 references it
        snippetIds: {'sn1'},
        includeSecrets: true,
      );

      final encoded = await encodeSshBundle(payload, '123456');
      final link = toSshImportLink(encoded);
      expect(isSshBundleText(link), isTrue);

      expect(await decodeSshBundle(link, '000000'), isNull);
      final decoded = await decodeSshBundle(link, '123456');
      expect(decoded, isNotNull);
      expect(decoded!.keys.single.id, 'k1');
      expect(decoded.secrets.privateKeys['k1'], 'PRIVATE-KEY-DATA');

      final dstData = SshData();
      final dstSecrets = SshSecrets();
      final first = decoded.mergeInto(dstData, dstSecrets);
      expect(first, (hosts: 1, keys: 1, snippets: 1));
      expect(dstData.hosts.single.linkedProfileId, isNull);

      // Second merge must not duplicate or overwrite.
      final second = decoded.mergeInto(dstData, dstSecrets);
      expect(second, (hosts: 0, keys: 0, snippets: 0));
    });

    test('SshLanSender serves encrypted bundle over loopback', () async {
      final payload = SshTransferPayload(
        hosts: [SshHost(id: 'h1', name: 'LAN Host', host: '1.1.1.1')],
        keys: [],
        snippets: [],
        secrets: SshSecrets(passwords: {'h1': 'pw'}),
      );
      final sender = await SshLanSender.start(
        payload: payload,
        pin: '654321',
        address: '127.0.0.1',
        broadcast: false,
      );
      expect(sender, isNotNull);
      addTearDown(sender!.close);

      final raw = await HttpOverrides.runWithHttpOverrides(
        () => fetchSshBundleFromLan(sender.address),
        _RealHttpOverrides(),
      );
      final decoded = await decodeSshBundle(raw, '654321');
      expect(decoded, isNotNull);
      expect(decoded!.hosts.single.name, 'LAN Host');
      expect(decoded.secrets.passwords['h1'], 'pw');
    });
  });

  group('SSH visibility and UI gating', () {
    testWidgets('SSH tab is hidden by default on Windows and appears when enabled',
        (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final state = makeState(platform: CorePlatform.windows);
      state.settings.locale = 'ru';
      await tester.pumpWidget(HeaApp(state: state, home: const Shell()));
      await tester.pump();

      expect(find.text('SSH'), findsNothing);

      await tester.runAsync(() => state.setSshClientEnabled(true));
      await tester.pump();

      expect(find.text('SSH'), findsOneWidget);
      await tester.tap(find.text('SSH'));
      await tester.pump();

      expect(find.text('Серверы VPN'), findsOneWidget);
      expect(find.text('Добавить хост'), findsOneWidget);

      await tester.runAsync(() => state.setSshClientEnabled(false));
      await tester.pump();
      expect(find.text('SSH'), findsNothing);
    });

    testWidgets('SSH tab never appears on Android even if flag is true',
        (tester) async {
      tester.view.physicalSize = const Size(400, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final state = makeState(platform: CorePlatform.android);
      state.settings
        ..locale = 'ru'
        ..sshClientEnabled = true;
      await tester.pumpWidget(HeaApp(state: state, home: const Shell()));
      await tester.pump();

      expect(find.text('SSH'), findsNothing);
    });
  });
}

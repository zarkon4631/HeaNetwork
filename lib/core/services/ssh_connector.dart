import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dartssh2/dartssh2.dart';

/// Wraps a raw [dart:io] [Socket] as an [SSHSocket], optionally carrying
/// leftover bytes read right after a SOCKS5 handshake.
class _WrappedSshSocket implements SSHSocket {
  _WrappedSshSocket(this._socket, this._stream);

  final Socket _socket;
  final Stream<Uint8List> _stream;

  @override
  Stream<Uint8List> get stream => _stream;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> close() => _socket.close();

  @override
  Future<void> get done => _socket.done;

  @override
  void destroy() => _socket.destroy();

  @override
  Future<void> flush() => _socket.flush();
}

/// Opens a TCP connection to [host]:[port] through a local no-auth SOCKS5
/// proxy (such as sing-box's `mixed-in`) and returns it as an [SSHSocket].
Future<SSHSocket> connectViaSocks5({
  required String proxyHost,
  required int proxyPort,
  required String targetHost,
  required int targetPort,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final socket = await Socket.connect(proxyHost, proxyPort, timeout: timeout);
  final out = StreamController<Uint8List>();
  final buf = BytesBuilder(copy: false);
  final ready = Completer<void>();

  var stage = 0; // 0 = method reply, 1 = connect reply, 2 = passthrough

  void fail(Object error) {
    if (!ready.isCompleted) ready.completeError(error);
    if (!out.isClosed) {
      out.addError(error);
      out.close();
    }
    socket.destroy();
  }

  void sendConnectRequest() {
    final hostBytes = utf8.encode(targetHost);
    if (hostBytes.length > 255) {
      fail(const SocketException('SOCKS5 host name too long'));
      return;
    }
    final req = BytesBuilder(copy: false)
      ..add([0x05, 0x01, 0x00, 0x03, hostBytes.length])
      ..add(hostBytes)
      ..add([(targetPort >> 8) & 0xFF, targetPort & 0xFF]);
    socket.add(req.takeBytes());
  }

  void processHandshake() {
    while (stage < 2) {
      final data = buf.toBytes();
      if (stage == 0) {
        if (data.length < 2) return;
        if (data[0] != 0x05 || data[1] != 0x00) {
          fail(SocketException(
              'SOCKS5 auth failed: ${data[0]}, ${data[1]}'));
          return;
        }
        buf.clear();
        if (data.length > 2) buf.add(data.sublist(2));
        stage = 1;
        sendConnectRequest();
      } else if (stage == 1) {
        if (data.length < 4) return;
        if (data[0] != 0x05 || data[1] != 0x00) {
          fail(SocketException('SOCKS5 connect rejected: code ${data[1]}'));
          return;
        }
        final atyp = data[3];
        int need;
        if (atyp == 0x01) {
          need = 4 + 4 + 2; // IPv4
        } else if (atyp == 0x04) {
          need = 4 + 16 + 2; // IPv6
        } else if (atyp == 0x03) {
          if (data.length < 5) return;
          need = 4 + 1 + data[4] + 2; // domain
        } else {
          fail(SocketException('SOCKS5 unknown address type $atyp'));
          return;
        }
        if (data.length < need) return;
        final rest = data.length > need ? data.sublist(need) : Uint8List(0);
        buf.clear();
        stage = 2;
        if (!ready.isCompleted) ready.complete();
        if (rest.isNotEmpty) out.add(rest);
      }
    }
  }

  socket.listen(
    (chunk) {
      if (stage == 2) {
        if (!out.isClosed) out.add(chunk);
        return;
      }
      buf.add(chunk);
      processHandshake();
    },
    onError: (Object e, StackTrace st) {
      if (!ready.isCompleted) ready.completeError(e, st);
      if (!out.isClosed) out.addError(e, st);
    },
    onDone: () {
      if (!ready.isCompleted) {
        ready.completeError(
            const SocketException('SOCKS5 proxy closed during handshake'));
      }
      if (!out.isClosed) out.close();
    },
  );

  // Greeting: SOCKS5, 1 method: no auth (0x00).
  socket.add(const [0x05, 0x01, 0x00]);
  await ready.future.timeout(timeout, onTimeout: () {
    socket.destroy();
    throw const SocketException('SOCKS5 handshake timed out');
  });
  return _WrappedSshSocket(socket, out.stream);
}

/// Opens an [SSHSocket] either directly (optionally bound to [directBindAddress]
/// to bypass an active TUN adapter) or through the local sing-box SOCKS5 proxy.
Future<SSHSocket> openSshSocket({
  required String host,
  required int port,
  required bool viaProxy,
  int? mixedPort,
  String? directBindAddress,
  Duration timeout = const Duration(seconds: 15),
}) async {
  if (viaProxy) {
    if (mixedPort == null || mixedPort <= 0) {
      throw const SocketException('VPN proxy is not running');
    }
    return connectViaSocks5(
      proxyHost: '127.0.0.1',
      proxyPort: mixedPort,
      targetHost: host,
      targetPort: port,
      timeout: timeout,
    );
  }
  if (directBindAddress != null && directBindAddress.isNotEmpty) {
    final bind = InternetAddress.tryParse(directBindAddress);
    if (bind != null) {
      final socket = await Socket.connect(
        host,
        port,
        sourceAddress: bind,
        timeout: timeout,
      );
      return _WrappedSshSocket(socket, socket);
    }
  }
  return SSHSocket.connect(host, port, timeout: timeout);
}

/// Formats a binary host key fingerprint as colon-separated hex (`ab:cd:...`).
String formatFingerprint(Uint8List bytes) => [
      for (final b in bytes) b.toRadixString(16).padLeft(2, '0'),
    ].join(':');

/// Extracts the OpenSSH `authorized_keys` public key line from a private key
/// PEM, or returns an empty string if it cannot be parsed.
String extractPublicKeyFromPem(String pemText, [String? passphrase]) {
  try {
    final pairs = SSHKeyPair.fromPem(pemText, passphrase);
    if (pairs.isEmpty) return '';
    final pair = pairs.first;
    final pub = pair.toPublicKey();
    return '${pair.name} ${base64.encode(pub.encode())}';
  } on Object {
    return '';
  }
}

/// Generates a new unencrypted OpenSSH Ed25519 key pair using `cryptography`.
/// Returns `(privateKeyPem, publicKeyLine)`.
Future<({String privateKey, String publicKey})> generateEd25519KeyPair({
  String comment = 'heanetwork',
}) async {
  final pair = await Ed25519().newKeyPair();
  final seed = await pair.extractPrivateKeyBytes();
  final pub = (await pair.extractPublicKey()).bytes;

  Uint8List sshString(List<int> bytes) {
    final out = ByteData(4 + bytes.length);
    out.setUint32(0, bytes.length);
    final list = out.buffer.asUint8List();
    list.setRange(4, 4 + bytes.length, bytes);
    return list;
  }

  final keyType = utf8.encode('ssh-ed25519');
  final pubBlob = (BytesBuilder(copy: false)
        ..add(sshString(keyType))
        ..add(sshString(pub)))
      .takeBytes();

  final check = Random.secure().nextInt(0x7FFFFFFF);
  final checkBytes = ByteData(8)
    ..setUint32(0, check)
    ..setUint32(4, check);
  final privSection = BytesBuilder(copy: false)
    ..add(checkBytes.buffer.asUint8List())
    ..add(sshString(keyType))
    ..add(sshString(pub))
    ..add(sshString([...seed, ...pub])) // 64-byte OpenSSH ed25519 secret
    ..add(sshString(utf8.encode(comment)));
  // Pad to 8-byte cipher block size (1, 2, 3...).
  var pad = 1;
  while (privSection.length % 8 != 0) {
    privSection.addByte(pad++);
  }

  final keyCount = ByteData(4)..setUint32(0, 1);
  final body = (BytesBuilder(copy: false)
        ..add(utf8.encode('openssh-key-v1\x00'))
        ..add(sshString(utf8.encode('none'))) // ciphername
        ..add(sshString(utf8.encode('none'))) // kdfname
        ..add(sshString(const [])) // kdfoptions
        ..add(keyCount.buffer.asUint8List())
        ..add(sshString(pubBlob))
        ..add(sshString(privSection.takeBytes())))
      .takeBytes();

  final b64 = base64.encode(body);
  final lines = <String>[
    '-----BEGIN OPENSSH PRIVATE KEY-----',
    for (var i = 0; i < b64.length; i += 70)
      b64.substring(i, min(i + 70, b64.length)),
    '-----END OPENSSH PRIVATE KEY-----',
  ];
  return (
    privateKey: '${lines.join('\n')}\n',
    publicKey: 'ssh-ed25519 ${base64.encode(pubBlob)} $comment',
  );
}

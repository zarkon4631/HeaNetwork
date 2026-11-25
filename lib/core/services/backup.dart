import 'dart:convert';

import 'package:cryptography/cryptography.dart';

const _encryptedPrefix = 'HEANETWORK-BACKUP-ENCRYPTED-1:';
const _iterations = 210000;
const _saltLength = 16;
const _nonceLength = 12;
const _macLength = 16;
final _aad = utf8.encode('HeaNetwork backup v1');

bool isBackupEncrypted(String text) =>
    text.trimLeft().startsWith(_encryptedPrefix);

Future<String> encodeBackup(String plain, String password) async {
  if (password.isEmpty) return plain;
  final salt = SecretKeyData.random(length: _saltLength).bytes;
  final key = await _deriveKey(password, salt);
  try {
    final box = await AesGcm.with256bits().encrypt(
      utf8.encode(plain),
      secretKey: key,
      aad: _aad,
    );
    final envelope = {
      'version': 1,
      'kdf': 'PBKDF2-HMAC-SHA256',
      'iterations': _iterations,
      'salt': base64.encode(salt),
      'cipher': 'AES-256-GCM',
      'nonce': base64.encode(box.nonce),
      'cipherText': base64.encode(box.cipherText),
      'mac': base64.encode(box.mac.bytes),
    };
    return '$_encryptedPrefix${base64.encode(utf8.encode(jsonEncode(envelope)))}';
  } finally {
    key.destroy();
  }
}

Future<Map<String, dynamic>?> decodeBackup(
  String text, {
  String? password,
}) async {
  final trimmed = text.trim();
  if (!trimmed.startsWith(_encryptedPrefix)) return _plainBackup(trimmed);
  if (password == null || password.isEmpty) return null;

  SecretKey? key;
  try {
    final decoded = jsonDecode(
      utf8.decode(base64.decode(trimmed.substring(_encryptedPrefix.length))),
    );
    if (decoded is! Map ||
        decoded['version'] != 1 ||
        decoded['kdf'] != 'PBKDF2-HMAC-SHA256' ||
        decoded['iterations'] != _iterations ||
        decoded['cipher'] != 'AES-256-GCM') {
      return null;
    }
    final salt = base64.decode(decoded['salt'] as String);
    final nonce = base64.decode(decoded['nonce'] as String);
    final cipherText = base64.decode(decoded['cipherText'] as String);
    final mac = base64.decode(decoded['mac'] as String);
    if (salt.length != _saltLength ||
        nonce.length != _nonceLength ||
        mac.length != _macLength) {
      return null;
    }

    key = await _deriveKey(password, salt);
    final clearText = await AesGcm.with256bits().decrypt(
      SecretBox(cipherText, nonce: nonce, mac: Mac(mac)),
      secretKey: key,
      aad: _aad,
    );
    return _plainBackup(utf8.decode(clearText));
  } on Object {
    return null;
  } finally {
    key?.destroy();
  }
}

Map<String, dynamic>? _plainBackup(String text) {
  try {
    final decoded = jsonDecode(text);
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } on Object {
    return null;
  }
}

Future<SecretKey> _deriveKey(String password, List<int> salt) {
  final passwordKey = SecretKeyData(
    utf8.encode(password),
    overwriteWhenDestroyed: true,
  );
  return Pbkdf2.hmacSha256(iterations: _iterations, bits: 256)
      .deriveKey(secretKey: passwordKey, nonce: salt)
      .whenComplete(passwordKey.destroy);
}

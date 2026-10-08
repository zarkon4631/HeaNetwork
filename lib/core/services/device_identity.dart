import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import '../../platform/windows/win32.dart' as win32;

/// What this device tells a subscription server about itself, so a panel
/// can count and limit devices per subscription (3x-ui "HWID").
///
/// Header names follow the convention 3x-ui reads: `X-HWID`, `X-Device-OS`,
/// `X-Ver-OS`, `X-Device-Model`.
class DeviceIdentity {
  const DeviceIdentity({
    required this.hwid,
    required this.os,
    required this.osVersion,
    required this.model,
    this.isTv = false,
  });

  /// Stable for this device, and a hash: the raw machine id never leaves it.
  final String hwid;
  final String os;
  final String osVersion;
  final String model;

  /// Android TV or another big-screen, remote-controlled device.
  final bool isTv;

  Map<String, String> get headers => {
        'X-HWID': hwid,
        'X-Device-OS': os,
        'X-Ver-OS': osVersion,
        'X-Device-Model': model,
      };

  /// Derives the id sent to servers from a raw machine id.
  static String hash(String raw) =>
      sha256.convert(utf8.encode('HeaNetwork:$raw')).toString().substring(0, 32);

  /// `"Windows 11 Pro" 10.0 (Build 26100)` -> `10.0.26100`.
  static String windowsVersion(String raw) {
    final m = RegExp(r'(\d+\.\d+) \(Build (\d+)\)').firstMatch(raw);
    return m == null ? raw : '${m.group(1)}.${m.group(2)}';
  }

  /// Reads the platform's device id, falling back to [installId] (random,
  /// per install) when the OS does not provide one.
  static Future<DeviceIdentity> detect({required String installId}) async {
    if (Platform.isWindows) {
      String? machine;
      try {
        machine = const win32.RegistryValue(
          r'SOFTWARE\Microsoft\Cryptography',
          'MachineGuid',
          hive: win32.hkeyLocalMachine,
        ).readString();
      } on Object {
        machine = null;
      }
      return DeviceIdentity(
        hwid: hash(machine?.isNotEmpty == true ? machine! : installId),
        os: 'Windows',
        osVersion: windowsVersion(Platform.operatingSystemVersion),
        model: Platform.localHostname,
      );
    }
    if (Platform.isAndroid) {
      try {
        final info = await const MethodChannel('hea/core')
            .invokeMapMethod<String, Object?>('device');
        final id = '${info?['id'] ?? ''}';
        return DeviceIdentity(
          hwid: hash(id.isNotEmpty ? id : installId),
          os: info?['tv'] == true ? 'Android TV' : 'Android',
          osVersion: '${info?['release'] ?? ''}',
          model: '${info?['model'] ?? ''}',
          isTv: info?['tv'] == true,
        );
      } on Object {
        // Fall through to the generic identity.
      }
    }
    return DeviceIdentity(
      hwid: hash(installId),
      os: Platform.operatingSystem,
      osVersion: Platform.operatingSystemVersion,
      model: '',
    );
  }
}

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

  /// The headers carrying this identity. HTTP carries printable ASCII only,
  /// and one letter outside it makes the client refuse the whole request,
  /// while a device can bear a name in any alphabet: the one its owner gave
  /// the phone, a computer called "ПК-Ивана". Such a value goes with what
  /// is left of it, and one with nothing left does not go at all.
  Map<String, String> get headers => {
        for (final (name, value) in [
          ('X-HWID', hwid),
          ('X-Device-OS', os),
          ('X-Ver-OS', osVersion),
          ('X-Device-Model', model),
        ])
          if (headerText(value) case final text when text.isNotEmpty) name: text,
      };

  /// [value] as an HTTP header can carry it.
  static String headerText(String value) => value
      .replaceAll(RegExp(r'[^\x20-\x7E]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^[\s\-_.,:;]+|[\s\-_.,:;]+$'), '');

  /// Derives the id sent to servers from a raw machine id.
  static String hash(String raw) =>
      sha256.convert(utf8.encode('HeaNetwork:$raw')).toString().substring(0, 32);

  /// `"Windows 11 Pro" 10.0 (Build 26100)` -> `10.0.26100`.
  static String windowsVersion(String raw) {
    final m = RegExp(r'(\d+\.\d+) \(Build (\d+)\)').firstMatch(raw);
    return m == null ? raw : '${m.group(1)}.${m.group(2)}';
  }

  /// `11 24H2` from the build number and the release name Windows keeps in
  /// the registry: the version people know it by, not `10.0.26100`.
  static String windowsRelease(String raw, String? displayVersion) {
    final build = int.tryParse(RegExp(r'Build (\d+)').firstMatch(raw)?.group(1) ?? '');
    if (build == null) return windowsVersion(raw);
    final major = build >= 22000 ? '11' : '10';
    final release = displayVersion?.trim() ?? '';
    return release.isEmpty ? '$major (build $build)' : '$major $release';
  }

  // What firmware reports when the maker never filled the field in.
  static bool _placeholder(String? v) {
    final t = (v ?? '').trim().toLowerCase();
    return t.isEmpty ||
        const {
          'system product name', 'system manufacturer', 'system version',
          'to be filled by o.e.m.', 'default string', 'o.e.m.', 'oem',
          'not applicable', 'not specified', 'none', 'invalid', 'unknown',
          'type1productconfigid', 'all series', 'x.x', '1.0',
        }.contains(t);
  }

  static String _brand(String maker) {
    final m = maker.trim();
    final l = m.toLowerCase();
    for (final (key, name) in const [
      ('asus', 'ASUS'), ('micro-star', 'MSI'), ('msi', 'MSI'),
      ('hewlett', 'HP'), ('hp', 'HP'), ('dell', 'Dell'),
      ('gigabyte', 'Gigabyte'), ('lenovo', 'Lenovo'), ('acer', 'Acer'),
      ('samsung', 'Samsung'), ('huawei', 'Huawei'), ('honor', 'Honor'),
      ('microsoft', 'Microsoft'), ('asrock', 'ASRock'), ('xiaomi', 'Xiaomi'),
      ('apple', 'Apple'), ('intel', 'Intel'), ('biostar', 'Biostar'),
    ]) {
      if (l.startsWith(key)) return name;
    }
    return m.replaceAll(
        RegExp(r',?\s+(inc|corp|corporation|co|ltd|llc)\.?.*$', caseSensitive: false), '');
  }

  /// The name a computer is sold under, from what its firmware reports.
  /// A laptop names itself (`ASUS ROG Strix G15`). A desktop reports a
  /// placeholder or a bare part number (`MS-7D22`) there, so its motherboard
  /// stands in (`MSI H510M-A PRO`). With nothing usable, the [hostname].
  static String windowsModel({
    String? manufacturer,
    String? product,
    String? version,
    String? boardManufacturer,
    String? boardProduct,
    required String hostname,
  }) {
    String join(String? maker, String name) {
      // Drop a part number in brackets after the name: "PRO (MS-7D22)".
      final n = name.replaceAll(RegExp(r'\s*\([^)]*\)\s*$'), '').trim();
      if (_placeholder(maker)) return n;
      final brand = _brand(maker!);
      return n.toLowerCase().startsWith(brand.toLowerCase()) ? n : '$brand $n';
    }

    // Lenovo keeps a part number in the product and the name in the version.
    if (!_placeholder(manufacturer) &&
        manufacturer!.toLowerCase().startsWith('lenovo') &&
        !_placeholder(version)) {
      return join(manufacturer, version!);
    }
    final board = _placeholder(boardProduct) ? null : boardProduct!.trim();
    final own = _placeholder(product) ? null : product!.trim();
    // The board's name says more when the product is only its part number.
    if (board != null &&
        (own == null || (board.length > own.length && board.contains(own)))) {
      return join(boardManufacturer ?? manufacturer, board);
    }
    if (own != null) return join(manufacturer, own);
    return hostname;
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
      String? reg(String path, String name) {
        try {
          return win32.RegistryValue(path, name, hive: win32.hkeyLocalMachine)
              .readString();
        } on Object {
          return null;
        }
      }

      const bios = r'HARDWARE\DESCRIPTION\System\BIOS';
      return DeviceIdentity(
        hwid: hash(machine?.isNotEmpty == true ? machine! : installId),
        os: 'Windows',
        osVersion: windowsRelease(Platform.operatingSystemVersion,
            reg(r'SOFTWARE\Microsoft\Windows NT\CurrentVersion', 'DisplayVersion')),
        model: windowsModel(
          manufacturer: reg(bios, 'SystemManufacturer'),
          product: reg(bios, 'SystemProductName'),
          version: reg(bios, 'SystemVersion'),
          boardManufacturer: reg(bios, 'BaseBoardManufacturer'),
          boardProduct: reg(bios, 'BaseBoardProduct'),
          hostname: Platform.localHostname,
        ),
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

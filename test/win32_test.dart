@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/platform/windows/win32.dart';

void main() {
  test('running executables include this test process', () {
    final list = runningExecutables();
    expect(list.length, greaterThan(5));
    final self = Platform.resolvedExecutable.toLowerCase();
    expect(list.map((e) => e.toLowerCase()), contains(self));
    expect(list.toSet().length, list.length, reason: 'no duplicates');
  });

  test('file description and icon of explorer.exe', () {
    final explorer = '${Platform.environment['WINDIR']}\\explorer.exe';
    expect(fileDescription(explorer), isNotEmpty);
    expect(fileDescription(r'C:\does\not\exist.exe'), isNull);

    final icon = fileIcon(explorer)!;
    expect(icon.width, 32);
    expect(icon.height, 32);
    expect(icon.bgra.length, 32 * 32 * 4);
    expect(icon.bgra.any((b) => b != 0), isTrue, reason: 'not a blank bitmap');
    // Premultiplied: no colour channel may exceed its alpha.
    for (var i = 0; i < icon.bgra.length; i += 4) {
      final a = icon.bgra[i + 3];
      expect(icon.bgra[i] <= a && icon.bgra[i + 1] <= a && icon.bgra[i + 2] <= a,
          isTrue);
    }
  });

  test('registry values round-trip under a scratch key', () {
    const path = r'Software\HeaNetworkTest';
    const s = RegistryValue(path, 'Text');
    const d = RegistryValue(path, 'Number');
    addTearDown(() {
      s.delete();
      d.delete();
      deleteRegistryKey(path);
    });

    expect(s.read(), isNull);
    expect(s.writeString('127.0.0.1:2080 — прокси'), isTrue);
    expect(s.readString(), '127.0.0.1:2080 — прокси');
    expect(d.writeInt(1), isTrue);
    expect(d.readInt(), 1);
    expect(d.readString(), isNull);
    expect(s.delete(), isTrue);
    expect(s.read(), isNull);
    expect(s.delete(), isTrue, reason: 'deleting a missing value is fine');
  });

  test('elevation query does not throw', () {
    expect(isElevated(), isA<bool>());
  });
}

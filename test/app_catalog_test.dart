@TestOn('windows')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/core/services/app_catalog.dart';

void main() {
  testWidgets('an executable icon decodes into an image', (tester) async {
    final path = '${Platform.environment['WINDIR']}\\explorer.exe';
    final image = await tester.runAsync(() => AppCatalog.icon(processPath: path));
    expect(image, isNotNull);
    expect(image!.width, 32);
  });

  test('catalog lists running apps with names', () async {
    final apps = await AppCatalog.list();
    expect(apps, isNotEmpty);
    expect(apps.every((a) => a.name.isNotEmpty && a.processPath != null), isTrue);
    expect(apps.any((a) => a.system), isTrue);
    expect(apps.any((a) => !a.system), isTrue);
  });
}

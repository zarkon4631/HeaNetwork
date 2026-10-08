// Draws the Android TV launcher banner (320 x 180 at xhdpi) with the same
// renderer and fonts as the app, since it needs real text:
//   $env:HEA_SCREENSHOTS=1; flutter test test/tv_banner_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  setUpAll(loadTestFonts);

  testWidgets('tv banner', (tester) async {
    tester.view.physicalSize = const Size(320, 180);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    const penguin = AssetImage('assets/icons/penguin.png');
    await tester.pumpWidget(RepaintBoundary(
      key: const ValueKey('banner'),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF1E2A78), Color(0xFF2F6BFF), Color(0xFF22D3EE)],
            ),
          ),
          child: Row(
            children: const [
              SizedBox(width: 14),
              Image(image: penguin, width: 118, height: 118),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'HeaNetwork',
                  maxLines: 1,
                  style: TextStyle(
                    fontFamily: 'Roboto',
                    fontSize: 29,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.runAsync(
        () => precacheImage(penguin, tester.element(find.byType(DecoratedBox))));
    await tester.pump();
    expect(tester.takeException(), isNull);

    final boundary =
        tester.renderObject<RenderRepaintBoundary>(find.byKey(const ValueKey('banner')));
    final bytes = await tester.runAsync(() async {
      final image = await boundary.toImage();
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    });
    final file = File('android/app/src/main/res/drawable-xhdpi/tv_banner.png');
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes!);
  }, skip: Platform.environment['HEA_SCREENSHOTS'] != '1');
}

// Country flags: reading a server's country off its name, and drawing the
// flag the app keeps for it.
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heanetwork/ui/flags.dart';

void main() {
  group('the country in a server name', () {
    String? country(String name) => ServerLabel.of(name).country;

    test('a code written in capitals', () {
      expect(country('NL'), 'NL');
      expect(country('RU-2'), 'RU');
      expect(country('NL1'), 'NL');
      expect(country('[DE] Frankfurt'), 'DE');
      expect(country('VLESS | FI | Helsinki'), 'FI');
      expect(country('Reality_SE_01'), 'SE');
      expect(ServerLabel.of('RU-2').title, 'RU-2', reason: 'the name is shown as it is');
    });

    test('other spellings of a country', () {
      expect(country('UK London'), 'GB');
      expect(country('USA-3'), 'US');
      expect(country('NLD'), 'NL');
      expect(country('NSK (Timeweb)'), 'RU');
    });

    test('not every pair of capitals is a country', () {
      expect(country('VLESS WS TLS'), isNull);
      expect(country('HOME'), isNull);
      expect(country('My server'), isNull);
      expect(country('nl-1'), isNull);
      expect(country('ID 42'), isNull, reason: 'an identifier far more often than Indonesia');
      expect(country(''), isNull);
    });

    test('an emoji flag says it outright, and is drawn instead of shown', () {
      final label = ServerLabel.of('🇳🇱 Amsterdam DE');
      expect(label.country, 'NL');
      expect(label.title, 'Amsterdam DE');
      expect(ServerLabel.of('Frankfurt | 🇩🇪').title, 'Frankfurt');
      expect(ServerLabel.of('🇩🇪').title, 'DE');

      // A flag the app has no drawing for stays in the text.
      final other = ServerLabel.of('🇲🇾 Kuala Lumpur');
      expect(other.country, isNull);
      expect(other.title, '🇲🇾 Kuala Lumpur');
    });
  });

  test('every flag parses and paints, whatever the shape of the box', () {
    expect(flagSpecs.length, greaterThan(60));
    for (final code in flagSpecs.keys) {
      for (final box in const [Rect.fromLTWH(0, 0, 22.5, 15), Rect.fromLTWH(4, 2, 170, 52)]) {
        final recorder = ui.PictureRecorder();
        paintFlag(Canvas(recorder), box, code);
        recorder.endRecording().dispose();
      }
    }
    // An unknown code is simply not drawn.
    final recorder = ui.PictureRecorder();
    paintFlag(Canvas(recorder), const Rect.fromLTWH(0, 0, 30, 20), 'ZZ');
    recorder.endRecording().dispose();
  });

  testWidgets('chip and backdrop', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Row(
        children: [
          FlagChip('NL'),
          SizedBox(width: 170, height: 52, child: FlagBackdrop('JP')),
        ],
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(tester.getSize(find.byType(FlagChip)), const Size(22.5, 15));
  });
}

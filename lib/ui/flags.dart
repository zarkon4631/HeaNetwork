import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Flags by ISO 3166 code, each a list of layers separated by `;`. The app
/// draws them itself: Windows has no emoji flags, and a drawn flag can be
/// stretched into a backdrop.
///
/// A layer is `op:RRGGBB@numbers` (bands take colours only). Positions are
/// fractions of the flag's width and height; sizes marked "h" are fractions
/// of its height, so emblems keep their shape when the flag is stretched.
///   `h` / `v`  bands top to bottom / left to right, `colour*weight`
///   `r`  rectangle: left, top, right, bottom
///   `p`  polygon: x, y pairs
///   `l`  line: x1, y1, x2, y2, width (h)
///   `g`  grid of dots: left, top, right, bottom, columns, rows, radius (h)
/// and, placed at x, y plus an offset dx, dy (h):
///   `o`  disc: radius (h)
///   `u`  upper half of a disc: radius (h)
///   `s`  five-pointed star: radius (h), rotation in degrees
///   `+`  cross: half-length (h), half-thickness (h)
///   `c`  ring of stars: ring radius (h), count, star radius (h)
const flagSpecs = <String, String>{
  // Western and Northern Europe
  'NL': 'h:AE1C28,FFFFFF,21468B',
  'DE': 'h:000000,DD0000,FFCE00',
  'FR': 'v:0055A4,FFFFFF,EF4135',
  'GB': 'h:012169;l:FFFFFF@0,0,1,1,.2;l:FFFFFF@0,1,1,0,.2;l:C8102E@0,0,1,1,.07;'
      'l:C8102E@0,1,1,0,.07;+:FFFFFF@.5,.5,0,0,9,.167;+:C8102E@.5,.5,0,0,9,.1',
  'IE': 'v:169B62,FFFFFF,FF883E',
  'BE': 'v:000000,FAE042,ED2939',
  'LU': 'h:ED2939,FFFFFF,00A1DE',
  'CH': 'h:DA291C;+:FFFFFF@.5,.5,0,0,.3,.095',
  'AT': 'h:ED2939,FFFFFF,ED2939',
  'IT': 'v:009246,FFFFFF,CE2B37',
  'ES': 'h:AA151B,F1BF00*2,AA151B',
  'PT': 'v:006600*2,FF0000*3;o:FFE900@.4,.5,0,0,.2;o:FF0000@.4,.5,0,0,.13;'
      'o:FFFFFF@.4,.5,0,0,.075',
  'MT': 'v:FFFFFF,CF142B;+:9CA3AF@.13,.2,0,0,.08,.028',
  'SE': 'h:006AA7;+:FECC00@.375,.5,0,0,9,.1',
  'NO': 'h:BA0C2F;+:FFFFFF@.3636,.5,0,0,9,.125;+:00205B@.3636,.5,0,0,9,.0625',
  'DK': 'h:C8102E;+:FFFFFF@.378,.5,0,0,9,.0714',
  'FI': 'h:FFFFFF;+:003580@.361,.5,0,0,9,.136',
  'IS': 'h:02529C;+:FFFFFF@.36,.5,0,0,9,.111;+:DC1E35@.36,.5,0,0,9,.0556',
  'EE': 'h:0072CE,000000,FFFFFF',
  'LV': 'h:9E3039*2,FFFFFF,9E3039*2',
  'LT': 'h:FDB913,006A44,C1272D',
  'EU': 'h:003399;c:FFCC00@.5,.5,0,0,.32,12,.055',

  // Central and Eastern Europe
  'PL': 'h:FFFFFF,DC143C',
  'CZ': 'h:FFFFFF,D7141A;p:11457E@0,0,.5,.5,0,1',
  'SK': 'h:FFFFFF,0B4EA2,EE1C25;p:FFFFFF@.18,.22,.44,.22,.44,.6,.31,.8,.18,.6;'
      'p:EE1C25@.2,.255,.42,.255,.42,.585,.31,.76,.2,.585;'
      'r:FFFFFF@.295,.3,.325,.64;r:FFFFFF@.255,.37,.365,.42;r:FFFFFF@.24,.47,.38,.52',
  'HU': 'h:CE2939,FFFFFF,477050',
  'RO': 'v:002B7F,FCD116,CE1126',
  'MD': 'v:0046AE,FFD200,CC092F;o:B07E5B@.5,.5,0,0,.13',
  'BG': 'h:FFFFFF,00966E,D62612',
  'RS': 'h:C6363C,0C4076,FFFFFF',
  'HR': 'h:FF0000,FFFFFF,171796;p:FF0000@.41,.28,.59,.28,.59,.6,.5,.72,.41,.6;'
      'r:FFFFFF@.41,.28,.5,.44;r:FFFFFF@.5,.44,.59,.6',
  'SI': 'h:FFFFFF,005DA4,ED1C24;p:ED1C24@.15,.11,.35,.11,.35,.42,.25,.56,.15,.42;'
      'p:005DA4@.165,.135,.335,.135,.335,.41,.25,.53,.165,.41;'
      'p:FFFFFF@.185,.4,.25,.22,.315,.4',
  'GR': 'h:0D5EAF,FFFFFF,0D5EAF,FFFFFF,0D5EAF,FFFFFF,0D5EAF,FFFFFF,0D5EAF;'
      'r:0D5EAF@0,0,.3704,.5556;r:FFFFFF@.1481,0,.2222,.5556;r:FFFFFF@0,.2222,.3704,.3333',
  'AL': 'h:E41E20;p:000000@.5,.2,.54,.3,.6,.24,.58,.36,.74,.3,.63,.46,.72,.6,.6,.56,'
      '.56,.7,.5,.82,.44,.7,.4,.56,.28,.6,.37,.46,.26,.3,.42,.36,.4,.24,.46,.3',
  'CY': 'h:FFFFFF;p:D57800@.28,.46,.42,.36,.56,.33,.74,.24,.62,.38,.6,.5,.48,.56,.38,.52;'
      'o:4E5B31@.43,.74,0,0,.045;o:4E5B31@.57,.74,0,0,.045',
  'UA': 'h:0057B7,FFD700',
  'BY': 'h:CF101A*2,007C30;r:FFFFFF@0,0,.11,1;p:CF101A@.055,.04,.1,.17,.055,.3,.01,.17;'
      'p:CF101A@.055,.37,.1,.5,.055,.63,.01,.5;p:CF101A@.055,.7,.1,.83,.055,.96,.01,.83',
  'RU': 'h:FFFFFF,0039A6,D52B1E',

  // Caucasus, Central Asia, Middle East, Africa
  'GE': 'h:FFFFFF;+:FF0000@.5,.5,0,0,9,.1;+:FF0000@.25,.22,0,0,.1,.032;'
      '+:FF0000@.75,.22,0,0,.1,.032;+:FF0000@.25,.78,0,0,.1,.032;+:FF0000@.75,.78,0,0,.1,.032',
  'AM': 'h:D90012,0033A0,F2A800',
  'AZ': 'h:00B5E2,EF3340,509E2F;o:FFFFFF@.46,.5,0,0,.15;o:EF3340@.46,.5,.035,0,.125;'
      's:FFFFFF@.46,.5,.17,0,.08',
  'KZ': 'h:00AFCA;o:FEC50C@.52,.42,0,0,.17;p:FEC50C@.3,.62,.52,.7,.74,.62,.52,.82;'
      'r:FEC50C@.04,.07,.085,.93',
  'UZ': 'h:0099B5*10,CE1126*.6,FFFFFF*9,CE1126*.6,1EB53A*10;o:FFFFFF@.16,.17,0,0,.1;'
      'o:0099B5@.16,.17,.035,0,.085',
  'KG': 'h:E8112D;o:FFEF00@.5,.5,0,0,.21;o:E8112D@.5,.5,0,0,.12;o:FFEF00@.5,.5,0,0,.085',
  'TJ': 'h:CC0000*2,FFFFFF*3,006600*2;o:F8C300@.5,.5,0,0,.09',
  'TR': 'h:E30A17;o:FFFFFF@.34,.5,0,0,.25;o:E30A17@.34,.5,.0625,0,.2;'
      's:FFFFFF@.34,.5,.29,0,.125,-90',
  'IL': 'h:FFFFFF;r:0038B8@0,.125,1,.25;r:0038B8@0,.75,1,.875;'
      'l:0038B8@.5,.33,.598,.585,.03;l:0038B8@.598,.585,.402,.585,.03;'
      'l:0038B8@.402,.585,.5,.33,.03;l:0038B8@.5,.67,.598,.415,.03;'
      'l:0038B8@.598,.415,.402,.415,.03;l:0038B8@.402,.415,.5,.67,.03',
  'AE': 'h:00732F,FFFFFF,000000;r:FF0000@0,0,.25,1',
  'IR': 'h:239F40,FFFFFF,DA0000;o:DA0000@.5,.5,0,0,.09',
  'EG': 'h:CE1126,FFFFFF,000000;o:C09300@.5,.5,0,0,.08',
  'MA': 'h:C1272D;s:006233@.5,.5,0,0,.2',
  'NG': 'v:008751,FFFFFF,008751',
  'ZA': 'h:E03C31,001489;p:FFFFFF@0,0,.16,0,.56,.33,1,.33,1,.67,.56,.67,.16,1,0,1;'
      'p:007749@0,.07,.08,0,.52,.4,1,.4,1,.6,.52,.6,.08,1,0,.93;'
      'p:FFB81C@0,.17,.4,.5,0,.83;p:000000@0,.25,.3,.5,0,.75',

  // Asia and the Pacific
  'IN': 'h:FF9933,FFFFFF,138808;o:000080@.5,.5,0,0,.14;o:FFFFFF@.5,.5,0,0,.115;'
      'o:000080@.5,.5,0,0,.03',
  'PK': 'v:FFFFFF,01411C*3;o:FFFFFF@.625,.5,0,0,.22;o:01411C@.625,.5,.05,-.04,.19;'
      's:FFFFFF@.625,.5,.1,-.08,.07',
  'BD': 'h:006A4E;o:F42A41@.45,.5,0,0,.27',
  'TH': 'h:A51931,F4F5F8,2D2A4A*2,F4F5F8,A51931',
  'VN': 'h:DA251D;s:FFFF00@.5,.5,0,0,.3',
  'ID': 'h:FF0000,FFFFFF',
  'PH': 'h:0038A8,CE1126;p:FFFFFF@0,0,.5,.5,0,1;o:FCD116@.17,.5,0,0,.09',
  'SG': 'h:ED2939,FFFFFF;o:FFFFFF@.2,.25,0,0,.17;o:ED2939@.2,.25,.055,0,.15;'
      'c:FFFFFF@.2,.25,.13,0,.07,5,.03',
  'HK': 'h:DE2910;o:FFFFFF@.5,.5,0,-.17,.1;o:FFFFFF@.5,.5,.16,-.05,.1;'
      'o:FFFFFF@.5,.5,.1,.14,.1;o:FFFFFF@.5,.5,-.1,.14,.1;o:FFFFFF@.5,.5,-.16,-.05,.1;'
      'o:DE2910@.5,.5,0,0,.04',
  'TW': 'h:FE0000;r:000095@0,0,.5,.5;o:FFFFFF@.25,.25,0,0,.12',
  'CN': 'h:DE2910;s:FFDE00@.167,.25,0,0,.15;s:FFDE00@.333,.1,0,0,.05;'
      's:FFDE00@.4,.2,0,0,.05;s:FFDE00@.4,.35,0,0,.05;s:FFDE00@.333,.45,0,0,.05',
  'JP': 'h:FFFFFF;o:BC002D@.5,.5,0,0,.3',
  'KR': 'h:FFFFFF;o:0047A0@.5,.5,0,0,.25;u:CD2E3A@.5,.5,0,0,.25;'
      'o:CD2E3A@.5,.5,-.125,0,.125;o:0047A0@.5,.5,.125,0,.125;'
      'l:000000@.2,.3,.3,.1,.08;l:000000@.7,.1,.8,.3,.08;'
      'l:000000@.2,.7,.3,.9,.08;l:000000@.7,.9,.8,.7,.08',
  'AU': 'h:00008B;l:FFFFFF@0,0,.5,.5,.1;l:FFFFFF@0,.5,.5,0,.1;l:C8102E@0,0,.5,.5,.035;'
      'l:C8102E@0,.5,.5,0,.035;r:00008B@.5,0,1,1;r:00008B@0,.5,1,1;'
      'r:FFFFFF@.2083,0,.2917,.5;r:FFFFFF@0,.1667,.5,.3333;r:C8102E@.225,0,.275,.5;'
      'r:C8102E@0,.2,.5,.3;s:FFFFFF@.25,.75,0,0,.14;s:FFFFFF@.75,.17,0,0,.06;'
      's:FFFFFF@.75,.83,0,0,.06;s:FFFFFF@.62,.45,0,0,.06;s:FFFFFF@.87,.38,0,0,.06;'
      's:FFFFFF@.8,.57,0,0,.035',
  'NZ': 'h:00247D;l:FFFFFF@0,0,.5,.5,.1;l:FFFFFF@0,.5,.5,0,.1;l:C8102E@0,0,.5,.5,.035;'
      'l:C8102E@0,.5,.5,0,.035;r:00247D@.5,0,1,1;r:00247D@0,.5,1,1;'
      'r:FFFFFF@.2083,0,.2917,.5;r:FFFFFF@0,.1667,.5,.3333;r:C8102E@.225,0,.275,.5;'
      'r:C8102E@0,.2,.5,.3;s:FFFFFF@.75,.2,0,0,.09;s:CC142B@.75,.2,0,0,.055;'
      's:FFFFFF@.67,.47,0,0,.09;s:CC142B@.67,.47,0,0,.055;s:FFFFFF@.84,.42,0,0,.09;'
      's:CC142B@.84,.42,0,0,.055;s:FFFFFF@.75,.8,0,0,.09;s:CC142B@.75,.8,0,0,.055',

  // The Americas
  'US': 'h:B22234,FFFFFF,B22234,FFFFFF,B22234,FFFFFF,B22234,FFFFFF,B22234,FFFFFF,'
      'B22234,FFFFFF,B22234;r:3C3B6E@0,0,.4,.5385;g:FFFFFF@.05,.075,.35,.465,5,4,.024',
  'CA': 'v:D80621,FFFFFF*2,D80621;p:D80621@.5,.16,.53,.3,.565,.265,.555,.43,.615,.36,'
      '.625,.42,.665,.43,.63,.57,.65,.6,.565,.67,.575,.72,.512,.705,.512,.84,.488,.84,'
      '.488,.705,.425,.72,.435,.67,.35,.6,.37,.57,.335,.43,.375,.42,.385,.36,.445,.43,'
      '.435,.265,.47,.3',
  'MX': 'v:006847,FFFFFF,CE1126;o:8C6A2F@.5,.5,0,0,.1',
  'BR': 'h:009B3A;p:FFDF00@.5,.1,.92,.5,.5,.9,.08,.5;o:002776@.5,.5,0,0,.2',
  'AR': 'h:74ACDF,FFFFFF,74ACDF;o:F6B40E@.5,.5,0,0,.09',
  'CL': 'h:FFFFFF,D52B1E;r:0039A6@0,0,.3333,.5;s:FFFFFF@.1667,.25,0,0,.13',
  'CO': 'h:FCD116*2,003893,CE1126',
  'PE': 'v:D91023,FFFFFF,D91023',
};

/// Other spellings of a country that server names use.
const _aliases = <String, String>{
  'UK': 'GB', 'GBR': 'GB', 'USA': 'US', 'NLD': 'NL', 'DEU': 'DE', 'GER': 'DE',
  'FRA': 'FR', 'RUS': 'RU', 'FIN': 'FI', 'SWE': 'SE', 'NOR': 'NO', 'DNK': 'DK',
  'POL': 'PL', 'CZE': 'CZ', 'AUT': 'AT', 'CHE': 'CH', 'ITA': 'IT', 'ESP': 'ES',
  'PRT': 'PT', 'IRL': 'IE', 'BEL': 'BE', 'LUX': 'LU', 'EST': 'EE', 'LVA': 'LV',
  'LTU': 'LT', 'UKR': 'UA', 'BLR': 'BY', 'MDA': 'MD', 'ROU': 'RO', 'BGR': 'BG',
  'SRB': 'RS', 'HUN': 'HU', 'GRC': 'GR', 'TUR': 'TR', 'ISR': 'IL', 'UAE': 'AE',
  'ARE': 'AE', 'GEO': 'GE', 'ARM': 'AM', 'AZE': 'AZ', 'KAZ': 'KZ', 'UZB': 'UZ',
  'IND': 'IN', 'JPN': 'JP', 'KOR': 'KR', 'CHN': 'CN', 'HKG': 'HK', 'TWN': 'TW',
  'SGP': 'SG', 'AUS': 'AU', 'NZL': 'NZ', 'CAN': 'CA', 'BRA': 'BR', 'MEX': 'MX',
  // Russian cities, as hosting providers abbreviate them.
  'MSK': 'RU', 'SPB': 'RU', 'NSK': 'RU', 'EKB': 'RU',
};

/// Codes that in a server name far more often mean something else.
const _ambiguous = {'ID'};

/// A two or three letter word in capitals: "NL", "RU-2", "[DE] Berlin", "USA1".
final _codeWord = RegExp(r'(?<![A-Za-z])([A-Z]{2,3})(?![A-Za-z])');
final _edgeFiller = RegExp(r'^[\s|·•:,\-–—]+|[\s|·•:,\-–—]+$');

bool _isRegionalIndicator(int rune) => rune >= 0x1F1E6 && rune <= 0x1F1FF;

/// A server name read for the country it mentions: an emoji flag, or a
/// country code written in capitals.
class ServerLabel {
  const ServerLabel._(this.title, this.country);

  factory ServerLabel.of(String name) {
    // An emoji flag says it outright.
    final runes = name.runes.toList();
    for (var i = 0; i + 1 < runes.length; i++) {
      if (!_isRegionalIndicator(runes[i]) || !_isRegionalIndicator(runes[i + 1])) {
        continue;
      }
      final code = String.fromCharCodes(
          [runes[i] - 0x1F1E6 + 0x41, runes[i + 1] - 0x1F1E6 + 0x41]);
      // A flag the app cannot draw stays in the text as it is.
      if (!flagSpecs.containsKey(code)) return ServerLabel._(name, null);
      final rest = String.fromCharCodes([...runes.take(i), ...runes.skip(i + 2)])
          .replaceAll(RegExp(r'\s+'), ' ')
          .replaceAll(_edgeFiller, '');
      return ServerLabel._(rest.isEmpty ? code : rest, code);
    }
    for (final match in _codeWord.allMatches(name)) {
      final word = match.group(1)!;
      final code = _aliases[word] ?? word;
      if (flagSpecs.containsKey(code) && !_ambiguous.contains(word)) {
        return ServerLabel._(name, code);
      }
    }
    return ServerLabel._(name, null);
  }

  /// The name to show. An emoji flag the app draws itself is left out of it.
  final String title;

  /// ISO 3166 code of the country, when the name gives one that has a flag
  /// in [flagSpecs].
  final String? country;
}

class _Layer {
  const _Layer(this.op, this.color, this.n);
  final String op;
  final Color color;
  final List<double> n;
}

final _parsed = <String, List<_Layer>>{};

Color _colour(String hex) => Color(0xFF000000 | int.parse(hex, radix: 16));

/// Turns a spec from [flagSpecs] into layers; bands become rectangles.
List<_Layer> _parse(String spec) {
  final layers = <_Layer>[];
  for (final part in spec.split(';')) {
    final op = part[0];
    final body = part.substring(2);
    if (op == 'h' || op == 'v') {
      final colours = <Color>[];
      final weights = <double>[];
      for (final band in body.split(',')) {
        final star = band.indexOf('*');
        colours.add(_colour(star < 0 ? band : band.substring(0, star)));
        weights.add(star < 0 ? 1.0 : double.parse(band.substring(star + 1)));
      }
      final total = weights.fold<double>(0, (sum, w) => sum + w);
      var from = 0.0;
      for (var i = 0; i < colours.length; i++) {
        final to = from + weights[i] / total;
        layers.add(_Layer('r', colours[i],
            op == 'h' ? <double>[0, from, 1, to] : <double>[from, 0, to, 1]));
        from = to;
      }
      continue;
    }
    final at = body.indexOf('@');
    layers.add(_Layer(op, _colour(body.substring(0, at)),
        [for (final v in body.substring(at + 1).split(',')) double.parse(v)]));
  }
  return layers;
}

Path _star(Offset centre, double radius, double degrees) {
  final path = Path();
  for (var i = 0; i < 10; i++) {
    final angle = (degrees - 90 + i * 36) * math.pi / 180;
    final r = i.isEven ? radius : radius * 0.382;
    final x = centre.dx + math.cos(angle) * r;
    final y = centre.dy + math.sin(angle) * r;
    if (i == 0) {
      path.moveTo(x, y);
    } else {
      path.lineTo(x, y);
    }
  }
  return path..close();
}

/// Paints the flag of [code] over [box], stretched to fill it. Does nothing
/// for a code without a flag in [flagSpecs].
void paintFlag(Canvas canvas, Rect box, String code) {
  final spec = flagSpecs[code];
  if (spec == null || box.isEmpty) return;
  final layers = _parsed[code] ??= _parse(spec);
  final w = box.width, h = box.height;
  final paint = Paint();
  canvas.save();
  canvas.clipRect(box);
  canvas.translate(box.left, box.top);
  for (final layer in layers) {
    final n = layer.n;
    paint.color = layer.color;
    switch (layer.op) {
      case 'r':
        canvas.drawRect(Rect.fromLTRB(n[0] * w, n[1] * h, n[2] * w, n[3] * h), paint);
      case 'p':
        final path = Path()..moveTo(n[0] * w, n[1] * h);
        for (var i = 2; i + 1 < n.length; i += 2) {
          path.lineTo(n[i] * w, n[i + 1] * h);
        }
        canvas.drawPath(path..close(), paint);
      case 'l':
        paint.strokeWidth = n[4] * h;
        canvas.drawLine(Offset(n[0] * w, n[1] * h), Offset(n[2] * w, n[3] * h), paint);
      case 'g':
        final columns = n[4].round(), rows = n[5].round();
        for (var i = 0; i < columns; i++) {
          for (var j = 0; j < rows; j++) {
            final x = n[0] + (n[2] - n[0]) * (columns > 1 ? i / (columns - 1) : 0.5);
            final y = n[1] + (n[3] - n[1]) * (rows > 1 ? j / (rows - 1) : 0.5);
            canvas.drawCircle(Offset(x * w, y * h), n[6] * h, paint);
          }
        }
      default:
        final centre = Offset(n[0] * w + n[2] * h, n[1] * h + n[3] * h);
        final size = n[4] * h;
        switch (layer.op) {
          case 'o':
            canvas.drawCircle(centre, size, paint);
          case 'u':
            canvas.drawArc(Rect.fromCircle(center: centre, radius: size), math.pi,
                math.pi, true, paint);
          case 's':
            canvas.drawPath(_star(centre, size, n.length > 5 ? n[5] : 0), paint);
          case '+':
            final thick = n[5] * h;
            canvas.drawRect(
                Rect.fromCenter(center: centre, width: size * 2, height: thick * 2),
                paint);
            canvas.drawRect(
                Rect.fromCenter(center: centre, width: thick * 2, height: size * 2),
                paint);
          case 'c':
            final count = n[5].round();
            for (var i = 0; i < count; i++) {
              final angle = 2 * math.pi * i / count - math.pi / 2;
              canvas.drawPath(
                  _star(centre + Offset(math.cos(angle), math.sin(angle)) * size,
                      n[6] * h, 0),
                  paint);
            }
        }
    }
  }
  canvas.restore();
}

class _FlagPainter extends CustomPainter {
  const _FlagPainter(this.code, {this.fade = 0});

  final String code;

  /// Above zero the flag is a backdrop: it fades in from nothing at the
  /// start of the box to this opacity at its end.
  final double fade;

  @override
  void paint(Canvas canvas, Size size) {
    final box = Offset.zero & size;
    if (fade <= 0) {
      paintFlag(canvas, box, code);
      return;
    }
    canvas.saveLayer(box, Paint());
    paintFlag(canvas, box, code);
    canvas.drawRect(
      box,
      Paint()
        ..blendMode = BlendMode.dstIn
        ..shader = ui.Gradient.linear(
          box.centerLeft,
          box.centerRight,
          [const Color(0x00000000), Color.fromRGBO(0, 0, 0, fade)],
        ),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FlagPainter old) => old.code != code || old.fade != fade;
}

/// A small flag with rounded corners, to stand next to a server's name.
class FlagChip extends StatelessWidget {
  const FlagChip(this.code, {super.key, this.height = 15});

  final String code;
  final double height;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(height * 0.2);
    return Container(
      width: height * 1.5,
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: radius),
      // Keeps a white flag visible on a light card and a dark one on a dark.
      foregroundDecoration: BoxDecoration(
        borderRadius: radius,
        border: Border.all(
            color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.45),
            width: 0.6),
      ),
      child: CustomPaint(painter: _FlagPainter(code)),
    );
  }
}

/// The flag as a backdrop for a row: it fills the box it is given and fades
/// out towards the row's start, so the text in front stays readable.
class FlagBackdrop extends StatelessWidget {
  const FlagBackdrop(this.code, {super.key});

  final String code;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(painter: _FlagPainter(code, fade: dark ? 0.34 : 0.42)),
      ),
    );
  }
}

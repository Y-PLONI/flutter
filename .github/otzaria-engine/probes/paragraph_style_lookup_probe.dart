// Use as lib/main.dart in a minimal Flutter Windows release app. Pass an
// absolute output path when launching the executable. Compare "geometry" from
// two runs with the same SDK and fonts, then compare "layoutMicros" separately.
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

void main(List<String> args) {
  final outputPath = args.single;
  File(outputPath).writeAsStringSync(
    jsonEncode(probeParagraphStyleLookup()),
    flush: true,
  );
  exit(0);
}

Map<String, Object> probeParagraphStyleLookup() {
  final geometry = [
    _measure(
      groups: 48,
      letterSpacing: 0.25,
      wordSpacing: 1.5,
      includeGeometry: true,
    ),
    _measure(
      groups: 48,
      letterSpacing: 0.0,
      wordSpacing: 1.5,
      includeGeometry: true,
      direction: ui.TextDirection.ltr,
    ),
    _measure(
      groups: 48,
      letterSpacing: 0.25,
      wordSpacing: 0.0,
      includeGeometry: true,
      maxLines: 1,
    ),
  ].map((sample) => sample['geometry']).toList();

  return {
    'geometry': geometry,
    'scaling': [
      for (final letterSpacing in [0.0, 0.25])
        for (final groups in [4000, 8000, 16000])
          _measure(groups: groups, letterSpacing: letterSpacing),
    ],
  };
}

Map<String, Object> _measure({
  required int groups,
  required double letterSpacing,
  double wordSpacing = 0.0,
  bool includeGeometry = false,
  ui.TextDirection direction = ui.TextDirection.rtl,
  int? maxLines,
}) {
  final builder = ui.ParagraphBuilder(
    ui.ParagraphStyle(
      textDirection: direction,
      textAlign: ui.TextAlign.justify,
      fontFamily: 'Arial',
      fontSize: 16,
      maxLines: maxLines,
      ellipsis: maxLines == null ? null : '…',
    ),
  );
  final normal = ui.TextStyle(
    letterSpacing: letterSpacing,
    wordSpacing: wordSpacing,
  );
  final highlighted = ui.TextStyle(
    // Give the geometry cases different spacing on either side of a style
    // boundary. With zero letter spacing, the match can also form ligatures.
    letterSpacing: includeGeometry ? 0.0 : letterSpacing,
    wordSpacing: includeGeometry ? wordSpacing + 2.0 : wordSpacing,
    fontFamily: includeGeometry ? 'Times New Roman' : null,
    fontFeatures: includeGeometry
        ? const [ui.FontFeature.enable('liga')]
        : null,
    background: ui.Paint()..color = const ui.Color(0xffffff00),
  );

  var textLength = 0;
  for (var group = 0; group < groups; group++) {
    final start = 'שָׁלוֹם abc ${group % 10} ';
    final match = includeGeometry ? 'office עָוֹלָם' : 'עולם';
    final end = group % 7 == 6 ? '\n' : ' ';
    builder
      ..pushStyle(normal)
      ..addText(start)
      ..pop();
    if (includeGeometry && group % 6 == 4) {
      builder.addPlaceholder(14, 20, ui.PlaceholderAlignment.middle);
      textLength++;
    }
    builder
      ..pushStyle(highlighted)
      ..addText(match)
      ..pop()
      ..pushStyle(normal)
      ..addText(end)
      ..pop();
    textLength += start.length + match.length + end.length;
  }

  final paragraph = builder.build();
  try {
    final stopwatch = Stopwatch()..start();
    paragraph.layout(const ui.ParagraphConstraints(width: 600));
    stopwatch.stop();
    final lines = paragraph.computeLineMetrics();
    return {
      'groups': groups,
      'characters': textLength,
      'letterSpacing': letterSpacing,
      'layoutMicros': stopwatch.elapsedMicroseconds,
      'lineCount': lines.length,
      if (includeGeometry)
        'geometry': {
          'height': paragraph.height,
          'longestLine': paragraph.longestLine,
          'minIntrinsicWidth': paragraph.minIntrinsicWidth,
          'maxIntrinsicWidth': paragraph.maxIntrinsicWidth,
          'exceededMaxLines': paragraph.didExceedMaxLines,
          'lines': [
            for (final line in lines)
              [
                line.hardBreak,
                line.left,
                line.width,
                line.height,
                line.baseline,
                line.ascent,
                line.descent,
              ],
          ],
          'selectionBoxes': paragraph
              .getBoxesForRange(1, textLength - 1)
              .map(_box)
              .toList(),
          'placeholderBoxes': paragraph
              .getBoxesForPlaceholders()
              .map(_box)
              .toList(),
        },
    };
  } finally {
    paragraph.dispose();
  }
}

List<Object> _box(ui.TextBox box) => [
  box.left,
  box.top,
  box.right,
  box.bottom,
  box.direction.name,
];

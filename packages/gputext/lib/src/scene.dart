import 'dart:math' as math;
import 'dart:typed_data';

import 'bands.dart';
import 'font.dart';
import 'layout.dart';
import 'paragraph.dart';

const ink = [12 / 255, 15 / 255, 28 / 255, 1.0];
const background = [233 / 255, 227 / 255, 213 / 255, 1.0];

const nLines = 180;
const minSize = 2.0;
const maxSize = 2200.0;
const growthSkew = 1.35;

const loremWords = [
  'lorem',
  'ipsum',
  'dolor',
  'sit',
  'amet',
  'consectetur',
  'adipiscing',
  'elit',
  'sed',
  'do',
  'eiusmod',
  'tempor',
  'incididunt',
  'ut',
  'labore',
  'et',
  'dolore',
  'magna',
  'aliqua',
  'enim',
  'ad',
  'minim',
  'veniam',
  'quis',
  'nostrud',
  'exercitation',
  'ullamco',
  'laboris',
  'nisi',
  'aliquip',
  'ex',
  'ea',
  'commodo',
  'consequat',
  'duis',
  'aute',
  'irure',
  'in',
  'reprehenderit',
  'voluptate',
  'velit',
  'esse',
  'cillum',
  'eu',
  'fugiat',
  'nulla',
  'pariatur',
  'excepteur',
  'sint',
  'occaecat',
  'cupidatat',
  'non',
  'proident',
  'sunt',
  'culpa',
  'qui',
  'officia',
  'deserunt',
  'mollit',
  'anim',
  'id',
  'est',
  'laborum',
  'perspiciatis',
  'unde',
  'omnis',
  'iste',
  'natus',
  'error',
  'voluptatem',
  'accusantium',
  'doloremque',
  'laudantium',
  'totam',
  'rem',
  'aperiam',
  'eaque',
  'ipsa',
  'quae',
  'ab',
  'illo',
  'inventore',
  'veritatis',
  'quasi',
  'architecto',
  'beatae',
  'vitae',
  'dicta',
  'explicabo',
  'nemo',
];

List<String> makeLines(int n) {
  final lines = <String>['lorem ipsum'];
  var w = 0;
  for (var i = 1; i < n; i++) {
    final count = 3 + ((i * 3) % 6);
    final words = <String>[];
    for (var k = 0; k < count; k++) {
      words.add(loremWords[w++ % loremWords.length]);
    }
    lines.add(words.join(' '));
  }
  return lines;
}

List<double> makeSizes(int n) {
  return List<double>.generate(
    n,
    (i) =>
        minSize *
        math.pow(maxSize / minSize, math.pow(i / (n - 1), growthSkew)),
  );
}

class GPUTextScene {
  GPUTextScene({
    required this.font,
    required this.atlas,
    required this.instances,
    required this.bounds,
  });

  final GPUFont font;
  final GlyphAtlas atlas;
  final Float32List instances;
  final LayoutBounds bounds;

  static GPUTextScene build(GPUFont font) {
    final lines = makeLines(nLines);
    final sizes = makeSizes(nLines);
    final text = lines.join();
    final atlas = buildGlyphAtlas(font, text);

    final ladder = layoutStack(
      List.generate(
        lines.length,
        (i) => SizedLine(text: lines[i], size: sizes[i]),
      ),
      atlas.table,
      font,
      x: 0,
      top: 0,
      color: ink,
    );

    const paragraphX = 4200.0;
    const paragraphTop = 0.0;
    const paragraphWidth = 900.0;

    final glyphs = SingleFontGlyphTable(font, atlas.table);

    final leftPara = layoutParagraph(
      [
        TextRun(
          text: 'Left aligned paragraph with mixed ',
          font: font,
          fontSizePx: 18,
          color: ink,
        ),
        TextRun(
          text: 'sizes',
          font: font,
          fontSizePx: 28,
          color: const [0.55, 0.12, 0.08, 1.0],
        ),
        TextRun(
          text: ' and a longer lorem ipsum flow that wraps cleanly across multiple lines.',
          font: font,
          fontSizePx: 18,
          color: ink,
        ),
      ],
      glyphs,
      const ParagraphStyle(maxWidth: paragraphWidth, align: TextAlign.left),
      x: paragraphX,
      top: paragraphTop,
    );

    final centerPara = layoutParagraph(
      [
        TextRun(
          text: 'Centered paragraph demonstrating font metrics, kerning, and word wrap in the gputext renderer.',
          font: font,
          fontSizePx: 20,
          color: ink,
        ),
      ],
      glyphs,
      const ParagraphStyle(maxWidth: paragraphWidth, align: TextAlign.center),
      x: paragraphX,
      top: paragraphTop + 220,
    );

    final rightPara = layoutParagraph(
      [
        TextRun(
          text: 'Right aligned. Pan and zoom to inspect edge anti-aliasing.',
          font: font,
          fontSizePx: 16,
          color: ink,
        ),
      ],
      glyphs,
      const ParagraphStyle(maxWidth: paragraphWidth, align: TextAlign.right),
      x: paragraphX,
      top: paragraphTop + 420,
    );

    final merged = mergeLayouts([ladder, leftPara, centerPara, rightPara]);
    return GPUTextScene(
      font: font,
      atlas: atlas,
      instances: Float32List.fromList(merged.instances),
      bounds: merged.bounds,
    );
  }
}

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/bands.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/scene.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('build glyph atlas from Lato', () async {
    final bytes = await rootBundle.load('assets/Lato-Regular.ttf');
    final font = GPUFont.parse(bytes.buffer.asUint8List());
    expect(font.unitsPerEm, greaterThan(0));

    final a = font.glyphQuads('a');
    expect(a, isNotNull);
    expect(a!.quads.length, greaterThan(0));
    expect(a.advance, greaterThan(0));

    final atlas = buildGlyphAtlas(font, 'lorem ipsum');
    expect(atlas.stats.uniqueGlyphs, greaterThan(5));
    expect(atlas.curves.length, greaterThan(0));
    expect(atlas.rows.length, greaterThan(0));

    final scene = GPUTextScene.build(font);
    expect(scene.instances.length, greaterThan(1000));
  });
}

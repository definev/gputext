// Verifies the two GPUTextLayout guarantees the demo's UI-thread and
// "Highlight (re-emit only)" paths rely on:
//   1. reflow() reuses one prepare across widths (narrower => more lines).
//   2. Re-emit after mutating the run colour changes ONLY the colour lanes of
//      the instance buffer — geometry (place/bbox/band) is byte-identical, so
//      no relayout happened. If the LineRuns didn't alias the run colour this
//      would silently fail, and the highlight feature would be a no-op.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/engine/shared_atlas.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/lowlevel/gpu_text_layout.dart';
import 'package:gputext/src/paragraph.dart' as wf;

void main() {
  test('reflow reuses prepare; re-emit recolors without relayout', () {
    final font = GPUFont.parse(
      File('assets/Lato-Regular.ttf').readAsBytesSync(),
    );
    final text = List.filled(30, 'Layout once, display many times.').join(' ');
    final run = wf.TextRun(
      text: text,
      font: font,
      fontSizePx: 18,
      color: List<double>.of(const [0.1, 0.1, 0.1, 1]),
    );
    final layout = GPUTextLayout.compute([run]);

    // 1. One prepare, two widths.
    const narrow = wf.ParagraphStyle(maxWidth: 300);
    const wide = wf.ParagraphStyle(maxWidth: 520);
    final atNarrow = layout.reflow(300, narrow);
    final atWide = layout.reflow(520, wide);
    expect(atNarrow.lines.length, greaterThan(atWide.lines.length));

    // 2. Settle at 300, emit, recolor in place, re-emit (no reflow between).
    layout.reflow(300, narrow);
    final atlas = SharedGlyphAtlas()..ensureShaped(run.shaped);
    final before = layout.emit(atlas);
    run.color[0] = 0.66;
    run.color[1] = 0.11;
    run.color[2] = 0.13;
    final after = layout.emit(atlas);

    expect(after.glyphCount, before.glyphCount);
    expect(before.glyphCount, greaterThan(0));
    final a = before.instances, b = after.instances;
    expect(a.length, b.length);

    // 16 floats/glyph: place[0..3], bbox[4..7], color[8..11], band[12..15].
    const geometryLanes = [0, 1, 2, 3, 4, 5, 6, 7, 12, 13, 14, 15];
    var colorChanged = false;
    for (var g = 0; g < before.glyphCount; g++) {
      final o = g * 16;
      for (final k in geometryLanes) {
        expect(b[o + k], a[o + k], reason: 'lane $k changed by a recolor');
      }
      if (b[o + 8] != a[o + 8] ||
          b[o + 9] != a[o + 9] ||
          b[o + 10] != a[o + 10]) {
        colorChanged = true;
      }
    }
    expect(colorChanged, isTrue, reason: 're-emit must update the colour lanes');
  });
}

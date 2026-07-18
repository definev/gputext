// Banded selection geometry (line table + on-demand detail bands): with
// full detail it must answer every query EXACTLY (Float64 ==) like the live
// ParagraphGeometry it was encoded from; without detail it must stay
// line-accurate (right line, x within the line's span, exact full-line
// rects); generations gate band application.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart' show TextScaler, TextSpan, TextStyle;
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/engine/engine.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/src/paragraph.dart' as wf;
import 'package:gputext/src/widgets/span_flattener.dart';

void main() {
  late GPUFont font;
  late GPUFont emojiFont;

  setUpAll(() {
    font = GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync());
    emojiFont = GPUFont.parse(
      File('assets/TwemojiMozilla.ttf').readAsBytesSync(),
    );
    GPUText.instance.registerFont('Lato', font);
  });

  wf.TextRun run(
    String text, {
    double size = 16,
    double letterSpacing = 0,
    double wordSpacing = 0,
  }) => wf.TextRun(
    text: text,
    font: font,
    fontSizePx: size,
    color: const [0, 0, 0, 1],
    letterSpacingPx: letterSpacing,
    wordSpacingPx: wordSpacing,
  );

  wf.ParagraphGeometry liveGeometry(
    List<wf.InlineItem> items, {
    double width = double.infinity,
    wf.TextAlign align = wf.TextAlign.left,
    double boxWidth = 400,
    int? maxLines,
    bool addEllipsis = false,
  }) {
    final para = wf.breakLines(
      items,
      width,
      wf.ParagraphStyle(
        maxWidth: width,
        align: align,
        maxLines: maxLines,
        addEllipsis: addEllipsis,
      ),
    );
    return wf.ParagraphGeometry(
      items: items,
      para: para,
      boxWidth: boxWidth,
      align: align,
    );
  }

  Int32List holesOf(List<wf.InlineItem> items) {
    final holes = <int>[];
    var cursor = 0;
    for (final item in items) {
      switch (item) {
        case wf.TextRun r:
          cursor += r.originalText.length;
        case wf.EmojiItem e:
          cursor += e.originalText.length;
        case wf.PlaceholderItem _:
          holes.add(cursor);
          cursor += 1;
      }
    }
    return Int32List.fromList(holes);
  }

  /// A banded geometry for [live], optionally with detail bands applied.
  wf.BandedDocGeometry banded(
    wf.ParagraphGeometry live, {
    bool fullDetail = false,
    int generation = 1,
  }) {
    final g = wf.BandedDocGeometry(
      plainText: live.plainText,
      placeholderOffsets: holesOf(live.items),
      table: wf.LineTable.decode(wf.encodeLineTable(live)),
      generation: generation,
    );
    if (fullDetail && live.lineCount > 0) {
      g.applyDetailBand(wf.encodeLineBand(live, 0, live.lineCount));
    }
    return g;
  }

  /// Asserts [snap] answers every query exactly like [live] — the same
  /// contract selection_snapshot_test pins for the full snapshot.
  void expectParity(wf.ParagraphGeometryBase snap, wf.ParagraphGeometry live) {
    expect(snap.plainText, live.plainText);
    expect(snap.lineCount, live.lineCount);
    expect(snap.length, live.length);

    for (var line = 0; line < live.lineCount; line++) {
      expect(snap.lineTop(line), live.lineTop(line), reason: 'top $line');
      expect(
        snap.lineBottom(line),
        live.lineBottom(line),
        reason: 'bottom $line',
      );
      expect(snap.lineRange(line), live.lineRange(line), reason: 'rng $line');
      expect(
        snap.lineHardBreakAt(line),
        live.lineHardBreakAt(line),
        reason: 'hard $line',
      );
    }

    for (var o = 0; o <= live.length; o++) {
      for (final upstream in [false, true]) {
        final a = live.caretAt(o, upstream: upstream);
        final b = snap.caretAt(o, upstream: upstream);
        expect(b.x, a.x, reason: 'caret x @$o up=$upstream');
        expect(b.top, a.top, reason: 'caret top @$o up=$upstream');
        expect(b.height, a.height, reason: 'caret h @$o up=$upstream');
        expect(b.line, a.line, reason: 'caret line @$o up=$upstream');
      }
    }

    final ys = <double>[-5];
    for (var line = 0; line < live.lineCount; line++) {
      ys.add(live.lineTop(line) + 0.5);
      ys.add((live.lineTop(line) + live.lineBottom(line)) / 2);
    }
    if (live.lineCount > 0) ys.add(live.lineBottom(live.lineCount - 1) + 5);
    for (final dy in ys) {
      for (var dx = -8.0; dx <= live.boxWidth + 8.0; dx += 2.0) {
        final a = live.positionForOffset(dx, dy);
        final b = snap.positionForOffset(dx, dy);
        expect(b.offset, a.offset, reason: 'pos @($dx,$dy)');
        expect(b.upstream, a.upstream, reason: 'affinity @($dx,$dy)');
      }
    }

    for (var s = 0; s <= live.length; s++) {
      for (var e = s; e <= live.length; e++) {
        final a = live.boxesForRange(s, e);
        final b = snap.boxesForRange(s, e);
        expect(b.length, a.length, reason: 'boxes count [$s,$e)');
        for (var k = 0; k < a.length; k++) {
          expect(b[k].left, a[k].left, reason: 'box $k left [$s,$e)');
          expect(b[k].top, a[k].top, reason: 'box $k top [$s,$e)');
          expect(b[k].right, a[k].right, reason: 'box $k right [$s,$e)');
          expect(b[k].bottom, a[k].bottom, reason: 'box $k bottom [$s,$e)');
        }
      }
    }
  }

  List<wf.InlineItem> flat(String text, {ui.TextDirection? direction}) =>
      flattenSpan(
        TextSpan(
          text: text,
          style: const TextStyle(fontFamily: 'Lato', fontSize: 16),
        ),
        TextScaler.noScaling,
        GPUText.instance,
        textDirection: direction ?? ui.TextDirection.ltr,
      )!;

  group('with full detail: exact parity with live geometry', () {
    test('plain wrapped run', () {
      expectParity(
        banded(
          liveGeometry(
            [run('the quick brown fox jumps over the lazy dog')],
            width: 120,
            boxWidth: 120,
          ),
          fullDetail: true,
        ),
        liveGeometry(
          [run('the quick brown fox jumps over the lazy dog')],
          width: 120,
          boxWidth: 120,
        ),
      );
    });

    test('ligatures wrapped', () {
      final live = liveGeometry(
        flat('first fish offer waffle'),
        width: 60,
        boxWidth: 60,
      );
      expectParity(banded(live, fullDetail: true), live);
    });

    test('justify with mixed spacing runs', () {
      final live = liveGeometry(
        [
          run('Veni vidi vici ', size: 16),
          run('AV To WA ', size: 24, letterSpacing: 1.5),
          run('the quick brown fox', size: 13, wordSpacing: 3),
        ],
        width: 150,
        boxWidth: 150,
        align: wf.TextAlign.justify,
      );
      expectParity(banded(live, fullDetail: true), live);
    });

    test('bidi mixed LTR/RTL', () {
      final live = liveGeometry(
        flat('ab שלום cd עולם ef'),
        width: 70,
        boxWidth: 70,
      );
      expectParity(banded(live, fullDetail: true), live);
    });

    test('blank lines and hard breaks', () {
      final live = liveGeometry([run('a\n\nbb ccc\ndddd')], width: 60);
      expectParity(banded(live, fullDetail: true), live);
    });

    test('emoji and placeholder items', () {
      final live = liveGeometry([
        run('hi '),
        wf.EmojiItem(
          font: emojiFont,
          fontSizePx: 16,
          advanceUnits: emojiFont.unitsPerEm.toDouble(),
          sourceText: '🌚',
        ),
        run(' mid '),
        const wf.PlaceholderItem(
          index: 0,
          width: 24,
          height: 12,
          alignment: wf.InlinePlaceholderAlignment.middle,
        ),
        run(' bye'),
      ]);
      expectParity(banded(live, fullDetail: true), live);
      // 'hi ' (3) + '🌚' (2) + ' mid ' (5) → the placeholder's '￼' at 10.
      expect(banded(live).placeholderOffsets, [10]);
    });

    test('maxLines with ellipsis', () {
      final live = liveGeometry(
        [run('one two three four five six seven eight nine ten')],
        width: 80,
        boxWidth: 80,
        maxLines: 2,
        addEllipsis: true,
      );
      expectParity(banded(live, fullDetail: true), live);
    });
  });

  group('without detail: line-accurate degradation', () {
    test('hit-tests land on the right line, x within its span', () {
      final live = liveGeometry(
        [run('aaa bbb ccc ddd eee fff ggg hhh')],
        width: 60,
        boxWidth: 60,
      );
      final g = banded(live);
      expect(live.lineCount, greaterThan(2));
      for (var line = 0; line < live.lineCount; line++) {
        final mid = (live.lineTop(line) + live.lineBottom(line)) / 2;
        final pos = g.positionForOffset(30, mid);
        expect(
          pos.offset,
          inInclusiveRange(live.lineStartAt(line), live.lineEndAt(line)),
          reason: 'line $line hit stays in its source range',
        );
        // Caret comes back on the same line with exact vertical metrics.
        final caret = g.caretAt(pos.offset);
        expect(caret.line, anyOf(line, line - 1)); // wrap boundary affinity
        expect(g.lineTop(line), live.lineTop(line));
        expect(g.lineBoxHeightAt(line), live.lineBoxHeightAt(line));
      }
    });

    test('full-line selection rects are exact without any detail', () {
      final live = liveGeometry(
        [run('aaa bbb ccc ddd eee fff')],
        width: 60,
        boxWidth: 60,
      );
      final g = banded(live);
      // Whole-document selection covers each line fully: [startX, endX] per
      // line is the true painted span even without glyph detail.
      final rects = g.boxesForRange(0, live.length);
      final refRects = live.boxesForRange(0, live.length);
      expect(rects.length, refRects.length);
      for (var k = 0; k < rects.length; k++) {
        expect(rects[k].top, refRects[k].top);
        expect(rects[k].bottom, refRects[k].bottom);
        expect(rects[k].left, closeTo(refRects[k].left, 1e-6));
        expect(rects[k].right, closeTo(refRects[k].right, 1e-6));
      }
    });

    test('detail band application is per-line and refines answers', () {
      final live = liveGeometry(
        [run('the quick brown fox jumps over the lazy dog again')],
        width: 80,
        boxWidth: 80,
      );
      final g = banded(live);
      expect(live.lineCount, greaterThan(3));
      // Degraded interior caret x is generally NOT exact...
      final probe = live.lineStartAt(1) + 2;
      final degraded = g.caretAt(probe).x;
      // ...then the band for line 1 arrives and the answer snaps exact.
      g.applyDetailBand(wf.encodeLineBand(live, 1, 2));
      expect(g.hasDetailFor(1, 2), isTrue);
      expect(g.hasDetailFor(0, 2), isFalse);
      final exact = g.caretAt(probe).x;
      expect(exact, live.caretAt(probe).x);
      // The degraded answer was still inside the line's span.
      expect(
        degraded,
        inInclusiveRange(live.lineStartXAt(1) - 1e-6, live.boxWidth + 1e-6),
      );
    });
  });

  test('detail cache evicts oldest lines beyond the cap', () {
    final live = liveGeometry(
      [run(List.filled(600, 'word').join(' '))],
      width: 40,
      boxWidth: 40,
    );
    final g = banded(live);
    final cap = wf.BandedDocGeometry.detailCacheCap;
    expect(live.lineCount, greaterThan(4)); // sanity
    // Apply the same small band repeatedly at shifting offsets to overflow
    // the cap; the earliest lines must be evicted, newest retained.
    var applied = 0;
    for (
      var first = 0;
      first < live.lineCount && applied <= cap + 8;
      first += 1
    ) {
      applied += g.applyDetailBand(
        wf.encodeLineBand(live, first, (first + 1).clamp(0, live.lineCount)),
      );
    }
    if (applied > cap) {
      expect(g.hasDetailFor(0, 1), isFalse, reason: 'oldest evicted');
    }
    expect(
      g.hasDetailFor(applied - 1, applied),
      isTrue,
      reason: 'newest retained',
    );
  });
}

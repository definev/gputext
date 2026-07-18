// Parity tests for the selection-geometry snapshot codec: a decoded
// snapshot must answer every query EXACTLY (Float64 ==) like the live
// ParagraphGeometry it was encoded from, across the layout feature matrix
// (ligatures, spacing, justify, alignment, bidi, atomic items, soft
// hyphens, maxLines/ellipsis, blank lines).

import 'dart:io';
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

  /// Asserts the decoded snapshot answers every query exactly like [live].
  void expectParity(wf.ParagraphGeometry live) {
    final snap = wf.SnapshotParagraphGeometry.decode(
      wf.encodeGeometrySnapshot(live),
    );

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
    }

    // Carets: every offset × both affinities, exact.
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

    // Hit-testing: a dense x grid through each line's band plus above/below
    // the paragraph, exact offset AND affinity.
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

    // Selection rects: every range, exact.
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

  test('plain single run', () {
    expectParity(liveGeometry([run('hello world')]));
  });

  test('empty text', () {
    expectParity(liveGeometry([run('')]));
  });

  test('blank lines (double newline)', () {
    expectParity(liveGeometry([run('a\n\nb')]));
  });

  test('ligatures wrapped', () {
    expectParity(
      liveGeometry(flat('first fish offer waffle'), width: 60, boxWidth: 60),
    );
  });

  test('multi-run styles with letter and word spacing', () {
    expectParity(
      liveGeometry(
        [
          run('Veni vidi vici ', size: 16),
          run('AV To WA ', size: 24, letterSpacing: 1.5),
          run('the quick brown fox', size: 13, wordSpacing: 3),
        ],
        width: 150,
        boxWidth: 150,
      ),
    );
  });

  test('justify', () {
    expectParity(
      liveGeometry(
        [run('the quick brown fox jumps over the lazy dog')],
        width: 120,
        boxWidth: 120,
        align: wf.TextAlign.justify,
      ),
    );
  });

  test('center and right alignment', () {
    for (final align in [wf.TextAlign.center, wf.TextAlign.right]) {
      expectParity(
        liveGeometry(
          [run('aaa bbb ccc')],
          width: 60,
          boxWidth: 60,
          align: align,
        ),
      );
    }
  });

  test('bidi mixed LTR/RTL', () {
    expectParity(
      liveGeometry(flat('ab שלום cd עולם ef'), width: 70, boxWidth: 70),
    );
  });

  test('pure RTL paragraph', () {
    expectParity(
      liveGeometry(
        flat('שלום עולם ושוב שלום', direction: ui.TextDirection.rtl),
        width: 70,
        boxWidth: 70,
      ),
    );
  });

  test('emoji item (multi-unit atomic)', () {
    expectParity(
      liveGeometry([
        run('hi '),
        wf.EmojiItem(
          font: emojiFont,
          fontSizePx: 16,
          advanceUnits: emojiFont.unitsPerEm.toDouble(),
          sourceText: '🌚',
        ),
        run(' bye'),
      ]),
    );
  });

  test('placeholder item', () {
    expectParity(
      liveGeometry([
        run('before '),
        const wf.PlaceholderItem(
          index: 0,
          width: 24,
          height: 12,
          alignment: wf.InlinePlaceholderAlignment.middle,
        ),
        run(' after'),
      ]),
    );
  });

  test('placeholder offsets survive the wire', () {
    final live = liveGeometry([
      run('ab'),
      const wf.PlaceholderItem(
        index: 0,
        width: 24,
        height: 12,
        alignment: wf.InlinePlaceholderAlignment.middle,
      ),
      run('cd'),
      const wf.PlaceholderItem(
        index: 1,
        width: 24,
        height: 12,
        alignment: wf.InlinePlaceholderAlignment.middle,
      ),
    ]);
    final snap = wf.SnapshotParagraphGeometry.decode(
      wf.encodeGeometrySnapshot(live),
    );
    expect(snap.placeholderOffsets, [2, 5]);
    expect(snap.plainText, 'ab￼cd￼');
  });

  test('soft hyphen wrap', () {
    expectParity(
      liveGeometry(
        [run('super­cali­fragilistic­expialidocious')],
        width: 80,
        boxWidth: 80,
      ),
    );
  });

  test('maxLines with ellipsis', () {
    expectParity(
      liveGeometry(
        [run('one two three four five six seven eight nine ten')],
        width: 80,
        boxWidth: 80,
        maxLines: 2,
        addEllipsis: true,
      ),
    );
  });
}

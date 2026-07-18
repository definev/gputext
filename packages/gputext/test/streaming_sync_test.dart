// syncStream (appendable-prepare v0, docs/appendable-prepare.md): a streaming
// document re-shapes only the hard-break paragraph slices whose content
// changed since the previous sync. These tests prove (1) the sliced pipeline
// is DRAWABLE-IDENTICAL to a from-scratch prepareDoc+reflowDoc of the same
// runs — including bidi text and newlines splitting mid-spec — and (2) the
// shaping cache actually skips stable slices (via debugStreamStats), which is
// the whole point: per-tick HarfBuzz cost O(delta), not O(document).
//
// Runs headless like lowlevel_worker_test.dart.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/lowlevel/gpu_text_worker.dart';

const _body = 15.0;

GPUTextRunSpec _run(
  String text, {
  double size = _body,
  List<double> color = const [1, 1, 1, 1],
  double? height = 1.45,
}) => GPUTextRunSpec(
  text: text,
  fontId: 'lato',
  fontSizePx: size,
  color: color,
  height: height,
);

/// The drawable fields that fully determine what gets painted.
void _expectSameDrawable(GPUTextInstances a, GPUTextInstances b) {
  expect(a.glyphCount, b.glyphCount);
  expect(a.lineCount, b.lineCount);
  expect(a.width, b.width);
  expect(a.contentWidth, b.contentWidth);
  expect(a.height, b.height);
  expect(
    a.instances.materialize().asUint8List(),
    b.instances.materialize().asUint8List(),
  );
}

void main() {
  late GPUTextWorker worker;
  late Uint8List latoBytes;

  setUp(() async {
    latoBytes = Uint8List.fromList(
      File('assets/Lato-Regular.ttf').readAsBytesSync(),
    );
    worker = await GPUTextWorker.spawn();
    await worker.registerFont('lato', latoBytes);
  });

  tearDown(() => worker.dispose());

  test('syncStream drawable matches prepareDoc+reflowDoc byte-for-byte', () async {
    // Three paragraphs: newline inside a spec, a spec boundary mid-paragraph
    // (style change), and an RTL stretch so bidi crosses a slice boundary.
    final runs = [
      _run('First paragraph with some words.\nSecond '),
      _run('paragraph continues bold-ish', color: const [1, 0.8, 0.6, 1]),
      _run(' and ends.\nThird: RTL مرحبا بالعالم mixed back to Latin.'),
    ];
    await worker.prepareDoc('ref', runs);
    final ref = await worker.reflowDoc('ref', 320);
    final stream = await worker.syncStream('s', runs, width: 320);
    _expectSameDrawable(ref, stream);
  });

  test('appending to the tail re-shapes only the tail slice', () async {
    const p1 = 'Alpha beta gamma delta.\n';
    const p2 = 'Epsilon zeta eta theta.\n';
    var tail = 'Iota kappa';
    await worker.syncStream('s', [_run(p1 + p2 + tail)], width: 320);
    expect(await worker.debugStreamStats('s'), (3, 3));

    // Word-by-word appends: chunk count stays 3, shaped count grows by one
    // slice per sync (the tail), never re-shaping p1/p2.
    for (final word in [' lambda', ' mu', ' nu']) {
      tail += word;
      await worker.syncStream('s', [_run(p1 + p2 + tail)], width: 320);
    }
    expect(await worker.debugStreamStats('s'), (3, 6));

    // A newline commits the tail; the next sync appends a NEW slice: the
    // committed one is not re-shaped (its slice content is unchanged).
    tail += '\nXi omicron';
    await worker.syncStream('s', [_run(p1 + p2 + tail)], width: 320);
    expect(await worker.debugStreamStats('s'), (4, 8));

    // Parity against a fresh document after all the incremental work.
    await worker.prepareDoc('ref', [_run(p1 + p2 + tail)]);
    final ref = await worker.reflowDoc('ref', 320);
    final stream = await worker.syncStream('s', [
      _run(p1 + p2 + tail),
    ], width: 320);
    _expectSameDrawable(ref, stream);
    // The parity sync itself changed nothing — no slice re-shaped.
    expect(await worker.debugStreamStats('s'), (4, 8));
  });

  test('a retroactive edit re-shapes from the edited slice onward', () async {
    final before = [_run('One.\n'), _run('Two.\n'), _run('Three.')];
    await worker.syncStream('s', before, width: 320);
    expect(await worker.debugStreamStats('s'), (3, 3));

    // Restyle the middle paragraph (markdown "**bold" closing late): slices
    // 2 and 3 rebuild, slice 1 is reused.
    final after = [
      _run('One.\n'),
      _run('Two.\n', color: const [1, 0, 0, 1]),
      _run('Three.'),
    ];
    final stream = await worker.syncStream('s', after, width: 320);
    expect(await worker.debugStreamStats('s'), (3, 5));

    await worker.prepareDoc('ref', after);
    final ref = await worker.reflowDoc('ref', 320);
    _expectSameDrawable(ref, stream);
  });

  test('finishStream drops the cache but keeps the prepared doc', () async {
    final runs = [_run('Streamed line one.\nStreamed line two.')];
    final live = await worker.syncStream('s', runs, width: 320);
    await worker.finishStream('s');
    expect(await worker.debugStreamStats('s'), isNull);

    // The document survives as an ordinary prepared doc: reflow at a new
    // width works without any re-prepare.
    final reflowed = await worker.reflowDoc('s', 200);
    expect(reflowed.glyphCount, live.glyphCount);
    expect(reflowed.lineCount, greaterThanOrEqualTo(live.lineCount));

    // disposeDoc clears both the doc and any (already absent) stream state.
    await worker.disposeDoc('s');
    await expectLater(worker.reflowDoc('s', 200), throwsStateError);
  });

  test('empty content is rejected with a clear error', () async {
    await expectLater(
      worker.syncStream('s', [_run('')], width: 320),
      throwsStateError,
    );
  });
}

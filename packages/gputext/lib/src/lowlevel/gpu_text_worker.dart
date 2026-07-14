// Long-lived background-isolate wrapper around the VM-pure layout pipeline.
//
// The heavy shape -> prepare -> layout -> emit work runs OFF the UI isolate;
// the main isolate receives a ready-to-upload Float32List (zero-copy via
// TransferableTypedData) and hands it straight to GPUTextPipeline. This is a
// capability Flutter's engine-bound Paragraph can't offer: text layout that
// never touches the UI thread.
//
// Decoupling: the worker depends only on Layer-0 (prepare/layout/emit), font
// parsing, and the CPU-side SharedGlyphAtlas. It never imports flutter_gpu,
// dart:ui, the widgets, or the GPUText engine singleton — none of which exist
// in a spawned isolate anyway.
//
// Shaping note: the worker loads HarfBuzz in its own isolate (FFI native
// symbols are process-global, so `HarfBuzzBindings.tryLoad()` works off the
// main isolate; native shaper handles are per-instance). That gives real
// shaping — ligatures, kerning, complex-script joining, bidi — and CFF/CFF2/
// CID outline extraction (via `GPUFont.outlineProvider`). On a platform where
// HarfBuzz can't load, it falls back to the pure-Dart per-rune path (glyf
// only, no ligatures). Use [buildRunItems] + [loadHarfBuzzShaper] to reproduce
// the exact same shaping on the main isolate (e.g. for a reference layout).

import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import '../engine/shared_atlas.dart';
import '../font.dart';
import '../native/harfbuzz_bindings.dart' show HarfBuzzBindings;
import '../paragraph.dart';
import '../text/bidi.dart' show itemize, scriptTagForRun;
import '../text/emoji_ranges.dart' show emojiClusterEnd;
import '../text/harfbuzz_shaper.dart' show HarfBuzzShaper;
import '../text/shaper.dart' show ShapeRequest, TextShaper;

/// One sendable inline item: a styled text run ([GPUTextRunSpec]) or a
/// widget-placeholder ([GPUPlaceholderSpec]). All fields are primitives/enums,
/// so a list of these deep-copies cleanly across the isolate boundary.
sealed class GPUInlineSpec {
  const GPUInlineSpec();
}

/// Sendable description of one styled text run. Carries no [GPUFont] — it
/// references a font registered on the worker by [fontId], so font bytes cross
/// the isolate boundary once (via [GPUTextWorker.registerFont]) rather than on
/// every request.
class GPUTextRunSpec extends GPUInlineSpec {
  const GPUTextRunSpec({
    required this.text,
    required this.fontId,
    required this.fontSizePx,
    this.color = const [0, 0, 0, 1],
    this.letterSpacingPx = 0,
    this.wordSpacingPx = 0,
    this.direction = TextDirection.ltr,
    this.features = const {},
  });

  final String text;
  final String fontId;
  final double fontSizePx;

  /// RGBA in 0..1.
  final List<double> color;
  final double letterSpacingPx;
  final double wordSpacingPx;
  final TextDirection direction;

  /// OpenType feature tags → values, e.g. `{'smcp': 1, 'tnum': 1, 'liga': 0}`.
  /// Applied by HarfBuzz when a shaper is available.
  final Map<String, int> features;
}

/// Sendable placeholder reserving inline space for a widget (a flattened
/// WidgetSpan). The worker lays it out and returns its box in the drawable's
/// [GPUTextInstances.placeholders]; the main isolate positions the real widget
/// there. [index] ties the returned box back to your widget.
class GPUPlaceholderSpec extends GPUInlineSpec {
  const GPUPlaceholderSpec({
    required this.index,
    required this.width,
    required this.height,
    this.alignment = InlinePlaceholderAlignment.middle,
    this.baselineOffset,
  });

  final int index;
  final double width;
  final double height;
  final InlinePlaceholderAlignment alignment;
  final double? baselineOffset;
}

/// Sendable layout request. Every field is a primitive, enum, or list thereof,
/// so it deep-copies cleanly across the isolate boundary.
class GPUTextLayoutRequest {
  const GPUTextLayoutRequest({
    required this.runs,
    this.maxWidth = double.infinity,
    this.align = TextAlign.left,
    this.lineHeight = 1.0,
    this.maxLines,
    this.fallbackFontIds = const [],
    this.emojiFontId,
  });

  final List<GPUInlineSpec> runs;
  final double maxWidth;
  final TextAlign align;
  final double lineHeight;
  final int? maxLines;

  /// Ordered fallback font ids for characters the run's font doesn't cover
  /// (e.g. CJK, Arabic). Must be registered via [GPUTextWorker.registerFont].
  final List<String> fallbackFontIds;

  /// Font id of a COLR (layered-vector) color-emoji font, or null. Emoji
  /// clusters resolve to it and render as coloured coverage layers.
  final String? emojiFontId;
}

/// A complete, self-contained drawable shipped back from the worker: the
/// glyph outline atlas ([curves]/[rows]) plus the [instances] that index into
/// it. Everything is transferred zero-copy — on the main isolate, feed
/// ([materializeCurves], [materializeRows], [materialize]) straight into
/// `GPUTextRenderer.create(...)` (or `uploadAtlasTextures` +
/// `GPUTextPipeline.renderInstances`) and draw. Nothing else is required.
class GPUTextInstances {
  GPUTextInstances({
    required this.instances,
    required this.colorInstances,
    required this.curves,
    required this.rows,
    required this.glyphCount,
    required this.colorGlyphCount,
    required this.lineCount,
    required this.width,
    required this.height,
    required this.didExceedMaxLines,
    this.placeholders = const [],
  });

  final TransferableTypedData instances;
  final TransferableTypedData? colorInstances;

  /// Quadratic-outline control points the coverage shader samples.
  final TransferableTypedData curves;

  /// Per-glyph band table into [curves].
  final TransferableTypedData rows;

  final int glyphCount;
  final int colorGlyphCount;
  final int lineCount;

  /// Laid-out extent, logical px. [width] is the wrap width used.
  final double width;
  final double height;
  final bool didExceedMaxLines;

  /// Boxes for flattened WidgetSpans, in document-layout space. Position your
  /// real widgets at these (each [PlaceholderBox.index] matches the
  /// [GPUPlaceholderSpec.index] you sent). Empty when there are no placeholders.
  final List<PlaceholderBox> placeholders;

  /// Materialize the coverage-glyph instance buffer on the receiving isolate.
  Float32List materialize() => instances.materialize().asFloat32List();

  /// Materialize the color-bitmap (emoji) instance buffer, or null if none.
  Float32List? materializeColor() =>
      colorInstances?.materialize().asFloat32List();

  /// Materialize the outline atlas — pair with [materializeRows] and hand both
  /// to `uploadAtlasTextures` / `GPUTextRenderer.create`.
  Float32List materializeCurves() => curves.materialize().asFloat32List();
  Uint32List materializeRows() => rows.materialize().asUint32List();
}

/// A warm isolate that registers fonts once and answers layout requests. Spawn
/// one per app (or per heavy surface), keep it alive, stream requests at it.
class GPUTextWorker {
  GPUTextWorker._(this._isolate, this._toWorker, this._rx, this._pending);

  final Isolate _isolate;
  final SendPort _toWorker;
  final ReceivePort _rx;
  final Map<int, Completer<Object?>> _pending;
  int _seq = 0;
  bool _disposed = false;

  /// Spawn the worker isolate and complete once its command port is ready.
  static Future<GPUTextWorker> spawn() async {
    final rx = ReceivePort();
    final ready = Completer<SendPort>();
    final pending = <int, Completer<Object?>>{};
    rx.listen((msg) {
      if (msg is SendPort) {
        ready.complete(msg);
        return;
      }
      final (int seq, Object? payload) = msg as (int, Object?);
      pending.remove(seq)?.complete(payload);
    });
    final isolate = await Isolate.spawn(_workerEntry, rx.sendPort);
    final toWorker = await ready.future;
    return GPUTextWorker._(isolate, toWorker, rx, pending);
  }

  Future<Object?> _send(Object command) {
    if (_disposed) throw StateError('GPUTextWorker is disposed');
    final seq = _seq++;
    final completer = Completer<Object?>();
    _pending[seq] = completer;
    _toWorker.send((seq, command));
    return completer.future;
  }

  /// Register a font's bytes once under [id]; runs reference it by that id.
  /// [bytes] is transferred (the caller's list is neutered afterwards) to
  /// avoid a copy — pass a throwaway or `Uint8List.fromList(...)` if you still
  /// need the originals.
  Future<void> registerFont(String id, Uint8List bytes) async {
    await _send(('font', id, TransferableTypedData.fromList([bytes])));
  }

  /// Shape + prepare + layout + emit [request] on the worker isolate (one-shot).
  Future<GPUTextInstances> layout(GPUTextLayoutRequest request) async {
    final reply = await _send(('layout', request));
    if (reply is GPUTextInstances) return reply;
    throw StateError('worker layout failed: $reply');
  }

  /// PHASE 1, cached: shape + prepare a multi-run (rich text) paragraph once
  /// and keep it under [id] with its glyph atlas. Run once per document, then
  /// [reflowDoc] cheaply at any width. Fonts referenced by [runs] must already
  /// be registered (see [registerFont]); flatten a Flutter `TextSpan` into
  /// [runs] with `flattenInlineSpan`. A single-style document is just a
  /// one-element list.
  Future<void> prepareDoc(
    String id,
    List<GPUInlineSpec> runs, {
    List<String> fallbackFontIds = const [],
    String? emojiFontId,
  }) async {
    final ok = await _send(('doc', id, runs, fallbackFontIds, emojiFontId));
    if (ok != true) throw StateError('prepareDoc failed: $ok');
  }

  /// PHASE 2 + 3, cached: re-break the document prepared under [id] at [width]
  /// and emit a fresh drawable — no re-shaping. Returns null geometry only if
  /// [id] was never prepared.
  /// The glyph outline atlas ([GPUTextInstances.curves]/[rows]) is IDENTICAL
  /// across reflows of a doc (only line breaking changes, not the glyph set),
  /// so pass [includeAtlas] `false` after the first reflow to skip re-sending
  /// (and re-uploading) it — the receiver reuses the atlas it already has. The
  /// returned buffers are empty when omitted.
  Future<GPUTextInstances> reflowDoc(
    String id,
    double width, {
    double lineHeight = 1.3,
    bool includeAtlas = true,
  }) async {
    final reply = await _send(('reflow', id, width, lineHeight, includeAtlas));
    if (reply is GPUTextInstances) return reply;
    throw StateError('reflowDoc failed: $reply');
  }

  /// Tear the worker down. Pending requests complete with an error.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _toWorker.send((-1, 'stop'));
    _rx.close();
    _isolate.kill(priority: Isolate.beforeNextEvent);
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(StateError('GPUTextWorker disposed'));
      }
    }
    _pending.clear();
  }
}

// --- worker-side (runs in the spawned isolate) ---

/// A document prepared once (phase 1) and kept warm for cheap re-breaks.
class _Doc {
  _Doc(this.prepared, this.atlas);
  final PreparedParagraph prepared;
  final SharedGlyphAtlas atlas;
}

Future<void> _workerEntry(SendPort host) async {
  final rx = ReceivePort();
  host.send(rx.sendPort);
  final fonts = <String, GPUFont>{};
  final docs = <String, _Doc>{};
  // Load HarfBuzz once in this isolate (sets GPUFont.outlineProvider). Null on
  // an unsupported platform → the pure-Dart per-rune fallback.
  final shaper = loadHarfBuzzShaper();
  await for (final msg in rx) {
    final (int seq, Object command) = msg as (int, Object);
    if (command == 'stop') {
      rx.close();
      break;
    }
    Object? reply;
    try {
      switch (command) {
        case ('font', final String id, final TransferableTypedData bytes):
          fonts[id] = GPUFont.parse(bytes.materialize().asUint8List());
          reply = true;
        case ('layout', final GPUTextLayoutRequest req):
          reply = _runLayout(req, fonts, shaper);
        case (
          'doc',
          final String id,
          final List<GPUInlineSpec> runs,
          final List<String> fallbackFontIds,
          final String? emojiFontId,
        ):
          reply = _prepareDoc(
            id,
            runs,
            fallbackFontIds,
            emojiFontId,
            fonts,
            shaper,
            docs,
          );
        case (
          'reflow',
          final String id,
          final double width,
          final double lh,
          final bool includeAtlas,
        ):
          reply = _reflowDoc(id, width, lh, includeAtlas, docs);
        default:
          reply = 'unknown command';
      }
    } catch (e, st) {
      reply = 'error: $e\n$st';
    }
    host.send((seq, reply));
  }
}

/// Load HarfBuzz for the current isolate (returns null on a platform where it
/// can't load — the caller then gets the pure-Dart per-rune fallback). When
/// [setOutlineProvider] is true, routes [GPUFont] outline extraction through
/// HarfBuzz so CFF/CFF2/CID/variable fonts render, not just glyf. Safe to call
/// on the worker isolate or the main isolate; the native bindings are cached
/// per isolate.
TextShaper? loadHarfBuzzShaper({bool setOutlineProvider = true}) {
  try {
    final hb = HarfBuzzBindings.tryLoad();
    if (hb == null) return null;
    final shaper = HarfBuzzShaper(hb);
    if (setOutlineProvider) {
      GPUFont.outlineProvider = shaper.drawGlyphOutline;
    }
    return shaper;
  } catch (_) {
    return null;
  }
}

/// Build the internal run items for a rich (multi-run) paragraph, resolving
/// each spec's [GPUTextRunSpec.fontId] against the registered [fonts] (runs
/// with an unregistered font are skipped).
///
/// With a [shaper] (from [loadHarfBuzzShaper]) each run is bidi-itemized and
/// HarfBuzz-shaped per sub-run — ligatures, kerning, complex-script joining,
/// RTL. Without one, each run gets the pure-Dart per-rune fallback (glyf only,
/// no shaping). Exposed so a caller can produce the SAME items the worker does
/// (e.g. a UI-thread reference, or a `GPUTextLayout` on the main isolate).
List<InlineItem> buildRunItems(
  List<GPUInlineSpec> runs,
  Map<String, GPUFont> fonts,
  TextShaper? shaper, {
  List<String> fallbackFontIds = const [],
  String? emojiFontId,
}) {
  final fallbacks = [
    for (final id in fallbackFontIds)
      if (fonts[id] != null) fonts[id]!,
  ];
  final emojiFont = emojiFontId == null ? null : fonts[emojiFontId];
  final items = <InlineItem>[];

  // Coverage-slice [text] (CJK/RTL routed to a covering fallback), then
  // bidi-itemize + shape each slice — the plain-text path.
  void emitText(String text, GPUTextRunSpec run, GPUFont primary) {
    if (text.isEmpty) return;
    for (final (font, sliceText) in _coverageSlices(text, primary, fallbacks)) {
      if (shaper == null) {
        items.add(
          TextRun(
            text: sliceText,
            font: font,
            fontSizePx: run.fontSizePx,
            color: List<double>.of(run.color),
            letterSpacingPx: run.letterSpacingPx,
            wordSpacingPx: run.wordSpacingPx,
          ),
        );
        continue;
      }
      // Tracked-out text de-ligates, matching the widget path.
      final defaultLigatures = run.letterSpacingPx == 0;
      for (final br in itemize(sliceText, baseDirection: run.direction)) {
        final slice = br.slice(sliceText);
        if (slice.isEmpty) continue;
        var shaped = shaper.shape(
          ShapeRequest(
            font: font,
            text: slice,
            fontSizePx: run.fontSizePx,
            features: run.features,
            defaultLigatures: defaultLigatures,
            direction: br.direction,
            bidiLevel: br.level,
            script: scriptTagForRun(slice),
          ),
        );
        if (shaped.bidiLevel != br.level || shaped.direction != br.direction) {
          shaped = shaped.withBidi(bidiLevel: br.level, direction: br.direction);
        }
        items.add(
          TextRun(
            text: shaped.pipelineText,
            font: font,
            fontSizePx: run.fontSizePx,
            color: List<double>.of(run.color),
            letterSpacingPx: run.letterSpacingPx,
            wordSpacingPx: run.wordSpacingPx,
            shaped: shaped,
          ),
        );
      }
    }
  }

  for (final spec in runs) {
    // Widget placeholder — reserve inline space; the box comes back in emit.
    if (spec is GPUPlaceholderSpec) {
      items.add(
        PlaceholderItem(
          index: spec.index,
          width: spec.width,
          height: spec.height,
          alignment: spec.alignment,
          baselineOffset: spec.baselineOffset,
        ),
      );
      continue;
    }
    final run = spec as GPUTextRunSpec;
    final primary = fonts[run.fontId];
    if (primary == null) continue;

    // No color emoji font → plain text (emoji tofu on the primary).
    if (emojiFont == null || !emojiFont.hasColorGlyphs) {
      emitText(run.text, run, primary);
      continue;
    }

    // Emoji-itemize FIRST (mirrors the widget path): pull out emoji clusters
    // (VS16 / skin-tone / ZWJ / flags / keycaps) that the emoji font resolves
    // to a single COLR glyph; everything else goes through the text path.
    final cps = run.text.runes.toList();
    final pending = StringBuffer();
    var i = 0;
    while (i < cps.length) {
      final end = emojiClusterEnd(cps, i);
      final emoji = end > i
          ? _resolveColrEmoji(
              String.fromCharCodes(cps.sublist(i, end)),
              emojiFont,
              shaper,
              run.fontSizePx,
              run.color,
            )
          : null;
      if (emoji != null) {
        if (pending.isNotEmpty) {
          emitText(pending.toString(), run, primary);
          pending.clear();
        }
        items.add(emoji);
        i = end;
        continue;
      }
      pending.writeCharCode(cps[i]);
      i++;
    }
    if (pending.isNotEmpty) emitText(pending.toString(), run, primary);
  }
  return items;
}

/// Resolve one emoji [cluster] to a COLR (layered-vector) glyph via the emoji
/// font: shape it (HarfBuzz collapses ZWJ/skin-tone sequences to one glyph),
/// then read its COLR layers. Returns null for a non-color/bitmap glyph, a
/// sequence the font doesn't ligate, or when no shaper is available for a
/// multi-codepoint cluster (bitmap emoji are a separate, un-wired path).
EmojiItem? _resolveColrEmoji(
  String cluster,
  GPUFont emojiFont,
  TextShaper? shaper,
  double fontSizePx,
  List<double> textColor,
) {
  int gid;
  if (shaper != null) {
    // Glyph-id resolution is ppem-independent; shape at a nominal size.
    final ShapedGlyphRun shaped;
    try {
      shaped = shaper.shape(
        ShapeRequest(font: emojiFont, text: cluster, fontSizePx: 64),
      );
    } catch (_) {
      return null;
    }
    if (shaped.glyphs.length != 1) return null; // unsupported sequence
    gid = shaped.glyphs.first.glyphId;
  } else {
    final cps = cluster.runes.toList();
    if (cps.length != 1) return null; // need a shaper for real sequences
    gid = emojiFont.glyphIdForRune(cps.first) ?? 0;
  }
  if (gid == 0) return null; // .notdef
  final layers = emojiFont.colrForGlyphId(gid);
  if (layers == null || layers.isEmpty) return null; // bitmap / no color
  return EmojiItem(
    font: emojiFont,
    fontSizePx: fontSizePx,
    advanceUnits: emojiFont.advanceOfGlyphId(gid),
    layers: layers,
    textColor: List<double>.of(textColor),
  );
}

/// Band the outlines every item in [items] needs into [atlas]: shaped glyphs
/// for text runs, and each COLR layer's glyph for emoji. Call before
/// `emitInstances`. Shared by the worker and main-isolate callers.
void bandRunItems(SharedGlyphAtlas atlas, List<InlineItem> items) {
  for (final item in items) {
    if (item is TextRun) {
      atlas.ensureShaped(item.shaped);
    } else if (item is EmojiItem) {
      for (final layer in item.layers) {
        atlas.ensureGlyphId(item.font, layer.glyphId);
      }
    }
  }
}

/// Split [text] into maximal contiguous runs, each covered by one font: the
/// [primary], else the first of [fallbacks] that has the glyph. A run "sticks"
/// with the current font while it still covers the next rune, to avoid
/// fragmenting (e.g. CJK + its trailing space stay together). Uncovered runes
/// fall through to [primary] (tofu).
Iterable<(GPUFont, String)> _coverageSlices(
  String text,
  GPUFont primary,
  List<GPUFont> fallbacks,
) sync* {
  if (text.isEmpty || fallbacks.isEmpty) {
    if (text.isNotEmpty) yield (primary, text);
    return;
  }
  GPUFont pick(int cp) {
    if (primary.hasGlyphForRune(cp)) return primary;
    for (final f in fallbacks) {
      if (f.hasGlyphForRune(cp)) return f;
    }
    return primary;
  }

  final buf = StringBuffer();
  GPUFont? current;
  for (final rune in text.runes) {
    final font = (current != null && current.hasGlyphForRune(rune))
        ? current
        : pick(rune);
    if (current != null && !identical(font, current)) {
      yield (current, buf.toString());
      buf.clear();
    }
    current = font;
    buf.writeCharCode(rune);
  }
  if (current != null) yield (current, buf.toString());
}

GPUTextInstances _runLayout(
  GPUTextLayoutRequest req,
  Map<String, GPUFont> fonts,
  TextShaper? shaper,
) {
  final items = buildRunItems(
    req.runs,
    fonts,
    shaper,
    fallbackFontIds: req.fallbackFontIds,
    emojiFontId: req.emojiFontId,
  );
  final style = ParagraphStyle(
    maxWidth: req.maxWidth,
    align: req.align,
    lineHeight: req.lineHeight,
    maxLines: req.maxLines,
  );

  // PHASE 1 + 2 (VM-pure).
  final prepared = prepareParagraph(items);
  final lines = layoutPreparedLines(prepared, req.maxWidth, style);

  // PHASE 3 — band outlines (incl. COLR emoji layers) and emit.
  final atlas = SharedGlyphAtlas();
  bandRunItems(atlas, items);
  return _drawable(lines, atlas, req.maxWidth, req.align);
}

bool _prepareDoc(
  String id,
  List<GPUInlineSpec> runs,
  List<String> fallbackFontIds,
  String? emojiFontId,
  Map<String, GPUFont> fonts,
  TextShaper? shaper,
  Map<String, _Doc> docs,
) {
  final items = buildRunItems(
    runs,
    fonts,
    shaper,
    fallbackFontIds: fallbackFontIds,
    emojiFontId: emojiFontId,
  );
  if (items.isEmpty) return false;
  final prepared = prepareParagraph(items);
  // One atlas for the whole rich paragraph — SharedGlyphAtlas interleaves
  // glyphs from every font (incl. COLR emoji layers) into a single curves/rows
  // pair, so a multi-font document is still ONE self-contained drawable.
  final atlas = SharedGlyphAtlas();
  bandRunItems(atlas, items);
  docs[id] = _Doc(prepared, atlas);
  return true;
}

GPUTextInstances _reflowDoc(
  String id,
  double width,
  double lineHeight,
  bool includeAtlas,
  Map<String, _Doc> docs,
) {
  final doc = docs[id];
  if (doc == null) throw StateError('doc "$id" was never prepared');
  final style = ParagraphStyle(maxWidth: width, lineHeight: lineHeight);
  final lines = layoutPreparedLines(doc.prepared, width, style);
  return _drawable(
    lines,
    doc.atlas,
    width,
    TextAlign.left,
    includeAtlas: includeAtlas,
  );
}

/// Package laid-out [lines] + [atlas] into a self-contained, transfer-ready
/// drawable. The fresh instance buffer is moved zero-copy; the atlas
/// ([curves]/[rows]) is copied then moved when [includeAtlas], else empty — it
/// is identical across a doc's reflows, so send it once. (A fresh empty buffer
/// each time: TransferableTypedData is single-use.)
GPUTextInstances _drawable(
  ParagraphLines lines,
  SharedGlyphAtlas atlas,
  double boxWidth,
  TextAlign align, {
  bool includeAtlas = true,
}) {
  final emitted = emitInstances(lines, boxWidth, align, atlas);
  final color = emitted.colorInstances;
  return GPUTextInstances(
    instances: TransferableTypedData.fromList([emitted.instances]),
    colorInstances:
        color.isEmpty ? null : TransferableTypedData.fromList([color]),
    curves: includeAtlas
        ? TransferableTypedData.fromList([Float32List.fromList(atlas.curves)])
        : TransferableTypedData.fromList([Float32List(0)]),
    rows: includeAtlas
        ? TransferableTypedData.fromList([Uint32List.fromList(atlas.rows)])
        : TransferableTypedData.fromList([Uint32List(0)]),
    glyphCount: emitted.glyphCount,
    colorGlyphCount: emitted.colorGlyphCount,
    lineCount: lines.lines.length,
    width: boxWidth.isFinite ? boxWidth : lines.maxIntrinsicWidth,
    height: lines.height,
    didExceedMaxLines: lines.didExceedMaxLines,
    placeholders: emitted.placeholders,
  );
}

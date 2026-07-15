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
// in a spawned isolate anyway. Color-bitmap (sbix/CBDT) emoji therefore ship
// as PNG stubs in [GPUTextInstances.colorGlyphStubs] for the main isolate to
// decode into a SharedColorAtlas; prefer a COLR emoji font when available.
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
import 'dart:math' as math;
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

/// How the laid-out paragraph width is chosen (mirror of Flutter's
/// [TextWidthBasis], plus a column-fill default suited to the worker API).
enum GPUTextWidthBasis {
  /// Alignment / reported width = the constraint [maxWidth] when finite.
  /// Matches the historical worker/reflow behaviour (layout in a column).
  parent,

  /// Hug the longest laid-out line (Flutter [TextWidthBasis.longestLine]).
  longestLine,

  /// Clamp max-intrinsic (unwrapped) width to the box — Flutter
  /// [TextWidthBasis.parent] / TextPainter shrink-wrap.
  intrinsic,
}

/// Sendable paragraph layout knobs — everything [ParagraphStyle] needs plus
/// soft-wrap / width-basis policy that [GPURichText] applies around it.
class GPUTextLayoutStyle {
  const GPUTextLayoutStyle({
    this.align = TextAlign.left,
    this.lineHeight = 1.0,
    this.maxLines,
    this.softWrap = true,
    this.addEllipsis = false,
    this.lineBreaker = LineBreaker.greedy,
    this.strut,
    this.applyHeightToFirstAscent = true,
    this.applyHeightToLastDescent = true,
    this.evenLeading = false,
    this.textWidthBasis = GPUTextWidthBasis.parent,
  });

  final TextAlign align;
  final double lineHeight;
  final int? maxLines;

  /// When false, wrap width is infinite (single long line); pair with
  /// [addEllipsis] to truncate at the box edge like `softWrap: false` +
  /// `overflow: ellipsis` on [GPURichText].
  final bool softWrap;

  /// Append '…' when [maxLines] is exceeded, or (with [softWrap] false)
  /// truncate each overlong line at the box width.
  final bool addEllipsis;

  /// Line-break strategy (greedy by default; [LineBreaker.knuthPlass] for
  /// TeX-style optimal justified paragraphs).
  final LineBreaker lineBreaker;

  /// Minimum (or with [StrutMetrics.force], exact) line metrics.
  final StrutMetrics? strut;

  /// When false, first-line ascent ignores run height multipliers.
  final bool applyHeightToFirstAscent;

  /// When false, last-line descent ignores run height multipliers.
  final bool applyHeightToLastDescent;

  /// Paragraph default for [TextRun.evenLeading].
  final bool evenLeading;

  final GPUTextWidthBasis textWidthBasis;

  /// Field-wise equality so views can skip a worker round-trip when a parent
  /// rebuild reconstructs an identical style. [lineBreaker] falls back to
  /// identity for non-const custom breakers — that direction is safe (an
  /// unnecessary reflow, never a skipped one).
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GPUTextLayoutStyle &&
          other.align == align &&
          other.lineHeight == lineHeight &&
          other.maxLines == maxLines &&
          other.softWrap == softWrap &&
          other.addEllipsis == addEllipsis &&
          other.lineBreaker == lineBreaker &&
          other.strut == strut &&
          other.applyHeightToFirstAscent == applyHeightToFirstAscent &&
          other.applyHeightToLastDescent == applyHeightToLastDescent &&
          other.evenLeading == evenLeading &&
          other.textWidthBasis == textWidthBasis;

  @override
  int get hashCode => Object.hash(
    align,
    lineHeight,
    maxLines,
    softWrap,
    addEllipsis,
    lineBreaker,
    strut,
    applyHeightToFirstAscent,
    applyHeightToLastDescent,
    evenLeading,
    textWidthBasis,
  );

  GPUTextLayoutStyle copyWith({
    TextAlign? align,
    double? lineHeight,
    int? maxLines,
    bool clearMaxLines = false,
    bool? softWrap,
    bool? addEllipsis,
    LineBreaker? lineBreaker,
    StrutMetrics? strut,
    bool clearStrut = false,
    bool? applyHeightToFirstAscent,
    bool? applyHeightToLastDescent,
    bool? evenLeading,
    GPUTextWidthBasis? textWidthBasis,
  }) => GPUTextLayoutStyle(
    align: align ?? this.align,
    lineHeight: lineHeight ?? this.lineHeight,
    maxLines: clearMaxLines ? null : (maxLines ?? this.maxLines),
    softWrap: softWrap ?? this.softWrap,
    addEllipsis: addEllipsis ?? this.addEllipsis,
    lineBreaker: lineBreaker ?? this.lineBreaker,
    strut: clearStrut ? null : (strut ?? this.strut),
    applyHeightToFirstAscent:
        applyHeightToFirstAscent ?? this.applyHeightToFirstAscent,
    applyHeightToLastDescent:
        applyHeightToLastDescent ?? this.applyHeightToLastDescent,
    evenLeading: evenLeading ?? this.evenLeading,
    textWidthBasis: textWidthBasis ?? this.textWidthBasis,
  );

  /// Build the Layer-0 [ParagraphStyle] for a given wrap width.
  ParagraphStyle toParagraphStyle(double wrapWidth) => ParagraphStyle(
    maxWidth: wrapWidth,
    align: align,
    lineHeight: lineHeight,
    maxLines: maxLines,
    addEllipsis: addEllipsis,
    lineBreaker: lineBreaker,
    strut: strut,
    applyHeightToFirstAscent: applyHeightToFirstAscent,
    applyHeightToLastDescent: applyHeightToLastDescent,
    evenLeading: evenLeading,
  );
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
    this.height,
    this.evenLeading,
    this.direction = TextDirection.ltr,
    this.language,
    this.features = const {},
    this.decoration,
    this.background,
    this.hitTag,
  });

  final String text;
  final String fontId;
  final double fontSizePx;

  /// RGBA in 0..1.
  final List<double> color;
  final double letterSpacingPx;
  final double wordSpacingPx;

  /// Per-run [TextStyle.height] multiplier; null → font natural metrics only
  /// (paragraph [GPUTextLayoutStyle.lineHeight] still applies as leading).
  final double? height;

  /// Height-multiplier leading: true → split evenly; null → paragraph default.
  final bool? evenLeading;

  final TextDirection direction;

  /// BCP-47 / OpenType language tag for HarfBuzz (e.g. from
  /// [Locale.toLanguageTag]); null → shaper default.
  final String? language;

  /// OpenType feature tags → values, e.g. `{'smcp': 1, 'tnum': 1, 'liga': 0}`.
  /// Applied by HarfBuzz when a shaper is available.
  final Map<String, int> features;

  /// Underline / overline / line-through (mirrors [TextStyle.decoration]).
  final InlineDecoration? decoration;

  /// Highlight behind the run (mirrors [TextStyle.backgroundColor]), RGBA 0..1.
  final List<double>? background;

  /// Sendable hit-test tag returned in [GPUTextInstances.hitBoxes]. Use a
  /// stable string (e.g. from [flattenInlineSpan]) and map it back to a
  /// [TextSpan] / callback on the main isolate.
  final String? hitTag;
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
    this.style = const GPUTextLayoutStyle(),
    this.lineBreak,
    this.language,
    this.fallbackFontIds = const [],
    this.emojiFontId,
  });

  /// Convenience that fills [style] from the common shorthand fields.
  factory GPUTextLayoutRequest.basic({
    required List<GPUInlineSpec> runs,
    double maxWidth = double.infinity,
    TextAlign align = TextAlign.left,
    double lineHeight = 1.0,
    int? maxLines,
    LineBreakConfig? lineBreak,
    String? language,
    List<String> fallbackFontIds = const [],
    String? emojiFontId,
  }) => GPUTextLayoutRequest(
    runs: runs,
    maxWidth: maxWidth,
    style: GPUTextLayoutStyle(
      align: align,
      lineHeight: lineHeight,
      maxLines: maxLines,
    ),
    lineBreak: lineBreak,
    language: language,
    fallbackFontIds: fallbackFontIds,
    emojiFontId: emojiFontId,
  );

  final List<GPUInlineSpec> runs;
  final double maxWidth;
  final GPUTextLayoutStyle style;

  /// Opt-in hyphenation / SA-script segmentation; applied at prepare time.
  final LineBreakConfig? lineBreak;

  /// Default OpenType language for runs that omit [GPUTextRunSpec.language].
  final String? language;

  /// Ordered fallback font ids for characters the run's font doesn't cover
  /// (e.g. CJK, Arabic). Must be registered via [GPUTextWorker.registerFont].
  final List<String> fallbackFontIds;

  /// Font id of a COLR (layered-vector) or color-bitmap (sbix/CBDT) emoji
  /// font, or null. Prefer a COLR face (e.g. Twemoji) when available — bitmap
  /// fonts work too, but PNG decode/pack happens on the main isolate after
  /// reflow. Platform [Text] emoji fallback is not part of this path; use
  /// [GPURichText] for hybrid platform delegation.
  final String? emojiFontId;

  TextAlign get align => style.align;
  double get lineHeight => style.lineHeight;
  int? get maxLines => style.maxLines;
  GPUTextLayoutStyle get effectiveStyle => style;
}

/// A complete, self-contained drawable shipped back from the worker: the
/// glyph outline atlas ([curves]/[rows]) plus the [instances] that index into
/// it. Everything is transferred zero-copy — on the main isolate, feed
/// ([materializeCurves], [materializeRows], [materialize]) straight into
/// `GPUTextRenderer.create(...)` (or `uploadAtlasTextures` +
/// `GPUTextPipeline.renderInstances`) and draw. Nothing else is required for
/// coverage glyphs.
///
/// Color-bitmap (sbix/CBDT) emoji arrive as [colorGlyphStubs]: the worker
/// cannot decode PNGs (`dart:ui`), so the main isolate packs them into a
/// [SharedColorAtlas], builds the color instance buffer, and draws a second
/// pass with [GPUTextPipeline.renderColorInstances].
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
    double? contentWidth,
    this.placeholders = const [],
    this.decorations = const [],
    this.backgrounds = const [],
    this.hitBoxes = const [],
    this.atlasGeneration = 0,
    this.colorGlyphStubs = const [],
  }) : contentWidth = contentWidth ?? width;

  final TransferableTypedData instances;
  final TransferableTypedData? colorInstances;

  /// Quadratic-outline control points the coverage shader samples.
  final TransferableTypedData curves;

  /// Per-glyph band table into [curves].
  final TransferableTypedData rows;

  final int glyphCount;
  final int colorGlyphCount;
  final int lineCount;

  /// Alignment / wrap box width, logical px (the constraint used for layout
  /// when soft-wrapping). The GPU viewport is this wide.
  final double width;

  /// Horizontal scroll extent: max of [width] and the longest laid-out line.
  /// Wider than [width] when `softWrap: false` (without ellipsis) or an
  /// unbreakable run overflows — callers should allow horizontal pan.
  final double contentWidth;

  final double height;
  final bool didExceedMaxLines;

  /// Boxes for flattened WidgetSpans, in document-layout space. Position your
  /// real widgets at these (each [PlaceholderBox.index] matches the
  /// [GPUPlaceholderSpec.index] you sent). Empty when there are no placeholders.
  final List<PlaceholderBox> placeholders;

  /// Underline / overline / line-through strokes in document-layout space.
  final List<DecorationLine> decorations;

  /// Highlight rects painted under the glyphs, in document-layout space.
  final List<BackgroundRect> backgrounds;

  /// Per-run hit rects tagged with [GPUTextRunSpec.hitTag] (as [HitSpanBox.source]).
  final List<HitSpanBox> hitBoxes;

  /// [SharedGlyphAtlas.generation] at emit time. Prepared docs share one
  /// atlas on the worker (append-only); when this rises, re-upload curves/rows.
  /// Returned even when [curves]/[rows] were omitted (`includeAtlas: false`).
  final int atlasGeneration;

  /// Color-bitmap emoji PNG stubs for the main isolate to decode/pack. Empty
  /// when the doc has no sbix/CBDT emoji (COLR emoji use coverage layers).
  final List<GPUColorGlyphStub> colorGlyphStubs;

  /// Materialize the coverage-glyph instance buffer on the receiving isolate.
  Float32List materialize() => instances.materialize().asFloat32List();

  /// Materialize the color-bitmap (emoji) instance buffer, or null if none.
  /// Worker reflows leave this empty — pack [colorGlyphStubs] on the main
  /// isolate instead.
  Float32List? materializeColor() =>
      colorInstances?.materialize().asFloat32List();

  /// Materialize the outline atlas — pair with [materializeRows] and hand both
  /// to `uploadAtlasTextures` / `GPUTextRenderer.create`.
  Float32List materializeCurves() => curves.materialize().asFloat32List();
  Uint32List materializeRows() => rows.materialize().asUint32List();
}

/// One color-bitmap emoji placed by the worker: PNG bytes + layout position.
/// The main isolate packs [png] into a [SharedColorAtlas] under [cacheKey],
/// then builds a 12-float color instance from the atlas UV + these metrics.
class GPUColorGlyphStub {
  GPUColorGlyphStub({
    required this.cacheKey,
    required this.png,
    required this.strikePpem,
    required this.bearingX,
    required this.bearingY,
    required this.penX,
    required this.baselineY,
    required this.fontSizePx,
    required this.alpha,
  });

  /// Atlas key, typically `"$fontId:$glyphId:$strikePpem"`.
  final String cacheKey;

  /// Embedded PNG bytes (copied out of the font table for isolate transfer).
  final TransferableTypedData png;

  final int strikePpem;
  final double bearingX;
  final double bearingY;
  final double penX;
  final double baselineY;
  final double fontSizePx;
  final double alpha;

  Uint8List materializePng() => png.materialize().asUint8List();
}

/// One document in a [GPUTextWorker.syncDocs] batch: prepare it if the worker
/// doesn't hold it yet (when [runs] is provided), then reflow it at the batch
/// width with [style]. All fields are sendable.
class GPUTextSyncEntry {
  const GPUTextSyncEntry({
    required this.id,
    required this.style,
    this.runs,
    this.fallbackFontIds = const [],
    this.emojiFontId,
    this.lineBreak,
    this.language,
  });

  final String id;

  /// Layout policy for this entry's reflow (per-doc: entries in one batch may
  /// differ).
  final GPUTextLayoutStyle style;

  /// Content to prepare when [id] is not already prepared on the worker. Null
  /// means "must already be prepared" — an unknown id then yields a null slot
  /// in [GPUTextSyncResult.results] instead of an error.
  final List<GPUInlineSpec>? runs;

  final List<String> fallbackFontIds;
  final String? emojiFontId;
  final LineBreakConfig? lineBreak;
  final String? language;
}

/// Reply to a [GPUTextWorker.syncDocs] batch. [results] aligns with the
/// request's entries (null where an entry couldn't be prepared); per-entry
/// drawables never carry the atlas — [curves]/[rows] hold ONE shared-atlas
/// snapshot taken after every prepare in the batch ran, so a single upload
/// covers all of them.
class GPUTextSyncResult {
  GPUTextSyncResult({
    required this.results,
    required this.atlasGeneration,
    this.curves,
    this.rows,
  });

  final List<GPUTextInstances?> results;

  /// [SharedGlyphAtlas.generation] after the batch. When it exceeds the
  /// generation already uploaded and [curves] is null, fetch the atlas (e.g.
  /// an entries-empty `syncDocs(includeAtlas: true)`).
  final int atlasGeneration;

  /// Post-batch atlas snapshot when `includeAtlas` was requested, else null.
  final TransferableTypedData? curves;
  final TransferableTypedData? rows;

  Float32List? materializeCurves() => curves?.materialize().asFloat32List();
  Uint32List? materializeRows() => rows?.materialize().asUint32List();
}

/// A [reflowDoc] call that was dropped because a newer reflow for the same
/// document id was already queued on the worker (sampling coalesce). Callers
/// that fire overlapping reflows should treat this as "ignore — newer result
/// is coming", not as a hard failure.
class GPUTextReflowSuperseded implements Exception {
  @override
  String toString() => 'GPUTextReflowSuperseded';
}

/// Sentinel the worker sends when a queued reflow is collapsed by a newer one.
const Object _kReflowSuperseded = 'superseded';

/// A warm isolate that registers fonts once and answers layout requests. Spawn
/// one per app (or per heavy surface), keep it alive, stream requests at it.
///
/// **Reflow sampling:** overlapping [reflowDoc] calls for the same document id
/// collapse on the worker — only the latest queued args run; older futures
/// complete with [GPUTextReflowSuperseded]. That frees isolate bandwidth for
/// the width the UI actually settled on (e.g. during a resize drag).
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
  /// and keep it under [id]. Glyph outlines band into a **shared** atlas on the
  /// worker (append-only across every prepared doc), so common glyphs are not
  /// duplicated per paragraph. Run once per document, then [reflowDoc] cheaply
  /// at any width. Fonts referenced by [runs] must already be registered (see
  /// [registerFont]); flatten a Flutter `TextSpan` into [runs] with
  /// `flattenInlineSpan`. A single-style document is just a one-element list.
  ///
  /// [lineBreak] is baked into the prepared paragraph (hyphenation / SA-script
  /// segmentation); change it ⇒ re-prepare under a new id. [language] is the
  /// default OpenType language for runs that omit [GPUTextRunSpec.language].
  Future<void> prepareDoc(
    String id,
    List<GPUInlineSpec> runs, {
    List<String> fallbackFontIds = const [],
    String? emojiFontId,
    LineBreakConfig? lineBreak,
    String? language,
  }) async {
    final ok = await _send((
      'doc',
      id,
      runs,
      fallbackFontIds,
      emojiFontId,
      lineBreak,
      language,
    ));
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
  ///
  /// Pass [style] for full paragraph policy (align, maxLines, ellipsis, strut,
  /// line breaker, text-height behavior, …). [lineHeight] is kept as a
  /// shorthand that overrides [GPUTextLayoutStyle.lineHeight] when set.
  ///
  /// [dpr] selects the color-bitmap strike (device pixels) for sbix/CBDT emoji
  /// stubs — match the view's device pixel ratio so Retina gets a crisper
  /// strike. Ignored for COLR-only / no-emoji docs.
  ///
  /// Overlapping calls for the same [id] are sampled: the worker keeps only the
  /// latest queued args and completes older futures with
  /// [GPUTextReflowSuperseded] (in-flight compute still finishes — Dart cannot
  /// preempt sync layout — but anything still sitting in the mailbox is free).
  Future<GPUTextInstances> reflowDoc(
    String id,
    double width, {
    double? lineHeight,
    GPUTextLayoutStyle style = const GPUTextLayoutStyle(lineHeight: 1.3),
    bool includeAtlas = true,
    double dpr = 1.0,
  }) async {
    final effective = lineHeight == null
        ? style
        : style.copyWith(lineHeight: lineHeight);
    final reply = await _send((
      'reflow',
      id,
      width,
      effective,
      includeAtlas,
      dpr,
    ));
    if (identical(reply, _kReflowSuperseded) || reply == _kReflowSuperseded) {
      throw GPUTextReflowSuperseded();
    }
    if (reply is GPUTextInstances) return reply;
    throw StateError('reflowDoc failed: $reply');
  }

  /// Drop the document prepared under [id], freeing its shaped paragraph on the
  /// worker. The shared glyph atlas is kept (append-only; other docs may still
  /// reference its glyphs). Use it to bound shaped-paragraph memory when many
  /// documents are prepared lazily (e.g. per-paragraph blocks): evict the ones
  /// scrolled far out of view; re-[prepareDoc] them if they come back. A no-op
  /// if unknown.
  Future<void> disposeDoc(String id) async {
    await _send(('disposeDoc', id));
  }

  /// Prepare-if-needed + reflow every entry at [width] in ONE isolate round
  /// trip. This is the fling/resize catch-up path for block views: a window of
  /// N blocks costs one message each way instead of up to 2·N, so the first
  /// glyphs land a whole batch sooner.
  ///
  /// Per-entry drawables never include the atlas. When [includeAtlas] is true
  /// the reply carries ONE shared-atlas snapshot taken after every prepare in
  /// the batch, valid for all entries (and all previously prepared docs). An
  /// entries-empty call with [includeAtlas] is a cheap atlas-only fetch.
  ///
  /// Entries that cannot be prepared (no [GPUTextSyncEntry.runs] and unknown
  /// id, or no registered fonts) come back as null slots, never errors.
  /// Batches are not coalesced (unlike [reflowDoc]) — callers should
  /// single-flight and re-issue with fresh geometry, as the sliver views do.
  Future<GPUTextSyncResult> syncDocs(
    List<GPUTextSyncEntry> entries,
    double width, {
    bool includeAtlas = false,
    double dpr = 1.0,
  }) async {
    // Normalize the runtime element type: a `const []` argument would cross
    // the boundary as List<dynamic> and miss the worker's pattern match.
    final reply = await _send((
      'syncDocs',
      List<GPUTextSyncEntry>.of(entries),
      width,
      includeAtlas,
      dpr,
    ));
    if (reply is GPUTextSyncResult) return reply;
    throw StateError('worker syncDocs failed: $reply');
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
/// [atlas] is the worker's shared glyph atlas (not private to this doc).
class _Doc {
  _Doc(this.prepared, this.atlas, {this.emojiFontId});
  final PreparedParagraph prepared;
  final SharedGlyphAtlas atlas;

  /// Registered font id used for color emoji (COLR or bitmap), if any.
  final String? emojiFontId;
}

Future<void> _workerEntry(SendPort host) async {
  final rx = ReceivePort();
  host.send(rx.sendPort);
  final fonts = <String, GPUFont>{};
  final docs = <String, _Doc>{};
  // One atlas for every prepareDoc — append-only, so banding a new paragraph
  // never moves existing glyph rowBases (already-emitted instance buffers stay
  // valid). One-shot [layout] still builds a private atlas per request.
  final sharedAtlas = SharedGlyphAtlas();
  // Load HarfBuzz once in this isolate (sets GPUFont.outlineProvider). Null on
  // an unsupported platform → the pure-Dart per-rune fallback.
  final shaper = loadHarfBuzzShaper();

  // Inbox + pump (instead of bare `await for`): while a sync reflow runs,
  // later messages sit in the isolate port queue. After each job we yield so
  // [listen] drains them, then [_coalesceQueuedReflows] drops stale reflows
  // for the same doc id before we spend more CPU on them.
  final inbox = <(int, Object)>[];
  var pumping = false;

  Future<void> pump() async {
    if (pumping) return;
    pumping = true;
    try {
      while (inbox.isNotEmpty) {
        _coalesceQueuedReflows(inbox, host);
        if (inbox.isEmpty) break;
        final (seq, command) = inbox.removeAt(0);
        if (command == 'stop') {
          rx.close();
          inbox.clear();
          break;
        }
        Object? reply;
        try {
          reply = _dispatchCommand(
            command,
            fonts: fonts,
            docs: docs,
            sharedAtlas: sharedAtlas,
            shaper: shaper,
          );
        } catch (e, st) {
          reply = 'error: $e\n$st';
        }
        host.send((seq, reply));
        // Let [listen] pull any messages that arrived during sync work.
        await Future<void>.delayed(Duration.zero);
      }
    } finally {
      pumping = false;
      if (inbox.isNotEmpty) {
        unawaited(pump());
      }
    }
  }

  rx.listen((msg) {
    final (int seq, Object command) = msg as (int, Object);
    inbox.add((seq, command));
    unawaited(pump());
  });
}

/// Run one worker command. Kept separate from the pump so coalesce / stop
/// handling stay easy to read.
Object? _dispatchCommand(
  Object command, {
  required Map<String, GPUFont> fonts,
  required Map<String, _Doc> docs,
  required SharedGlyphAtlas sharedAtlas,
  required TextShaper? shaper,
}) {
  switch (command) {
    case ('font', final String id, final TransferableTypedData bytes):
      fonts[id] = GPUFont.parse(bytes.materialize().asUint8List());
      return true;
    case ('layout', final GPUTextLayoutRequest req):
      return _runLayout(req, fonts, shaper);
    case (
      'doc',
      final String id,
      final List<GPUInlineSpec> runs,
      final List<String> fallbackFontIds,
      final String? emojiFontId,
      final LineBreakConfig? lineBreak,
      final String? language,
    ):
      return _prepareDoc(
        id,
        runs,
        fallbackFontIds,
        emojiFontId,
        lineBreak,
        language,
        fonts,
        shaper,
        docs,
        sharedAtlas,
      );
    case (
      'reflow',
      final String id,
      final double width,
      final GPUTextLayoutStyle style,
      final bool includeAtlas,
      final double dpr,
    ):
      return _reflowDoc(id, width, style, includeAtlas, dpr, docs, fonts);
    case ('disposeDoc', final String id):
      docs.remove(id);
      return true;
    case (
      'syncDocs',
      final List<GPUTextSyncEntry> entries,
      final double width,
      final bool includeAtlas,
      final double dpr,
    ):
      return _syncDocs(
        entries,
        width,
        includeAtlas,
        dpr,
        fonts,
        shaper,
        docs,
        sharedAtlas,
      );
    default:
      return 'unknown command';
  }
}

/// Batch prepare-if-needed + reflow (see [GPUTextWorker.syncDocs]). Entry
/// failures degrade to null slots so one bad block never fails the window.
GPUTextSyncResult _syncDocs(
  List<GPUTextSyncEntry> entries,
  double width,
  bool includeAtlas,
  double dpr,
  Map<String, GPUFont> fonts,
  TextShaper? shaper,
  Map<String, _Doc> docs,
  SharedGlyphAtlas sharedAtlas,
) {
  final results = <GPUTextInstances?>[];
  for (final e in entries) {
    if (!docs.containsKey(e.id)) {
      final runs = e.runs;
      if (runs == null ||
          !_prepareDoc(
            e.id,
            runs,
            e.fallbackFontIds,
            e.emojiFontId,
            e.lineBreak,
            e.language,
            fonts,
            shaper,
            docs,
            sharedAtlas,
          )) {
        results.add(null);
        continue;
      }
    }
    // Per-entry drawables skip the atlas; the batch-level snapshot below
    // covers every entry at once.
    results.add(_reflowDoc(e.id, width, e.style, false, dpr, docs, fonts));
  }
  return GPUTextSyncResult(
    results: results,
    atlasGeneration: sharedAtlas.generation,
    curves: includeAtlas
        ? TransferableTypedData.fromList([
            Float32List.fromList(sharedAtlas.curves),
          ])
        : null,
    rows: includeAtlas
        ? TransferableTypedData.fromList([
            Uint32List.fromList(sharedAtlas.rows),
          ])
        : null,
  );
}

/// Doc id of a reflow command, or null for any other command.
String? _reflowDocId(Object command) {
  if (command case (
    'reflow',
    final String id,
    final double _,
    final GPUTextLayoutStyle _,
    final bool _,
    final double _,
  )) {
    return id;
  }
  return null;
}

/// Collapse queued reflows: for each document id keep only the last entry in
/// [inbox] and reply [_kReflowSuperseded] for the ones we drop. Non-reflow
/// commands are left alone (ordering with prepare/dispose stays intact).
void _coalesceQueuedReflows(List<(int, Object)> inbox, SendPort host) {
  final lastByDoc = <String, int>{};
  for (var i = 0; i < inbox.length; i++) {
    final id = _reflowDocId(inbox[i].$2);
    if (id != null) lastByDoc[id] = i;
  }
  if (lastByDoc.isEmpty) return;

  final drop = <int>{};
  for (var i = 0; i < inbox.length; i++) {
    final id = _reflowDocId(inbox[i].$2);
    if (id != null && lastByDoc[id] != i) drop.add(i);
  }
  if (drop.isEmpty) return;

  final kept = <(int, Object)>[];
  for (var i = 0; i < inbox.length; i++) {
    if (drop.contains(i)) {
      host.send((inbox[i].$1, _kReflowSuperseded));
    } else {
      kept.add(inbox[i]);
    }
  }
  inbox
    ..clear()
    ..addAll(kept);
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
///
/// [language] is the default OpenType language for runs that omit
/// [GPUTextRunSpec.language].
List<InlineItem> buildRunItems(
  List<GPUInlineSpec> runs,
  Map<String, GPUFont> fonts,
  TextShaper? shaper, {
  List<String> fallbackFontIds = const [],
  String? emojiFontId,
  String? language,
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
    final lang = run.language ?? language;
    final bg = run.background == null ? null : List<double>.of(run.background!);
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
            height: run.height,
            evenLeading: run.evenLeading,
            decoration: run.decoration,
            background: bg,
            source: run.hitTag,
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
            language: lang,
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
            height: run.height,
            evenLeading: run.evenLeading,
            decoration: run.decoration,
            background: bg == null ? null : List<double>.of(bg),
            source: run.hitTag,
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

    // No color emoji font (COLR or sbix/CBDT) → plain text (emoji tofu).
    if (emojiFont == null ||
        !(emojiFont.hasColorGlyphs || emojiFont.hasBitmapGlyphs)) {
      emitText(run.text, run, primary);
      continue;
    }

    // Emoji-itemize FIRST (mirrors the widget path): pull out emoji clusters
    // (VS16 / skin-tone / ZWJ / flags / keycaps) that the emoji font resolves
    // to a single COLR or bitmap glyph; everything else goes through the text
    // path.
    final cps = run.text.runes.toList();
    final pending = StringBuffer();
    var i = 0;
    while (i < cps.length) {
      final end = emojiClusterEnd(cps, i);
      final emoji = end > i
          ? _resolveColorEmoji(
              String.fromCharCodes(cps.sublist(i, end)),
              emojiFont,
              shaper,
              run.fontSizePx,
              run.color,
              background: run.background,
              source: run.hitTag,
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

/// Resolve one emoji [cluster] to a COLR (layered-vector) or color-bitmap
/// (sbix/CBDT) glyph via the emoji font: shape it (HarfBuzz collapses
/// ZWJ/skin-tone sequences to one glyph), then read COLR layers or confirm a
/// bitmap strike. Returns null for an unsupported sequence, .notdef, or when
/// no shaper is available for a multi-codepoint cluster.
EmojiItem? _resolveColorEmoji(
  String cluster,
  GPUFont emojiFont,
  TextShaper? shaper,
  double fontSizePx,
  List<double> textColor, {
  List<double>? background,
  Object? source,
}) {
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
  final advance = emojiFont.advanceOfGlyphId(gid);
  final bg = background == null ? null : List<double>.of(background);
  final color = List<double>.of(textColor);
  final layers = emojiFont.colrForGlyphId(gid);
  if (layers != null && layers.isNotEmpty) {
    return EmojiItem(
      font: emojiFont,
      fontSizePx: fontSizePx,
      advanceUnits: advance,
      layers: layers,
      textColor: color,
      background: bg,
      source: source,
    );
  }
  // Color-bitmap (sbix / CBDT): coverage check at a nominal ppem; the worker
  // picks the DPR-aware strike later when collecting PNG stubs for the main
  // isolate's color atlas.
  if (emojiFont.hasBitmapGlyphs &&
      emojiFont.bitmapGlyphForId(gid, targetPpem: 64) != null) {
    return EmojiItem(
      font: emojiFont,
      fontSizePx: fontSizePx,
      advanceUnits: advance,
      bitmapGlyphId: gid,
      textColor: color,
      background: bg,
      source: source,
    );
  }
  return null;
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
    language: req.language,
  );
  final prepared = prepareParagraph(items, lineBreak: req.lineBreak);
  final atlas = SharedGlyphAtlas();
  bandRunItems(atlas, items);
  return _layoutPrepared(
    prepared,
    atlas,
    req.maxWidth,
    req.effectiveStyle,
    emojiFontId: req.emojiFontId,
    fonts: fonts,
  );
}

bool _prepareDoc(
  String id,
  List<GPUInlineSpec> runs,
  List<String> fallbackFontIds,
  String? emojiFontId,
  LineBreakConfig? lineBreak,
  String? language,
  Map<String, GPUFont> fonts,
  TextShaper? shaper,
  Map<String, _Doc> docs,
  SharedGlyphAtlas sharedAtlas,
) {
  final items = buildRunItems(
    runs,
    fonts,
    shaper,
    fallbackFontIds: fallbackFontIds,
    emojiFontId: emojiFontId,
    language: language,
  );
  if (items.isEmpty) return false;
  final prepared = prepareParagraph(items, lineBreak: lineBreak);
  // Band into the worker-shared atlas. Append-only: new glyphs extend
  // curves/rows; existing rowBases never move, so other docs' instance buffers
  // stay valid. Duplicate glyphs across paragraphs are stored once.
  bandRunItems(sharedAtlas, items);
  docs[id] = _Doc(prepared, sharedAtlas, emojiFontId: emojiFontId);
  return true;
}

GPUTextInstances _reflowDoc(
  String id,
  double width,
  GPUTextLayoutStyle style,
  bool includeAtlas,
  double dpr,
  Map<String, _Doc> docs,
  Map<String, GPUFont> fonts,
) {
  final doc = docs[id];
  if (doc == null) throw StateError('doc "$id" was never prepared');
  return _layoutPrepared(
    doc.prepared,
    doc.atlas,
    width,
    style,
    includeAtlas: includeAtlas,
    dpr: dpr,
    emojiFontId: doc.emojiFontId,
    fonts: fonts,
  );
}

/// Apply soft-wrap / ellipsis / width-basis policy around [layoutPreparedLines]
/// the same way [RenderGPUParagraph] does, then emit a transferable drawable.
GPUTextInstances _layoutPrepared(
  PreparedParagraph prepared,
  SharedGlyphAtlas atlas,
  double maxWidth,
  GPUTextLayoutStyle style, {
  bool includeAtlas = true,
  double dpr = 1.0,
  String? emojiFontId,
  Map<String, GPUFont>? fonts,
}) {
  final wrapWidth = style.softWrap && maxWidth.isFinite
      ? maxWidth
      : double.infinity;
  final lines = layoutPreparedLines(
    prepared,
    wrapWidth,
    style.toParagraphStyle(wrapWidth),
  );

  // softWrap:false + ellipsis truncates each overlong line at the box edge.
  if (style.addEllipsis && !style.softWrap && maxWidth.isFinite) {
    for (final line in lines.lines) {
      final lastRun = line.items.isEmpty ? null : line.items.last;
      final last = lastRun is LineRun ? lastRun.text : null;
      if (line.width > maxWidth && last != '…' && last != '...') {
        ellipsizeLine(line, maxWidth);
        // Ellipsis is synthesized after prepare — band it into the atlas.
        final ell = line.items.isEmpty ? null : line.items.last;
        if (ell is LineRun) atlas.ensureGlyphs(ell.font, ell.text);
      }
    }
  }

  // Alignment / reported width.
  var longest = 0.0;
  for (final l in lines.lines) {
    if (l.width > longest) longest = l.width;
  }
  final double boxWidth;
  if (!maxWidth.isFinite) {
    boxWidth = lines.maxIntrinsicWidth;
  } else {
    switch (style.textWidthBasis) {
      case GPUTextWidthBasis.parent:
        boxWidth = maxWidth;
      case GPUTextWidthBasis.longestLine:
        boxWidth = longest.clamp(0.0, maxWidth);
      case GPUTextWidthBasis.intrinsic:
        boxWidth = lines.maxIntrinsicWidth.clamp(0.0, maxWidth);
    }
  }
  // Overflow extent for horizontal scroll (softWrap:false, long unbreakables).
  final contentWidth =
      boxWidth.isFinite ? math.max(boxWidth, longest) : longest;

  return _drawable(
    lines,
    atlas,
    boxWidth,
    style.align,
    contentWidth: contentWidth,
    includeAtlas: includeAtlas,
    dpr: dpr,
    emojiFontId: emojiFontId,
    fonts: fonts,
  );
}

/// Package laid-out [lines] + [atlas] into a self-contained, transfer-ready
/// drawable. The fresh instance buffer is moved zero-copy; the atlas
/// ([curves]/[rows]) is copied then moved when [includeAtlas], else empty — it
/// is identical across a doc's reflows (and shared across prepared docs), so
/// send it once per generation. (A fresh empty buffer each time:
/// TransferableTypedData is single-use.)
///
/// Bitmap emoji PNG stubs are collected when [emojiFontId] points at a
/// registered sbix/CBDT font; [dpr] picks the strike.
GPUTextInstances _drawable(
  ParagraphLines lines,
  SharedGlyphAtlas atlas,
  double boxWidth,
  TextAlign align, {
  double? contentWidth,
  bool includeAtlas = true,
  double dpr = 1.0,
  String? emojiFontId,
  Map<String, GPUFont>? fonts,
}) {
  final stubs = <GPUColorGlyphStub>[];
  final emojiFont =
      emojiFontId == null || fonts == null ? null : fonts[emojiFontId];
  final emitted = emitInstances(
    lines,
    boxWidth,
    align,
    atlas,
    onBitmapEmoji: emojiFont == null || !emojiFont.hasBitmapGlyphs
        ? null
        : (item, penX, baselineY) {
            final gid = item.bitmapGlyphId;
            if (gid == null) return;
            final glyph = item.font.bitmapGlyphForId(
              gid,
              targetPpem: item.fontSizePx * dpr,
            );
            if (glyph == null || !glyph.isPng) return;
            // Copy PNG out of the font table — TransferableTypedData needs an
            // owned buffer, and the table view would dangle after transfer.
            final png = Uint8List.fromList(glyph.bytes);
            final alpha =
                item.textColor.length > 3 ? item.textColor[3] : 1.0;
            stubs.add(
              GPUColorGlyphStub(
                cacheKey: '$emojiFontId:$gid:${glyph.ppem}',
                png: TransferableTypedData.fromList([png]),
                strikePpem: glyph.ppem,
                bearingX: glyph.bearingX,
                bearingY: glyph.bearingY,
                penX: penX,
                baselineY: baselineY,
                fontSizePx: item.fontSizePx,
                alpha: alpha,
              ),
            );
          },
  );
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
    width: boxWidth,
    contentWidth: contentWidth ?? boxWidth,
    height: lines.height,
    didExceedMaxLines: lines.didExceedMaxLines,
    placeholders: emitted.placeholders,
    decorations: emitted.decorations,
    backgrounds: emitted.backgrounds,
    hitBoxes: emitted.hitBoxes,
    atlasGeneration: atlas.generation,
    colorGlyphStubs: stubs,
  );
}

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
/// width-basis policy that [GPURichText] applies around it.
class GPUTextLayoutStyle {
  const GPUTextLayoutStyle({
    this.align = TextAlign.left,
    this.lineHeight = 1.0,
    this.maxLines,
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

  /// Append '…' when [maxLines] is exceeded.
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

/// The selection source text of [runs] — each text run's characters, one
/// '￼' per placeholder — plus the placeholder offsets in it. This is the
/// SAME offset space the worker's layout geometry reports (fallback
/// splitting and emoji itemization preserve source text), so the main
/// isolate never needs the text shipped back.
({String text, Int32List placeholderOffsets}) flattenSpecSource(
  List<GPUInlineSpec> runs,
) {
  final buf = StringBuffer();
  final holes = <int>[];
  for (final spec in runs) {
    switch (spec) {
      case GPUTextRunSpec r:
        buf.write(r.text);
      case GPUPlaceholderSpec _:
        holes.add(buf.length);
        buf.write('\u{FFFC}');
    }
  }
  return (text: buf.toString(), placeholderOffsets: Int32List.fromList(holes));
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
    this.curveBase = 0,
    this.rowBase = 0,
    this.atlasStructure = 0,
    this.colorGlyphStubs = const [],
    this.geometry,
    this.lineTable,
    this.layoutGeneration = 0,
  }) : contentWidth = contentWidth ?? width;

  final TransferableTypedData instances;
  final TransferableTypedData? colorInstances;

  /// Selection-geometry snapshot for this drawable (same lines/box/align as
  /// the instances, so highlight rects match painted pens exactly), or null
  /// unless the request asked for it (`includeGeometry`). Also null when the
  /// document exceeds the selection-geometry budget (~250k source chars) —
  /// the snapshot is O(document). The BLOCK views use this (each block's
  /// geometry stays small); the single-document views use [lineTable] +
  /// on-demand [GPUTextWorker.fetchLineBand] instead, which has NO budget.
  /// Decode with [materializeGeometry]; see `SnapshotParagraphGeometry`.
  final TransferableTypedData? geometry;

  /// O(lines) selection line table for this drawable (single-document
  /// views), or null unless the request asked for it (`includeLineTable`).
  /// Never declined — ~29 B per line at any document size. Decode with
  /// `LineTable.decode`; per-line glyph detail arrives separately via
  /// [GPUTextWorker.fetchLineBand] tagged with [layoutGeneration].
  final TransferableTypedData? lineTable;

  /// The worker's layout generation for this doc at emit time (bumps every
  /// reflow). [GPUTextWorker.fetchLineBand] replies only for the current
  /// generation, so stale bands can never mix into a newer table.
  final int layoutGeneration;

  /// Quadratic-outline control points the coverage shader samples. When the
  /// request carried `sinceCurves`, this is the append-only TAIL of the shared
  /// atlas starting at [curveBase] — append it to the prefix already held to
  /// reconstruct the full snapshot. A default request ships the whole atlas
  /// ([curveBase] 0).
  final TransferableTypedData curves;

  /// Per-glyph band table into [curves] (same delta semantics, from [rowBase]).
  final TransferableTypedData rows;

  /// Float offset of [curves] within the shared atlas (0 = full snapshot).
  final int curveBase;

  /// Entry offset of [rows] within the shared atlas (0 = full snapshot).
  final int rowBase;

  /// [SharedGlyphAtlas.structureGeneration] at emit. When it differs from the
  /// value the held prefix was fetched under, that prefix is invalid — refetch
  /// the full snapshot (`sinceCurves: 0`).
  final int atlasStructure;

  final int glyphCount;
  final int colorGlyphCount;
  final int lineCount;

  /// Alignment / wrap box width, logical px (the constraint used for layout).
  /// The GPU viewport is this wide.
  final double width;

  /// Content extent: max of [width] and the longest laid-out line. Wider than
  /// [width] only when an unbreakable run overflows the wrap width.
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

  /// Decode the selection-geometry snapshot, or null when the request didn't
  /// ask for one. Idempotent: materialize neuters the transferable, so the
  /// first decode is cached and returned on later calls.
  SnapshotParagraphGeometry? materializeGeometry() {
    final g = geometry;
    if (g == null) return null;
    return _decodedGeometry ??= SnapshotParagraphGeometry.decode(
      g.materialize(),
    );
  }

  SnapshotParagraphGeometry? _decodedGeometry;

  /// Decode the selection line table, or null when the request didn't ask
  /// for one. Idempotent (materialize neuters the transferable; the first
  /// decode is cached).
  LineTable? materializeLineTable() {
    final t = lineTable;
    if (t == null) return null;
    return _decodedLineTable ??= LineTable.decode(t.materialize());
  }

  LineTable? _decodedLineTable;
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
  /// The worker ships each strike's bytes ONCE — the first stub that places
  /// [cacheKey] carries them; later stubs for the same key are metrics-only
  /// (null here). A receiver that no longer holds a key's bytes can recover
  /// them with [GPUTextWorker.fetchColorPngs].
  final TransferableTypedData? png;

  final int strikePpem;
  final double bearingX;
  final double bearingY;
  final double penX;
  final double baselineY;
  final double fontSizePx;
  final double alpha;

  /// Materialize the PNG bytes, or null for a metrics-only stub (bytes were
  /// shipped with an earlier reply under the same [cacheKey]).
  Uint8List? materializePng() => png?.materialize().asUint8List();
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
    this.includeGeometry = false,
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

  /// Ship a selection-geometry snapshot with this entry's drawable (see
  /// [GPUTextInstances.geometry]; ignored above the ~250k source-char
  /// budget documented there).
  final bool includeGeometry;
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
    this.curveBase = 0,
    this.rowBase = 0,
    this.atlasStructure = 0,
  });

  final List<GPUTextInstances?> results;

  /// [SharedGlyphAtlas.generation] after the batch. When it exceeds the
  /// generation already uploaded and [curves] is null, fetch the atlas (e.g.
  /// an entries-empty `syncDocs(includeAtlas: true)`).
  final int atlasGeneration;

  /// Post-batch atlas snapshot when `includeAtlas` was requested, else null.
  /// Same delta semantics as [GPUTextInstances.curves]: when the request
  /// carried `sinceCurves`, this is the tail from [curveBase]/[rowBase].
  final TransferableTypedData? curves;
  final TransferableTypedData? rows;

  /// Offsets of the shipped tail within the shared atlas (0 = full snapshot).
  final int curveBase;
  final int rowBase;

  /// [SharedGlyphAtlas.structureGeneration] after the batch (see
  /// [GPUTextInstances.atlasStructure]).
  final int atlasStructure;

  Float32List? materializeCurves() => curves?.materialize().asFloat32List();
  Uint32List? materializeRows() => rows?.materialize().asUint32List();
}

/// Sendable request for [GPUTextWorker.syncStream] — a streaming (append-
/// mostly) document sync. One class rather than a bare tuple: the arity is
/// large and the coalescer needs to recognize it structurally.
class GPUTextStreamRequest {
  const GPUTextStreamRequest({
    required this.id,
    required this.runs,
    required this.width,
    required this.style,
    this.fallbackFontIds = const [],
    this.emojiFontId,
    this.lineBreak,
    this.language,
    this.includeAtlas = true,
    this.dpr = 1.0,
    this.sinceCurves = 0,
    this.sinceRows = 0,
    this.sinceStructure = 0,
    this.includeLineTable = false,
  });

  final String id;

  /// The FULL current content — the worker diffs against the previous sync.
  final List<GPUInlineSpec> runs;
  final double width;
  final GPUTextLayoutStyle style;
  final List<String> fallbackFontIds;
  final String? emojiFontId;
  final LineBreakConfig? lineBreak;
  final String? language;
  final bool includeAtlas;
  final double dpr;
  final int sinceCurves;
  final int sinceRows;
  final int sinceStructure;
  final bool includeLineTable;
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
  /// The glyph outline atlas ([GPUTextInstances.curves]/[rows]) barely changes
  /// across reflows (only ellipsization can band a new glyph), so callers that
  /// keep a CPU-side copy should pass [sinceCurves]/[sinceRows] and receive
  /// just the growth (see below) — that stays correct when OTHER docs' prepares
  /// grow the shared atlas. [includeAtlas] `false` omits the payload entirely
  /// (empty buffers); the receiver then reuses whatever it already uploaded.
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
  ///
  /// **Incremental atlas:** the shared atlas is append-only, so a caller that
  /// already holds a prefix can pass [sinceCurves]/[sinceRows] (the float /
  /// entry counts it holds) and [sinceStructure] (the
  /// [GPUTextInstances.atlasStructure] it was fetched under): the reply then
  /// carries only the tail beyond that prefix (usually empty), with
  /// [GPUTextInstances.curveBase]/[rowBase] marking where it appends. A
  /// structure mismatch falls back to a full snapshot (base 0). Defaults ship
  /// the full snapshot, as before.
  Future<GPUTextInstances> reflowDoc(
    String id,
    double width, {
    double? lineHeight,
    GPUTextLayoutStyle style = const GPUTextLayoutStyle(lineHeight: 1.3),
    bool includeAtlas = true,
    double dpr = 1.0,
    int sinceCurves = 0,
    int sinceRows = 0,
    int sinceStructure = 0,
    bool includeGeometry = false,
    bool includeLineTable = false,
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
      sinceCurves,
      sinceRows,
      sinceStructure,
      includeGeometry,
      includeLineTable,
    ));
    if (identical(reply, _kReflowSuperseded) || reply == _kReflowSuperseded) {
      throw GPUTextReflowSuperseded();
    }
    if (reply is GPUTextInstances) return reply;
    throw StateError('reflowDoc failed: $reply');
  }

  /// Fetch per-line selection detail (glyph/item placement records) for
  /// lines [firstLine, lastLine) of the layout tagged [generation] — the
  /// [GPUTextInstances.layoutGeneration] that came with the line table.
  /// Returns null when the worker has moved on to a newer layout (or never
  /// kept one): the caller's next reflow reply brings a fresh table and the
  /// band can be re-requested against it. Decode with `decodeLineBand`.
  Future<TransferableTypedData?> fetchLineBand(
    String id,
    int generation,
    int firstLine,
    int lastLine,
  ) async {
    final reply = await _send((
      'lineBand',
      id,
      generation,
      firstLine,
      lastLine,
    ));
    if (reply == null) return null;
    if (reply is TransferableTypedData) return reply;
    throw StateError('worker lineBand failed: $reply');
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
  /// [sinceCurves]/[sinceRows]/[sinceStructure] request an incremental atlas
  /// payload exactly as on [reflowDoc]; the tail offsets come back in
  /// [GPUTextSyncResult.curveBase]/[rowBase].
  Future<GPUTextSyncResult> syncDocs(
    List<GPUTextSyncEntry> entries,
    double width, {
    bool includeAtlas = false,
    double dpr = 1.0,
    int sinceCurves = 0,
    int sinceRows = 0,
    int sinceStructure = 0,
  }) async {
    // Normalize the runtime element type: a `const []` argument would cross
    // the boundary as List<dynamic> and miss the worker's pattern match.
    final reply = await _send((
      'syncDocs',
      List<GPUTextSyncEntry>.of(entries),
      width,
      includeAtlas,
      dpr,
      sinceCurves,
      sinceRows,
      sinceStructure,
    ));
    if (reply is GPUTextSyncResult) return reply;
    throw StateError('worker syncDocs failed: $reply');
  }

  /// Re-fetch color-bitmap emoji strike PNGs by [GPUColorGlyphStub.cacheKey].
  /// The worker ships each strike's bytes only once (with the first stub that
  /// places it); a receiver that dropped them — e.g. after a future color-atlas
  /// eviction — recovers the bytes here without re-preparing anything. Keys
  /// that can't be resolved (unregistered font, no matching strike) are simply
  /// absent from the result.
  /// STREAMING sync: prepare-if-changed + reflow + emit for an append-mostly
  /// document (an LLM response, a log tail). Pass the FULL current [runs]
  /// each call; the worker splits them into hard-break paragraph slices and
  /// re-shapes ONLY the slices whose content changed since the previous sync
  /// under this [id] — for a pure append that is just the growing tail
  /// paragraph, so per-sync HarfBuzz cost is O(delta), not O(document).
  /// (Segmentation, line breaking, and emission still run over the whole
  /// document — pure-arithmetic phases, cheap relative to shaping. The v1
  /// incremental design is sketched in docs/appendable-prepare.md.)
  ///
  /// After every sync the document is ALSO a normally-prepared doc under
  /// [id]: [reflowDoc], [fetchLineBand], and [disposeDoc] all work on it.
  /// Call [finishStream] when the stream completes to drop the per-slice
  /// shaping cache (the prepared doc stays).
  ///
  /// Contract and caveats:
  /// - [id] stays FIXED for the whole stream (unlike the prepare-cache id
  ///   contract, content is expected to change under it).
  /// - Retroactive edits are correct, just costlier: the diff finds a smaller
  ///   stable prefix and everything after it re-shapes.
  /// - A non-null [lineBreak] disables slice reuse in v0 (its callbacks lose
  ///   identity crossing the isolate) — every sync re-shapes fully.
  /// - Content must be non-empty (at least one shapeable run); sync only
  ///   after the first token arrives.
  /// - Overlapping calls for the same [id] coalesce like [reflowDoc]
  ///   (older futures throw [GPUTextReflowSuperseded]).
  Future<GPUTextInstances> syncStream(
    String id,
    List<GPUInlineSpec> runs, {
    required double width,
    GPUTextLayoutStyle style = const GPUTextLayoutStyle(lineHeight: 1.3),
    List<String> fallbackFontIds = const [],
    String? emojiFontId,
    LineBreakConfig? lineBreak,
    String? language,
    bool includeAtlas = true,
    double dpr = 1.0,
    int sinceCurves = 0,
    int sinceRows = 0,
    int sinceStructure = 0,
    bool includeLineTable = false,
  }) async {
    final reply = await _send((
      'syncStream',
      GPUTextStreamRequest(
        id: id,
        runs: runs,
        width: width,
        style: style,
        fallbackFontIds: fallbackFontIds,
        emojiFontId: emojiFontId,
        lineBreak: lineBreak,
        language: language,
        includeAtlas: includeAtlas,
        dpr: dpr,
        sinceCurves: sinceCurves,
        sinceRows: sinceRows,
        sinceStructure: sinceStructure,
        includeLineTable: includeLineTable,
      ),
    ));
    if (identical(reply, _kReflowSuperseded) || reply == _kReflowSuperseded) {
      throw GPUTextReflowSuperseded();
    }
    if (reply is GPUTextInstances) return reply;
    throw StateError('syncStream failed: $reply');
  }

  /// Drop the streaming shaping cache for [id]. The prepared document
  /// survives as an ordinary doc (same id — [reflowDoc] keeps working), so
  /// "hardening" a finished stream costs nothing. No-op for unknown ids.
  Future<void> finishStream(String id) async {
    final ok = await _send(('finishStream', id));
    if (ok != true) throw StateError('finishStream failed: $ok');
  }

  /// Diagnostics (tests only): (paragraph slices currently cached, slices
  /// shaped since the stream began), or null when [id] has no live streaming
  /// state.
  Future<(int, int)?> debugStreamStats(String id) async {
    final reply = await _send(('streamStats', id));
    if (reply == null) return null;
    if (reply is (int, int)) return reply;
    throw StateError('streamStats failed: $reply');
  }

  Future<Map<String, Uint8List>> fetchColorPngs(List<String> keys) async {
    final reply = await _send(('colorPng', List<String>.of(keys)));
    if (reply is! Map) throw StateError('worker colorPng failed: $reply');
    return {
      for (final MapEntry(:key, :value) in reply.entries)
        if (key is String && value is TransferableTypedData)
          key: value.materialize().asUint8List(),
    };
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
/// One hard-break paragraph slice of a streaming document: the spec slice
/// (kept for the equality diff) and its shaped items (the HarfBuzz output
/// this cache exists to reuse).
class _StreamChunk {
  _StreamChunk(this.specs, this.items);
  final List<GPUInlineSpec> specs;
  final List<InlineItem> items;
}

/// Worker-side state for one [GPUTextWorker.syncStream] document.
class _StreamState {
  _StreamState(this.fallbackFontIds, this.emojiFontId, this.language);
  final List<String> fallbackFontIds;
  final String? emojiFontId;
  final String? language;
  final chunks = <_StreamChunk>[];
  int shapedSlices = 0; // cumulative, for debugStreamStats

  /// Shaping-relevant config must match for chunk reuse to be sound.
  bool configMatches(GPUTextStreamRequest req) {
    if (emojiFontId != req.emojiFontId || language != req.language) {
      return false;
    }
    if (fallbackFontIds.length != req.fallbackFontIds.length) return false;
    for (var i = 0; i < fallbackFontIds.length; i++) {
      if (fallbackFontIds[i] != req.fallbackFontIds[i]) return false;
    }
    return true;
  }
}

class _Doc {
  _Doc(this.prepared, this.atlas, {this.emojiFontId});
  final PreparedParagraph prepared;
  final SharedGlyphAtlas atlas;

  /// Registered font id used for color emoji (COLR or bitmap), if any.
  final String? emojiFontId;

  /// Bumps on every reflow of this doc — tags line tables and gates
  /// [liveGeometries]-backed 'lineBand' replies so stale bands never answer.
  int layoutGeneration = 0;

  /// Recent table-carrying reflow layouts, keyed by generation, kept for
  /// 'lineBand' fetches. SEVERAL views may share one prepared doc id (each
  /// view's reflow bumps the generation); keeping a few generations lets
  /// every live view fetch detail against the table IT holds instead of
  /// starving all but the latest. Retained only while callers request line
  /// tables; freed by disposeDoc (or eviction as newer generations land).
  final Map<int, ParagraphGeometry> liveGeometries = {};

  static const int keptGenerations = 3;
}

Future<void> _workerEntry(SendPort host) async {
  final rx = ReceivePort();
  host.send(rx.sendPort);
  final fonts = <String, GPUFont>{};
  final docs = <String, _Doc>{};
  final streams = <String, _StreamState>{};
  // One atlas for every prepareDoc — append-only, so banding a new paragraph
  // never moves existing glyph rowBases (already-emitted instance buffers stay
  // valid). One-shot [layout] still builds a private atlas per request.
  final sharedAtlas = SharedGlyphAtlas();
  // Color-bitmap strike PNGs already shipped to the host (by cache key) —
  // later stubs for the same strike go metrics-only. Recoverable on the host
  // via the 'colorPng' command, so this never needs invalidation.
  final sentColorPngs = <String>{};
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
            streams: streams,
            sharedAtlas: sharedAtlas,
            shaper: shaper,
            sentColorPngs: sentColorPngs,
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
  required Map<String, _StreamState> streams,
  required SharedGlyphAtlas sharedAtlas,
  required TextShaper? shaper,
  required Set<String> sentColorPngs,
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
      final int sinceCurves,
      final int sinceRows,
      final int sinceStructure,
      final bool includeGeometry,
      final bool includeLineTable,
    ):
      return _reflowDoc(
        id,
        width,
        style,
        includeAtlas,
        dpr,
        docs,
        fonts,
        sinceCurves: sinceCurves,
        sinceRows: sinceRows,
        sinceStructure: sinceStructure,
        sentColorPngs: sentColorPngs,
        includeGeometry: includeGeometry,
        includeLineTable: includeLineTable,
      );
    case (
      'lineBand',
      final String id,
      final int generation,
      final int first,
      final int last,
    ):
      final g = docs[id]?.liveGeometries[generation];
      if (g == null) {
        return null; // stale or never kept — caller re-syncs on next reflow
      }
      final f = first.clamp(0, g.lineCount);
      final l = last.clamp(f, g.lineCount);
      return TransferableTypedData.fromList([
        encodeLineBand(g, f, l).asUint8List(),
      ]);
    case ('disposeDoc', final String id):
      docs.remove(id);
      streams.remove(id);
      return true;
    case ('syncStream', final GPUTextStreamRequest req):
      return _syncStream(
        req,
        fonts: fonts,
        shaper: shaper,
        docs: docs,
        streams: streams,
        sharedAtlas: sharedAtlas,
        sentColorPngs: sentColorPngs,
      );
    case ('finishStream', final String id):
      streams.remove(id);
      return true;
    case ('streamStats', final String id):
      final s = streams[id];
      return s == null ? null : (s.chunks.length, s.shapedSlices);
    case (
      'syncDocs',
      final List<GPUTextSyncEntry> entries,
      final double width,
      final bool includeAtlas,
      final double dpr,
      final int sinceCurves,
      final int sinceRows,
      final int sinceStructure,
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
        sinceCurves: sinceCurves,
        sinceRows: sinceRows,
        sinceStructure: sinceStructure,
        sentColorPngs: sentColorPngs,
      );
    case ('colorPng', final List<String> keys):
      return _extractColorPngs(keys, fonts);
    default:
      return 'unknown command';
  }
}

/// Resolve color-bitmap strike PNGs for the 'colorPng' command. Keys are
/// [GPUColorGlyphStub.cacheKey]s (`"<fontId>:<glyphId>:<strikePpem>"`) — the
/// font id may itself contain ':', so parse from the right. Unresolvable keys
/// are omitted.
Map<String, TransferableTypedData> _extractColorPngs(
  List<String> keys,
  Map<String, GPUFont> fonts,
) {
  final out = <String, TransferableTypedData>{};
  for (final key in keys) {
    final ppemSep = key.lastIndexOf(':');
    if (ppemSep <= 0) continue;
    final gidSep = key.lastIndexOf(':', ppemSep - 1);
    if (gidSep <= 0) continue;
    final ppem = int.tryParse(key.substring(ppemSep + 1));
    final gid = int.tryParse(key.substring(gidSep + 1, ppemSep));
    if (ppem == null || gid == null) continue;
    final glyph = fonts[key.substring(0, gidSep)]?.bitmapGlyphForId(
      gid,
      targetPpem: ppem.toDouble(),
    );
    // The key pins an exact strike; nearest-match returning another ppem
    // would pack wrong metrics under this key, so skip it instead.
    if (glyph == null || !glyph.isPng || glyph.ppem != ppem) continue;
    out[key] = TransferableTypedData.fromList([
      Uint8List.fromList(glyph.bytes),
    ]);
  }
  return out;
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
  SharedGlyphAtlas sharedAtlas, {
  int sinceCurves = 0,
  int sinceRows = 0,
  int sinceStructure = 0,
  Set<String>? sentColorPngs,
}) {
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
    results.add(
      _reflowDoc(
        e.id,
        width,
        e.style,
        false,
        dpr,
        docs,
        fonts,
        sentColorPngs: sentColorPngs,
        includeGeometry: e.includeGeometry,
      ),
    );
  }
  final (curveBase, rowBase) = _atlasTail(
    sharedAtlas,
    sinceCurves,
    sinceRows,
    sinceStructure,
  );
  return GPUTextSyncResult(
    results: results,
    atlasGeneration: sharedAtlas.generation,
    curves: includeAtlas
        ? TransferableTypedData.fromList([
            Float32List.sublistView(sharedAtlas.curves, curveBase),
          ])
        : null,
    rows: includeAtlas
        ? TransferableTypedData.fromList([
            Uint32List.sublistView(sharedAtlas.rows, rowBase),
          ])
        : null,
    curveBase: curveBase,
    rowBase: rowBase,
    atlasStructure: sharedAtlas.structureGeneration,
  );
}

/// Where an atlas payload for a caller holding `since*` starts: the held
/// prefix carries over only when it was fetched under the current structure
/// generation and doesn't overrun the atlas — otherwise ship from 0 (full).
/// TransferableTypedData copies the bytes at construction, so slicing the live
/// atlas views here is safe (and the only copy the payload pays).
(int, int) _atlasTail(
  SharedGlyphAtlas atlas,
  int sinceCurves,
  int sinceRows,
  int sinceStructure,
) {
  if (sinceStructure != atlas.structureGeneration) return (0, 0);
  return (
    sinceCurves.clamp(0, atlas.curveFloatCount),
    sinceRows.clamp(0, atlas.rowCount),
  );
}

/// Doc id of a reflow command, or null for any other command. This pattern
/// MUST match the 'reflow' tuple [GPUTextWorker.reflowDoc] sends (and
/// [_dispatchCommand] destructures) exactly — a drifted arity silently
/// disables reflow coalescing.
String? _reflowDocId(Object command) {
  if (command case (
    'reflow',
    final String id,
    final double _,
    final GPUTextLayoutStyle _,
    final bool _,
    final double _,
    final int _,
    final int _,
    final int _,
    final bool _,
    final bool _,
  )) {
    return id;
  }
  return null;
}

/// Sampling key for coalescable commands: reflows and stream syncs each
/// collapse per document id (namespaced so a reflow can't cancel a stream
/// sync of the same id or vice versa). Null = never coalesced.
String? _coalesceKey(Object command) {
  final reflowId = _reflowDocId(command);
  if (reflowId != null) return 'r $reflowId';
  if (command case ('syncStream', final GPUTextStreamRequest req)) {
    return 's ${req.id}';
  }
  return null;
}

/// Collapse queued reflows / stream syncs: for each document id keep only the
/// last entry in [inbox] and reply [_kReflowSuperseded] for the ones we drop.
/// Other commands are left alone (ordering with prepare/dispose stays intact).
void _coalesceQueuedReflows(List<(int, Object)> inbox, SendPort host) {
  final lastByDoc = <String, int>{};
  for (var i = 0; i < inbox.length; i++) {
    final id = _coalesceKey(inbox[i].$2);
    if (id != null) lastByDoc[id] = i;
  }
  if (lastByDoc.isEmpty) return;

  final drop = <int>{};
  for (var i = 0; i < inbox.length; i++) {
    final id = _coalesceKey(inbox[i].$2);
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
          shaped = shaped.withBidi(
            bidiLevel: br.level,
            direction: br.direction,
          );
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
      // Selection/copy content: without it the geometry's plainText holds
      // '￼' and copied text loses the emoji.
      sourceText: cluster,
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
      sourceText: cluster,
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

/// Streaming sync (see [GPUTextWorker.syncStream]): re-shape only the
/// hard-break paragraph slices whose specs changed since the last sync,
/// splice cached shaped items for the rest, then prepare + layout + emit the
/// whole document through the ordinary [_layoutPrepared] path. The result is
/// byte-compatible with a from-scratch [_prepareDoc] + [_reflowDoc] of the
/// same runs: slicing only changes HOW items were shaped ((prepare's text
/// analysis runs over concatenated adjacent runs, and '\n' is a UAX #9
/// paragraph separator, so bidi context resets at every slice boundary
/// regardless).
GPUTextInstances _syncStream(
  GPUTextStreamRequest req, {
  required Map<String, GPUFont> fonts,
  required TextShaper? shaper,
  required Map<String, _Doc> docs,
  required Map<String, _StreamState> streams,
  required SharedGlyphAtlas sharedAtlas,
  Set<String>? sentColorPngs,
}) {
  var state = streams[req.id];
  if (state != null && !state.configMatches(req)) {
    state = null; // shaping config changed — every cached slice is invalid
  }
  state ??= streams[req.id] = _StreamState(
    List<String>.of(req.fallbackFontIds),
    req.emojiFontId,
    req.language,
  );

  final slices = _splitAtHardBreaks(req.runs);
  // Longest stable prefix of paragraph slices. A LineBreakConfig's callbacks
  // lose identity crossing the isolate, so hyphenation/segmentation configs
  // conservatively disable reuse (v0 limitation, documented on syncStream).
  var stable = 0;
  if (req.lineBreak == null) {
    while (stable < slices.length &&
        stable < state.chunks.length &&
        _specListEquals(state.chunks[stable].specs, slices[stable])) {
      stable++;
    }
  }
  state.chunks.length = stable;
  for (var i = stable; i < slices.length; i++) {
    final items = buildRunItems(
      slices[i],
      fonts,
      shaper,
      fallbackFontIds: req.fallbackFontIds,
      emojiFontId: req.emojiFontId,
      language: req.language,
    );
    // Band only the fresh slices — cached slices' glyphs are already rows in
    // the append-only atlas.
    bandRunItems(sharedAtlas, items);
    state.chunks.add(_StreamChunk(slices[i], items));
    state.shapedSlices++;
  }

  final items = [for (final c in state.chunks) ...c.items];
  if (items.isEmpty) {
    throw StateError(
      'syncStream("${req.id}"): no shapeable content — sync only after the '
      'first token arrives (or check the runs\' fontIds are registered)',
    );
  }
  final prepared = prepareParagraph(items, lineBreak: req.lineBreak);
  final old = docs[req.id];
  final doc = _Doc(prepared, sharedAtlas, emojiFontId: req.emojiFontId);
  if (old != null) {
    // Keep lineBand generation continuity across syncs of the same stream.
    doc.layoutGeneration = old.layoutGeneration;
    doc.liveGeometries.addAll(old.liveGeometries);
  }
  docs[req.id] = doc;
  return _layoutPrepared(
    prepared,
    sharedAtlas,
    req.width,
    req.style,
    includeAtlas: req.includeAtlas,
    dpr: req.dpr,
    emojiFontId: req.emojiFontId,
    fonts: fonts,
    sinceCurves: req.sinceCurves,
    sinceRows: req.sinceRows,
    sinceStructure: req.sinceStructure,
    sentColorPngs: sentColorPngs,
    includeLineTable: req.includeLineTable,
    cacheDoc: doc,
  );
}

/// Partition [runs] into hard-break paragraph slices: each '\n' ends the
/// slice it belongs to (the newline character stays with the preceding
/// text, so concatenating the slices reproduces the input exactly).
/// Placeholders belong to the slice that is open when they appear.
List<List<GPUInlineSpec>> _splitAtHardBreaks(List<GPUInlineSpec> runs) {
  final slices = <List<GPUInlineSpec>>[];
  var cur = <GPUInlineSpec>[];
  for (final spec in runs) {
    if (spec is! GPUTextRunSpec) {
      cur.add(spec);
      continue;
    }
    final text = spec.text;
    var start = 0;
    while (true) {
      final nl = text.indexOf('\n', start);
      if (nl < 0) break;
      cur.add(
        start == 0 && nl + 1 == text.length
            ? spec
            : _withText(spec, text.substring(start, nl + 1)),
      );
      slices.add(cur);
      cur = <GPUInlineSpec>[];
      start = nl + 1;
    }
    if (start == 0) {
      cur.add(spec); // no newline at all — keep the original instance
    } else if (start < text.length) {
      cur.add(_withText(spec, text.substring(start)));
    }
  }
  if (cur.isNotEmpty) slices.add(cur);
  return slices;
}

GPUTextRunSpec _withText(GPUTextRunSpec s, String text) => GPUTextRunSpec(
  text: text,
  fontId: s.fontId,
  fontSizePx: s.fontSizePx,
  color: s.color,
  letterSpacingPx: s.letterSpacingPx,
  wordSpacingPx: s.wordSpacingPx,
  height: s.height,
  evenLeading: s.evenLeading,
  direction: s.direction,
  language: s.language,
  features: s.features,
  decoration: s.decoration,
  background: s.background,
  hitTag: s.hitTag,
);

bool _specListEquals(List<GPUInlineSpec> a, List<GPUInlineSpec> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (!_specEquals(a[i], b[i])) return false;
  }
  return true;
}

bool _specEquals(GPUInlineSpec a, GPUInlineSpec b) {
  if (a is GPUTextRunSpec && b is GPUTextRunSpec) {
    return a.text == b.text &&
        a.fontId == b.fontId &&
        a.fontSizePx == b.fontSizePx &&
        _doubleListEquals(a.color, b.color) &&
        a.letterSpacingPx == b.letterSpacingPx &&
        a.wordSpacingPx == b.wordSpacingPx &&
        a.height == b.height &&
        a.evenLeading == b.evenLeading &&
        a.direction == b.direction &&
        a.language == b.language &&
        _featureMapEquals(a.features, b.features) &&
        _decorationEquals(a.decoration, b.decoration) &&
        _doubleListEquals(a.background, b.background) &&
        a.hitTag == b.hitTag;
  }
  if (a is GPUPlaceholderSpec && b is GPUPlaceholderSpec) {
    return a.index == b.index &&
        a.width == b.width &&
        a.height == b.height &&
        a.alignment == b.alignment &&
        a.baselineOffset == b.baselineOffset;
  }
  return false;
}

bool _doubleListEquals(List<double>? a, List<double>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _featureMapEquals(Map<String, int> a, Map<String, int> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (final e in a.entries) {
    if (b[e.key] != e.value) return false;
  }
  return true;
}

bool _decorationEquals(InlineDecoration? a, InlineDecoration? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null) return false;
  return a.underline == b.underline &&
      a.overline == b.overline &&
      a.lineThrough == b.lineThrough &&
      a.style == b.style &&
      a.thickness == b.thickness &&
      _doubleListEquals(a.color, b.color);
}

GPUTextInstances _reflowDoc(
  String id,
  double width,
  GPUTextLayoutStyle style,
  bool includeAtlas,
  double dpr,
  Map<String, _Doc> docs,
  Map<String, GPUFont> fonts, {
  int sinceCurves = 0,
  int sinceRows = 0,
  int sinceStructure = 0,
  Set<String>? sentColorPngs,
  bool includeGeometry = false,
  bool includeLineTable = false,
}) {
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
    sinceCurves: sinceCurves,
    sinceRows: sinceRows,
    sinceStructure: sinceStructure,
    sentColorPngs: sentColorPngs,
    includeGeometry: includeGeometry,
    includeLineTable: includeLineTable,
    cacheDoc: doc,
  );
}

/// Ceiling on a document's SOURCE length (UTF-16 units) for the FULL
/// selection-geometry snapshot (`includeGeometry`, used by the block views
/// where every block is paragraph-sized and never hits this). The snapshot
/// is O(document) — ~24 B per glyph plus an eager whole-document pen walk
/// per reflow (measured: a 2.6 M-char stress body costs +472 ms and a 93 MB
/// payload PER REFLOW) — so it stays budgeted. The single-document views no
/// longer use it: they request `includeLineTable` (O(lines), ~29 B/line, no
/// budget) and fetch per-line detail bands on demand, so selection works at
/// any document size.
const int _maxSelectionGeometryChars = 250000;

/// Debug-only "geometry skipped" warning, once per worker isolate.
bool _geometryBudgetWarned = false;

bool _withinGeometryBudget(List<InlineItem> items) {
  var chars = 0;
  for (final item in items) {
    chars += switch (item) {
      TextRun r => r.originalText.length,
      EmojiItem e => e.originalText.length,
      PlaceholderItem _ => 1,
    };
    if (chars > _maxSelectionGeometryChars) return false;
  }
  return true;
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
  int sinceCurves = 0,
  int sinceRows = 0,
  int sinceStructure = 0,
  Set<String>? sentColorPngs,
  bool includeGeometry = false,
  bool includeLineTable = false,
  _Doc? cacheDoc,
}) {
  if (includeGeometry && !_withinGeometryBudget(prepared.items)) {
    includeGeometry = false;
    assert(() {
      if (!_geometryBudgetWarned) {
        _geometryBudgetWarned = true;
        // ignore:   avoid_print
        print(
          'gputext: selection geometry skipped — document exceeds '
          '$_maxSelectionGeometryChars source chars. The snapshot costs '
          '~24 B/glyph and an extra pen walk PER REFLOW, which on '
          'multi-megabyte single documents multiplies reflow time and ships '
          'tens of MB per reply. The view degrades to "not selectable"; '
          'split huge content into blocks (GPUTextBlocksView / '
          'SliverGPUTextBlocks) to keep per-document geometry small.',
        );
      }
      return true;
    }());
  }
  final wrapWidth = maxWidth.isFinite ? maxWidth : double.infinity;
  final lines = layoutPreparedLines(
    prepared,
    wrapWidth,
    style.toParagraphStyle(wrapWidth),
  );

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
  // Overflow extent when a long unbreakable run exceeds the wrap width.
  final contentWidth = boxWidth.isFinite
      ? math.max(boxWidth, longest)
      : longest;

  // Selection geometry rides the same reply as the drawable it describes,
  // built from the SAME post-ellipsis lines/boxWidth/align emit uses, so
  // caret/highlight positions match painted pens by construction.
  final geometry = includeGeometry
      ? TransferableTypedData.fromList([
          encodeGeometrySnapshot(
            ParagraphGeometry(
              items: prepared.items,
              para: lines,
              boxWidth: boxWidth,
              align: style.align,
            ),
          ).asUint8List(),
        ])
      : null;

  // Single-document selection: the O(lines) table rides the reply and the
  // live geometry is retained for on-demand 'lineBand' fetches (placements
  // cache per line, so only fetched lines ever pay a pen walk). The
  // generation bumps on EVERY cached-doc reflow — with or without a table —
  // and a few recent generations stay fetchable so several views sharing
  // one doc id (each holding its own reply's table) all get detail. A
  // no-table reflow leaves earlier retained layouts alone for the same
  // reason.
  TransferableTypedData? lineTable;
  var layoutGeneration = 0;
  if (cacheDoc != null) {
    layoutGeneration = ++cacheDoc.layoutGeneration;
    if (includeLineTable) {
      final g = ParagraphGeometry(
        items: prepared.items,
        para: lines,
        boxWidth: boxWidth,
        align: style.align,
      );
      cacheDoc.liveGeometries[layoutGeneration] = g;
      while (cacheDoc.liveGeometries.length > _Doc.keptGenerations) {
        cacheDoc.liveGeometries.remove(cacheDoc.liveGeometries.keys.first);
      }
      lineTable = TransferableTypedData.fromList([
        encodeLineTable(g).asUint8List(),
      ]);
    }
  }

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
    sinceCurves: sinceCurves,
    sinceRows: sinceRows,
    sinceStructure: sinceStructure,
    sentColorPngs: sentColorPngs,
    geometrySnapshot: geometry,
    lineTable: lineTable,
    layoutGeneration: layoutGeneration,
  );
}

/// Package laid-out [lines] + [atlas] into a self-contained, transfer-ready
/// drawable. The fresh instance buffer is moved zero-copy; the atlas
/// ([curves]/[rows]) is copied once (by TransferableTypedData construction)
/// then moved when [includeAtlas], else empty. With `since*` from a caller
/// that already holds a prefix, only the append-only tail is copied/shipped
/// (see [_atlasTail]) — usually nothing. (A fresh empty buffer each time:
/// TransferableTypedData is single-use.)
///
/// Bitmap emoji PNG stubs are collected when [emojiFontId] points at a
/// registered sbix/CBDT font; [dpr] picks the strike. With [sentColorPngs],
/// each strike's bytes ship only on its first stub ever (metrics-only after) —
/// pass null to always embed bytes (self-contained one-shot replies).
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
  int sinceCurves = 0,
  int sinceRows = 0,
  int sinceStructure = 0,
  Set<String>? sentColorPngs,
  TransferableTypedData? geometrySnapshot,
  TransferableTypedData? lineTable,
  int layoutGeneration = 0,
}) {
  final stubs = <GPUColorGlyphStub>[];
  final emojiFont = emojiFontId == null || fonts == null
      ? null
      : fonts[emojiFontId];
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
            final cacheKey = '$emojiFontId:$gid:${glyph.ppem}';
            // Ship the strike's bytes only the first time this worker places
            // it (Set.add is false once seen); the receiver caches by key.
            // Copy PNG out of the font table — TransferableTypedData needs an
            // owned buffer, and the table view would dangle after transfer.
            final sendPng =
                sentColorPngs == null || sentColorPngs.add(cacheKey);
            final alpha = item.textColor.length > 3 ? item.textColor[3] : 1.0;
            stubs.add(
              GPUColorGlyphStub(
                cacheKey: cacheKey,
                png: sendPng
                    ? TransferableTypedData.fromList([
                        Uint8List.fromList(glyph.bytes),
                      ])
                    : null,
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
  // Compute the tail AFTER emit — ellipsization above may have banded the
  // '…' glyph, and the payload must cover everything [atlasGeneration] claims.
  final (curveBase, rowBase) = _atlasTail(
    atlas,
    sinceCurves,
    sinceRows,
    sinceStructure,
  );
  return GPUTextInstances(
    instances: TransferableTypedData.fromList([emitted.instances]),
    colorInstances: color.isEmpty
        ? null
        : TransferableTypedData.fromList([color]),
    curves: includeAtlas
        ? TransferableTypedData.fromList([
            Float32List.sublistView(atlas.curves, curveBase),
          ])
        : TransferableTypedData.fromList([Float32List(0)]),
    rows: includeAtlas
        ? TransferableTypedData.fromList([
            Uint32List.sublistView(atlas.rows, rowBase),
          ])
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
    curveBase: curveBase,
    rowBase: rowBase,
    atlasStructure: atlas.structureGeneration,
    colorGlyphStubs: stubs,
    geometry: geometrySnapshot,
    lineTable: lineTable,
    layoutGeneration: layoutGeneration,
  );
}

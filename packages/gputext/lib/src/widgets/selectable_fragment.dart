// The Selectable fragment shared by every gputext surface that talks to
// Flutter's SelectionArea/SelectableRegion: GPURichText's RenderGPUParagraph
// (UI-isolate layout) and the lowlevel worker-backed views (GPUTextView,
// blocks, slivers), which answer the same queries from a decoded
// SnapshotParagraphGeometry.
//
// The fragment mirrors RenderParagraph's _SelectableFragment: geometry
// queries run in SOURCE offsets, so copied content is the pre-shaping text
// even when ligatures render as single glyphs. Everything host-specific —
// where geometry comes from, coordinate mapping, repaint — goes through
// [GPUSelectableTextHost], so the event handling exists exactly once.

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../paragraph.dart' as wf;

/// What a render object (or adapter) must provide for its
/// [SelectableTextFragment]s.
///
/// Coordinate contract: [selectionGeometry] answers in a fixed "paragraph
/// local" space, and [selectionTransformTo] maps THAT space to an ancestor
/// (null = global). Hosts whose paint origin moves relative to the paragraph
/// (internal scrolling, per-block offsets) fold that shift into the
/// transform — fragment values stay scroll-invariant.
abstract interface class GPUSelectableTextHost {
  /// Query geometry for the current layout, or null while none exists (e.g.
  /// before the first worker snapshot arrives). Fragments degrade gracefully
  /// on null: empty geometry, events resolve without moving.
  wf.ParagraphGeometryBase? get selectionGeometry;

  TextDirection get selectionTextDirection;

  /// The paragraph's laid-out box in paragraph-local space (drag-adjust and
  /// selection-result classification use it).
  Size get selectionSize;

  /// Paragraph-local → [ancestor] (null = global), including any scroll or
  /// block offset between the paragraph space and the host's paint space.
  Matrix4 selectionTransformTo(RenderObject? ancestor);

  /// Whether highlight repaints can be requested right now (attached, sized).
  bool get selectionPaintReady;

  /// Request a repaint of whatever paints the selection highlight.
  void markSelectionPaintDirty();

  /// Highlight color (null paints no highlight, handles still work).
  Color? get selectionHighlightColor;
}

/// One placeholder-free stretch of a paragraph's source text, exposed to the
/// selection framework (SelectionArea / SelectableRegion).
class SelectableTextFragment with ChangeNotifier implements Selectable {
  SelectableTextFragment(this.host, this.range);

  final GPUSelectableTextHost host;

  /// Source-text offsets covered by this fragment (no placeholders inside).
  final TextRange range;

  int? _selectionStart;
  int? _selectionEnd;
  LayerLink? _startHandle;
  LayerLink? _endHandle;
  SelectionGeometry? _cachedGeometry;
  Rect? _cachedRect;

  @override
  SelectionGeometry get value => _cachedGeometry ??= _computeGeometry();

  /// Called by the host after (re)layout or a fresh geometry snapshot:
  /// positions moved, source offsets are still valid.
  void didChangeParagraphLayout() {
    _cachedRect = null;
    _updateGeometry();
  }

  void _updateGeometry() {
    final next = _computeGeometry();
    if (next == _cachedGeometry) return;
    _cachedGeometry = next;
    notifyListeners();
    if (host.selectionPaintReady) host.markSelectionPaintDirty();
  }

  SelectionGeometry _computeGeometry() {
    final hasContent = range.end > range.start;
    final g = host.selectionGeometry;
    final s = _selectionStart;
    final e = _selectionEnd;
    if (g == null || s == null || e == null) {
      return SelectionGeometry(
        status: SelectionStatus.none,
        hasContent: hasContent,
      );
    }
    final a = math.min(s, e);
    final b = math.max(s, e);
    final flipped = e < s;
    final collapsed = a == b;
    SelectionPoint point(wf.CaretMetrics c, TextSelectionHandleType type) =>
        SelectionPoint(
          localPosition: Offset(c.x, c.top + c.height),
          lineHeight: c.height,
          handleType: type,
        );
    return SelectionGeometry(
      status: collapsed
          ? SelectionStatus.collapsed
          : SelectionStatus.uncollapsed,
      hasContent: hasContent,
      startSelectionPoint: point(
        g.caretAt(s),
        collapsed
            ? TextSelectionHandleType.collapsed
            : (flipped
                  ? TextSelectionHandleType.right
                  : TextSelectionHandleType.left),
      ),
      endSelectionPoint: point(
        g.caretAt(e),
        collapsed
            ? TextSelectionHandleType.collapsed
            : (flipped
                  ? TextSelectionHandleType.left
                  : TextSelectionHandleType.right),
      ),
      selectionRects: [
        for (final r in _selectionRectsFor(g, a, b))
          Rect.fromLTRB(r.left, r.top, r.right, r.bottom),
      ],
    );
  }

  /// Per-line rect coverage above this span count switches to edge-anchored
  /// rects plus one coarse middle band, so [SelectionGeometry] stays O(1) on
  /// huge selections. Painting doesn't use these — the highlight is computed
  /// per frame from the host's visible band in [paint].
  static const int _kMaxExactRectLines = 256;

  /// Lines of exact rects kept at each edge when the cap kicks in — the
  /// magnifier and toolbar position off the edges, never the middle.
  static const int _kEdgeRectLines = 8;

  List<wf.SelectionRect> _selectionRectsFor(
    wf.ParagraphGeometryBase g,
    int a,
    int b,
  ) {
    if (a >= b || g.lineCount == 0) return const [];
    final startLine = g.lineForOffset(a, upstream: false);
    final endLine = g.lineForOffset(b, upstream: true);
    if (endLine - startLine + 1 <= _kMaxExactRectLines) {
      return g.boxesForRange(a, b);
    }
    final headEnd = g.lineEndAt(startLine + _kEdgeRectLines - 1).clamp(a, b);
    final tailStart = g.lineStartAt(endLine - _kEdgeRectLines + 1).clamp(a, b);
    final middle = g.rangeBounds(headEnd, tailStart);
    return [
      ...g.boxesForRange(a, headEnd),
      ?middle,
      ...g.boxesForRange(tailStart, b),
    ];
  }

  @override
  SelectionResult dispatchSelectionEvent(SelectionEvent event) {
    final SelectionResult result;
    if (event is SelectionEdgeUpdateEvent) {
      result = _updateEdge(
        event,
        isEnd: event.type == SelectionEventType.endEdgeUpdate,
      );
    } else if (event is ClearSelectionEvent) {
      _selectionStart = null;
      _selectionEnd = null;
      result = SelectionResult.none;
    } else if (event is SelectAllSelectionEvent) {
      _selectionStart = range.start;
      _selectionEnd = range.end;
      result = SelectionResult.none;
    } else if (event is SelectWordSelectionEvent) {
      result = _selectBoundaryAt(event.globalPosition, word: true);
    } else if (event is SelectParagraphSelectionEvent) {
      result = _selectBoundaryAt(event.globalPosition, word: false);
    } else if (event is GranularlyExtendSelectionEvent) {
      result = _granularlyExtend(event);
    } else if (event is DirectionallyExtendSelectionEvent) {
      result = _directionallyExtend(event);
    } else {
      result = SelectionResult.none;
    }
    _updateGeometry();
    return result;
  }

  Offset _globalToLocal(Offset global) {
    final transform = host.selectionTransformTo(null)..invert();
    return MatrixUtils.transformPoint(transform, global);
  }

  /// This fragment's own laid-out bounds (union of its text boxes),
  /// paragraph-local. Drag-edge routing works on THIS rect, not the whole
  /// paragraph box: a paragraph split by placeholders holds several
  /// fragments inside the same box, and each must cede the edge
  /// (next/previous) once the pointer moves past its own text, or the edge
  /// can never cross the placeholder. Mirrors
  /// RenderParagraph._SelectableFragment._rect.
  Rect get _rect {
    var rect = _cachedRect;
    if (rect != null) return rect;
    final g = host.selectionGeometry;
    if (g == null) {
      rect = Offset.zero & host.selectionSize;
    } else {
      // rangeBounds never walks a huge range: table-backed geometries
      // answer from their line table.
      final b = g.rangeBounds(range.start, range.end);
      rect = b == null
          ? Rect.zero
          : Rect.fromLTRB(b.left, b.top, b.right, b.bottom);
    }
    return _cachedRect = rect;
  }

  SelectionResult _updateEdge(
    SelectionEdgeUpdateEvent event, {
    required bool isEnd,
  }) {
    final local = _globalToLocal(event.globalPosition);
    final rect = _rect;
    if (rect.isEmpty) {
      // Nothing laid out for this range: hold no edge, just route the drag
      // past this fragment.
      if (isEnd) {
        _selectionEnd = null;
      } else {
        _selectionStart = null;
      }
      return SelectionUtils.getResultBasedOnRect(rect, local);
    }
    final adjusted = SelectionUtils.adjustDragOffset(
      rect,
      local,
      direction: host.selectionTextDirection,
    );
    final g = host.selectionGeometry;
    var offset =
        (g == null ? 0 : g.positionForOffset(adjusted.dx, adjusted.dy).offset)
            .clamp(range.start, range.end);
    if (event.granularity == TextGranularity.word) {
      // Long-press drags select whole words: snap the moving edge outward
      // from the anchor edge.
      final anchor = isEnd ? _selectionStart : _selectionEnd;
      if (g != null && g.plainText.isNotEmpty) {
        final w = wf.wordRangeIn(
          g.plainText,
          offset.clamp(0, g.plainText.length - 1),
        );
        offset = (anchor == null || offset >= anchor)
            ? w.end.clamp(range.start, range.end)
            : w.start.clamp(range.start, range.end);
      }
    }
    if (isEnd) {
      _selectionEnd = offset;
    } else {
      _selectionStart = offset;
    }
    return SelectionUtils.getResultBasedOnRect(rect, local);
  }

  SelectionResult _selectBoundaryAt(
    Offset globalPosition, {
    required bool word,
  }) {
    final g = host.selectionGeometry;
    if (g == null || range.end == range.start) return SelectionResult.end;
    final local = _globalToLocal(globalPosition);
    var at = g.positionForOffset(local.dx, local.dy).offset;
    if (at < range.start) at = range.start;
    final lastIn = math.max(range.start, range.end - 1);
    if (at > lastIn) at = lastIn;
    if (word) {
      final w = wf.wordRangeIn(g.plainText, at);
      _selectionStart = w.start.clamp(range.start, range.end);
      _selectionEnd = w.end.clamp(range.start, range.end);
    } else {
      // Paragraph: between newlines (clamped into the fragment).
      final text = g.plainText;
      var start = at;
      while (start > range.start && text.codeUnitAt(start - 1) != 0x0A) {
        start--;
      }
      var end = at;
      while (end < range.end && text.codeUnitAt(end) != 0x0A) {
        end++;
      }
      _selectionStart = start;
      _selectionEnd = end;
    }
    return SelectionResult.end;
  }

  static int _cpStart(String text, int index) {
    if (index <= 0) return 0;
    final unit = text.codeUnitAt(index);
    return (unit >= 0xDC00 && unit <= 0xDFFF) ? index - 1 : index;
  }

  static int _stepForward(String text, int offset) {
    if (offset >= text.length) return offset + 1;
    final unit = text.codeUnitAt(offset);
    final pair = unit >= 0xD800 && unit <= 0xDBFF && offset + 1 < text.length;
    return offset + (pair ? 2 : 1);
  }

  static int _stepBackward(String text, int offset) {
    if (offset <= 0) return -1;
    return _cpStart(text, offset - 1) == offset - 1
        ? offset - 1
        : _cpStart(text, offset - 1);
  }

  SelectionResult _granularlyExtend(GranularlyExtendSelectionEvent event) {
    final g = host.selectionGeometry;
    if (g == null) return SelectionResult.end;
    final text = g.plainText;
    var edge = event.isEnd ? _selectionEnd : _selectionStart;
    edge ??= event.isEnd ? _selectionStart : _selectionEnd;
    edge ??= event.forward ? range.start : range.end;

    int next;
    switch (event.granularity) {
      case TextGranularity.character:
        next = event.forward
            ? _stepForward(text, edge)
            : _stepBackward(text, edge);
      case TextGranularity.word:
        if (event.forward) {
          final probe = math.min(
            math.max(edge, 0),
            math.max(0, text.length - 1),
          );
          final w = wf.wordRangeIn(text, probe);
          next = w.end > edge ? w.end : _stepForward(text, edge);
        } else {
          final probe = math.max(0, edge - 1);
          final w = wf.wordRangeIn(text, probe);
          next = w.start < edge ? w.start : _stepBackward(text, edge);
        }
      case TextGranularity.line:
        final r = g.lineRange(
          g.caretAt(edge.clamp(range.start, range.end)).line,
        );
        next = event.forward ? r.end : r.start;
      case TextGranularity.paragraph:
      case TextGranularity.document:
        next = event.forward ? range.end : range.start;
    }

    final crossedForward = event.forward && next > range.end;
    final crossedBackward = !event.forward && next < range.start;
    final clamped = next.clamp(range.start, range.end);
    if (event.isEnd) {
      _selectionEnd = clamped;
    } else {
      _selectionStart = clamped;
    }
    (event.isEnd ? _selectionStart ??= edge : _selectionEnd ??= edge);
    if (crossedForward) return SelectionResult.next;
    if (crossedBackward) return SelectionResult.previous;
    return SelectionResult.end;
  }

  SelectionResult _directionallyExtend(
    DirectionallyExtendSelectionEvent event,
  ) {
    final g = host.selectionGeometry;
    if (g == null || g.lineCount == 0) return SelectionResult.end;
    final localDx = _globalToLocal(Offset(event.dx, 0)).dx;
    var edge = event.isEnd ? _selectionEnd : _selectionStart;
    edge ??= event.isEnd ? _selectionStart : _selectionEnd;

    int line;
    switch (event.direction) {
      case SelectionExtendDirection.forward:
        line = g.caretAt(range.start).line;
      case SelectionExtendDirection.backward:
        line = g.caretAt(range.end).line;
      case SelectionExtendDirection.previousLine:
        line =
            g
                .caretAt((edge ?? range.start).clamp(range.start, range.end))
                .line -
            1;
      case SelectionExtendDirection.nextLine:
        line =
            g.caretAt((edge ?? range.end).clamp(range.start, range.end)).line +
            1;
    }

    SelectionResult result = SelectionResult.end;
    int offset;
    if (line < 0) {
      offset = range.start;
      result = SelectionResult.previous;
    } else if (line >= g.lineCount) {
      offset = range.end;
      result = SelectionResult.next;
    } else {
      final mid = (g.lineTop(line) + g.lineBottom(line)) / 2;
      offset = g
          .positionForOffset(localDx, mid)
          .offset
          .clamp(range.start, range.end);
      if (offset <= range.start &&
          event.direction == SelectionExtendDirection.previousLine) {
        // Still inside, fine — previous only when we ran off the top above.
      }
    }
    if (event.isEnd) {
      _selectionEnd = offset;
      _selectionStart ??= edge ?? offset;
    } else {
      _selectionStart = offset;
      _selectionEnd ??= edge ?? offset;
    }
    return result;
  }

  @override
  SelectedContent? getSelectedContent() {
    final s = _selectionStart;
    final e = _selectionEnd;
    final g = host.selectionGeometry;
    if (s == null || e == null || s == e || g == null) return null;
    return SelectedContent(
      plainText: g.plainText.substring(math.min(s, e), math.max(s, e)),
    );
  }

  @override
  SelectedContentRange? getSelection() {
    final s = _selectionStart;
    final e = _selectionEnd;
    if (s == null || e == null) return null;
    return SelectedContentRange(
      startOffset: s - range.start,
      endOffset: e - range.start,
    );
  }

  @override
  int get contentLength => range.end - range.start;

  @override
  Matrix4 getTransformTo(RenderObject? ancestor) =>
      host.selectionTransformTo(ancestor);

  @override
  Size get size => host.selectionSize;

  @override
  List<Rect> get boundingBoxes {
    final g = host.selectionGeometry;
    if (g == null) {
      return <Rect>[Offset.zero & host.selectionSize];
    }
    final boxes = _selectionRectsFor(g, range.start, range.end);
    if (boxes.isEmpty) return <Rect>[Offset.zero & host.selectionSize];
    return [
      for (final b in boxes) Rect.fromLTRB(b.left, b.top, b.right, b.bottom),
    ];
  }

  @override
  void pushHandleLayers(LayerLink? startHandle, LayerLink? endHandle) {
    if (identical(startHandle, _startHandle) &&
        identical(endHandle, _endHandle)) {
      return;
    }
    _startHandle = startHandle;
    _endHandle = endHandle;
    if (host.selectionPaintReady) host.markSelectionPaintDirty();
  }

  /// Whether any (possibly collapsed) selection edge is set — hosts use it
  /// to pin geometry for blocks that scroll out of their live window.
  bool get hasSelection => _selectionStart != null || _selectionEnd != null;

  /// Paints the highlight and mobile handle anchors. Hosts call this UNDER
  /// the glyphs, with [offset] mapping paragraph-local to the paint space
  /// (consistent with [GPUSelectableTextHost.selectionTransformTo]).
  ///
  /// With a [cull] (paragraph-local visible window) the highlight rects are
  /// computed fresh from the geometry for JUST the culled band — bounded by
  /// visible lines however large the selection is. Without one (small
  /// paragraph hosts) the cached [value] rects paint as before.
  void paint(PaintingContext context, Offset offset, {Rect? cull}) {
    final geometry = value;
    if (geometry.status == SelectionStatus.uncollapsed) {
      final color = host.selectionHighlightColor;
      final g = host.selectionGeometry;
      if (color != null) {
        final paintObj = Paint()..color = color;
        final s = _selectionStart;
        final e = _selectionEnd;
        if (cull != null && g != null && s != null && e != null) {
          final a = math.min(s, e);
          final b = math.max(s, e);
          for (final r in g.boxesForRangeInBand(a, b, cull.top, cull.bottom)) {
            final rect = Rect.fromLTRB(r.left, r.top, r.right, r.bottom);
            if (!rect.overlaps(cull)) continue;
            context.canvas.drawRect(rect.shift(offset), paintObj);
          }
        } else {
          for (final r in geometry.selectionRects) {
            if (cull != null && !r.overlaps(cull)) continue;
            context.canvas.drawRect(r.shift(offset), paintObj);
          }
        }
      }
    }
    final start = geometry.startSelectionPoint;
    final end = geometry.endSelectionPoint;
    if (_startHandle != null && start != null) {
      context.pushLayer(
        LeaderLayer(link: _startHandle!, offset: offset + start.localPosition),
        (PaintingContext c, Offset o) {},
        Offset.zero,
      );
    }
    if (_endHandle != null && end != null) {
      context.pushLayer(
        LeaderLayer(link: _endHandle!, offset: offset + end.localPosition),
        (PaintingContext c, Offset o) {},
        Offset.zero,
      );
    }
  }
}

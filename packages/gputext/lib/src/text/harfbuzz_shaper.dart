// HarfBuzz TextShaper: FFI adapter producing [ShapedGlyphRun] with GPOS
// baked into advances/offsets (appliesKerning=false). Falls back is handled
// by the engine when bindings fail to load.

import 'dart:ffi';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../font.dart';
import '../native/harfbuzz_bindings.dart';
import 'shaped_run.dart';
import 'shaper.dart';

/// One `hb_face` per distinct font-byte buffer, shared by a base font and all
/// its variant instances (they alias the same [ByteData]). The face owns the
/// sole native copy of the file bytes: the blob frees them via its destroy
/// callback, and after creation the face holds the only blob reference.
class _HbSharedFace implements Finalizable {
  _HbSharedFace(this.face);

  final Pointer<HbFace> face;
}

/// Per-[GPUFont] `hb_font` (scale/variations state), keyed by font identity.
class _HbFontEntry implements Finalizable {
  _HbFontEntry(this.font, this.sharedFace);

  final Pointer<HbFont> font;

  /// Keeps the shared-face box (and its Expando entry) warm while any font
  /// made from it is alive; the native refcount protects the face regardless.
  final _HbSharedFace sharedFace;
}

/// HarfBuzz-backed shaper. Construct only when [HarfBuzzBindings.tryLoad]
/// succeeds.
class HarfBuzzShaper implements TextShaper {
  HarfBuzzShaper(this._hb);

  final HarfBuzzBindings _hb;
  final _fonts = Expando<_HbFontEntry>('gputextHbFont');
  final _sharedFaces = Expando<_HbSharedFace>('gputextHbFace');

  /// Weak tracking so [evictAllFonts] can find live entries (Expando is not
  /// iterable). Does not keep fonts alive.
  final _weakFonts = <WeakReference<GPUFont>>[];

  // Outline extraction (hb-draw). One shared draw-funcs object with the five
  // path callbacks; the callables are kept alive for the shaper's lifetime.
  Pointer<HbDrawFuncs>? _drawFuncsPtr;
  final _drawCallables = <NativeCallable>[];
  // Drawing is synchronous and single-threaded (HB calls the callbacks inline
  // on this isolate during hb_font_draw_glyph), so one active sink is safe.
  _DrawSink? _activeSink;

  // NativeFinalizers (unlike Dart Finalizers) also run at isolate shutdown /
  // hot restart, so native handles cannot outlive the process's Dart state.
  // Held in a static map so attachments stay guaranteed even if the shaper
  // instance itself is replaced and collected; at most two entries since
  // bindings are a process-wide singleton.
  static final _nativeFinalizers = <int, NativeFinalizer>{};
  static NativeFinalizer _finalizerFor(Pointer<NativeFinalizerFunction> fn) =>
      _nativeFinalizers[fn.address] ??= NativeFinalizer(fn);

  NativeFinalizer get _fontFinalizer => _finalizerFor(_hb.hbFontDestroyPtr);
  NativeFinalizer get _faceFinalizer => _finalizerFor(_hb.hbFaceDestroyPtr);

  @override
  void evictFont(GPUFont font) {
    final entry = _fonts[font];
    if (entry == null) return;
    _fonts[font] = null;
    _fontFinalizer.detach(entry);
    _hb.hbFontDestroy(entry.font);
    // The shared face is left to the native refcount + its own finalizer:
    // other variants of the same file may still be using it.
    _weakFonts.removeWhere((w) {
      final t = w.target;
      return t == null || identical(t, font);
    });
  }

  @override
  void evictAllFonts() {
    final live = <GPUFont>[];
    for (final weak in _weakFonts) {
      final font = weak.target;
      if (font != null) live.add(font);
    }
    _weakFonts.clear();
    for (final font in live) {
      evictFont(font);
    }
  }

  @override
  ShapedGlyphRun shape(ShapeRequest request) {
    if (request.text.isEmpty) {
      return ShapedGlyphRun(
        font: request.font,
        fontSizePx: request.fontSizePx,
        sourceText: request.text,
        pipelineText: request.text,
        glyphs: const [],
        appliesKerning: false,
        bidiLevel: request.bidiLevel,
        direction: request.direction,
      );
    }

    final entry = _fontFor(request.font);
    final upem = request.font.unitsPerEm;
    // Scale font to font units so advances match GPUFont.advanceOfGlyphId.
    _hb.hbFontSetScale(entry.font, upem, upem);

    final buf = _hb.hbBufferCreate();
    Pointer<HbFeature> featPtr = nullptr;
    try {
      final units = request.text.codeUnits;
      final ptr = calloc<Uint16>(units.length);
      try {
        ptr.asTypedList(units.length).setAll(0, units);
        _hb.hbBufferAddUtf16(buf, ptr, units.length, 0, units.length);
      } finally {
        calloc.free(ptr);
      }

      _hb.hbBufferSetDirection(
        buf,
        request.direction == TextDirection.rtl
            ? HbDirection.rtl
            : HbDirection.ltr,
      );

      final script = request.script;
      if (script != null && script.isNotEmpty) {
        final s = script.toNativeUtf8();
        final tag = _hb.hbScriptFromString(s, script.length);
        calloc.free(s);
        if (tag != 0) _hb.hbBufferSetScript(buf, tag);
      }
      final lang = request.language;
      if (lang != null && lang.isNotEmpty) {
        final l = lang.toNativeUtf8();
        final hbLang = _hb.hbLanguageFromString(l, lang.length);
        calloc.free(l);
        if (hbLang != nullptr) _hb.hbBufferSetLanguage(buf, hbLang);
      }
      _hb.hbBufferGuessSegmentProperties(buf);

      final features = _buildFeatures(request);
      featPtr = features.$1;
      final featCount = features.$2;
      _hb.hbShape(entry.font, buf, featPtr, featCount);

      final len = _hb.hbBufferGetLength(buf);
      final infos = _hb.hbBufferGetGlyphInfos(buf, nullptr);
      final positions = _hb.hbBufferGetGlyphPositions(buf, nullptr);

      final glyphs = <ShapedGlyph>[];
      final textLen = request.text.length;
      // Cluster starts, clamped into the text.
      final clusters = List<int>.generate(
        len,
        (i) => infos[i].cluster.clamp(0, textLen),
        growable: false,
      );
      // Cluster ends. HB emits glyphs in visual order: clusters are
      // non-decreasing for LTR but non-increasing for RTL, so a glyph's
      // cluster ends where the nearest larger neighboring cluster starts —
      // array-next for LTR, array-previous for RTL. The logically last
      // cluster extends to the end of the text (covers ligature tails).
      // Glyphs sharing a cluster (base + marks) share the same range.
      final ends = List<int>.filled(len, textLen);
      if (request.direction == TextDirection.rtl) {
        var end = textLen;
        for (var i = 0; i < len; i++) {
          if (i > 0 && clusters[i - 1] > clusters[i]) end = clusters[i - 1];
          ends[i] = end;
        }
      } else {
        var end = textLen;
        for (var i = len - 1; i >= 0; i--) {
          if (i + 1 < len && clusters[i + 1] > clusters[i]) {
            end = clusters[i + 1];
          }
          ends[i] = end;
        }
      }
      for (var i = 0; i < len; i++) {
        final info = infos[i];
        final pos = positions[i];
        var c0 = clusters[i];
        var c1 = ends[i];
        if (c1 <= c0) c1 = (c0 + 1).clamp(0, textLen);
        if (c0 >= textLen) {
          c0 = textLen;
          c1 = textLen;
        }

        glyphs.add(
          ShapedGlyph(
            glyphId: info.codepoint,
            cluster: c0,
            clusterEnd: c1,
            // Pipeline == source for HarfBuzz.
            shapedStart: c0,
            shapedEnd: c1,
            xAdvance: pos.xAdvance.toDouble(),
            yAdvance: pos.yAdvance.toDouble(),
            xOffset: pos.xOffset.toDouble(),
            yOffset: pos.yOffset.toDouble(),
          ),
        );
      }

      return ShapedGlyphRun(
        font: request.font,
        fontSizePx: request.fontSizePx,
        sourceText: request.text,
        pipelineText: request.text,
        glyphs: glyphs,
        sourceMap: null, // identity: pipeline == source
        bidiLevel: request.bidiLevel,
        direction: request.direction,
        appliesKerning: false,
      );
    } finally {
      if (featPtr != nullptr) calloc.free(featPtr);
      _hb.hbBufferDestroy(buf);
    }
  }

  (Pointer<HbFeature>, int) _buildFeatures(ShapeRequest request) {
    final specs = <String>[];
    // OpenType default features.
    final enabled = <String, int>{
      'ccmp': 1,
      'locl': 1,
      'rlig': 1,
      if (request.defaultLigatures) ...{'liga': 1, 'clig': 1, 'calt': 1},
    };
    // When default ligatures are off, explicitly disable HB's built-in
    // defaults so letterSpacing tracked-out text stays unligated.
    if (!request.defaultLigatures) {
      for (final tag in const ['liga', 'clig', 'calt']) {
        if (!request.features.containsKey(tag)) {
          specs.add('-$tag');
        }
      }
    }
    request.features.forEach((tag, value) {
      if (value == 0) {
        enabled.remove(tag);
        specs.add('-$tag');
      } else {
        enabled[tag] = value;
      }
    });
    for (final e in enabled.entries) {
      if (e.value == 1) {
        specs.add(e.key);
      } else {
        specs.add('${e.key}=${e.value}');
      }
    }
    if (specs.isEmpty) return (nullptr, 0);
    final ptr = calloc<HbFeature>(specs.length);
    var n = 0;
    try {
      for (final s in specs) {
        final utf = s.toNativeUtf8();
        final ok = _hb.hbFeatureFromString(utf, s.length, ptr + n);
        calloc.free(utf);
        if (ok != 0) {
          n++;
        }
      }
    } catch (_) {
      calloc.free(ptr);
      rethrow;
    }
    return (ptr, n);
  }

  _HbFontEntry _fontFor(GPUFont font) {
    final existing = _fonts[font];
    if (existing != null) return existing;

    final shared = _sharedFaceFor(font.fontBytes);
    final hbFont = _hb.hbFontCreate(shared.face);
    try {
      _hb.hbOtFontSetFuncs(hbFont);
      _applyVariations(hbFont, font);
    } catch (_) {
      _hb.hbFontDestroy(hbFont);
      rethrow;
    }
    final entry = _HbFontEntry(hbFont, shared);
    // Attach to [entry]: Expando drops it when [font] is GC'd, then the
    // finalizer runs. detach: entry so [evictFont] can destroy immediately.
    _fontFinalizer.attach(entry, hbFont.cast(), detach: entry);
    _fonts[font] = entry;
    _weakFonts.removeWhere((w) => w.target == null);
    _weakFonts.add(WeakReference(font));
    return entry;
  }

  /// Face for [bytes], created once per distinct byte buffer and shared by
  /// every [GPUFont] that aliases it (base + variants), so variants cost one
  /// small `hb_font` each instead of a full copy of the font file.
  _HbSharedFace _sharedFaceFor(ByteData bytes) {
    final existing = _sharedFaces[bytes];
    if (existing != null) return existing;

    final len = bytes.lengthInBytes;
    final owned = calloc<Uint8>(len);
    owned
        .asTypedList(len)
        .setAll(0, bytes.buffer.asUint8List(bytes.offsetInBytes, len));
    // The blob owns the copy: HB invokes the destroy callback (native free)
    // on user_data when the last blob reference goes away.
    final blob = _hb.hbBlobCreate(
      owned,
      len,
      HarfBuzzBindings.memoryModeReadonly,
      owned.cast(),
      calloc.nativeFree.cast(),
    );
    final face = _hb.hbFaceCreate(blob, 0);
    _hb.hbBlobDestroy(blob); // the face holds its own blob reference
    final shared = _HbSharedFace(face);
    // externalSize: the GC should feel the native font-file copy the face
    // keeps alive (freed via the blob destroy callback when the face dies).
    _faceFinalizer.attach(
      shared,
      face.cast(),
      detach: shared,
      externalSize: len,
    );
    _sharedFaces[bytes] = shared;
    return shared;
  }

  /// Push [GPUFont.variationCoordinates] onto the HB font so HVAR/GPOS
  /// advances match the GPU outline instance. Base fonts (empty coords) skip.
  void _applyVariations(Pointer<HbFont> hbFont, GPUFont font) {
    final coords = font.variationCoordinates;
    if (coords.isEmpty) return;
    final n = coords.length;
    final ptr = calloc<HbVariation>(n);
    try {
      var i = 0;
      for (final e in coords.entries) {
        ptr[i].tag = hbTagFromString(e.key);
        ptr[i].value = e.value;
        i++;
      }
      _hb.hbFontSetVariations(hbFont, ptr, n);
    } finally {
      calloc.free(ptr);
    }
  }

  // --- Outline extraction via hb_font_draw_glyph ---

  @override
  List<double>? drawGlyphOutline(GPUFont font, int gid) {
    try {
      final entry = _fontFor(font);
      final upem = font.unitsPerEm;
      // Font-unit coordinates (scale == upem) so the quads match the glyf path.
      _hb.hbFontSetScale(entry.font, upem, upem);
      final sink = _DrawSink(upem * 0.0005);
      _activeSink = sink;
      try {
        _hb.hbFontDrawGlyph(entry.font, gid, _drawFuncs(), nullptr);
      } finally {
        _activeSink = null;
      }
      sink.finish();
      return sink.out;
    } catch (_) {
      return null; // any FFI failure → let the caller use the pure-Dart parser
    }
  }

  Pointer<HbDrawFuncs> _drawFuncs() {
    final existing = _drawFuncsPtr;
    if (existing != null) return existing;
    final funcs = _hb.hbDrawFuncsCreate();
    final move = NativeCallable<HbDrawMoveToNative>.isolateLocal(_moveTo);
    final line = NativeCallable<HbDrawLineToNative>.isolateLocal(_lineTo);
    final quad = NativeCallable<HbDrawQuadToNative>.isolateLocal(_quadTo);
    final cubic = NativeCallable<HbDrawCubicToNative>.isolateLocal(_cubicTo);
    final close = NativeCallable<HbDrawCloseNative>.isolateLocal(_closePath);
    _hb.hbDrawFuncsSetMoveTo(funcs, move.nativeFunction, nullptr, nullptr);
    _hb.hbDrawFuncsSetLineTo(funcs, line.nativeFunction, nullptr, nullptr);
    _hb.hbDrawFuncsSetQuadTo(funcs, quad.nativeFunction, nullptr, nullptr);
    _hb.hbDrawFuncsSetCubicTo(funcs, cubic.nativeFunction, nullptr, nullptr);
    _hb.hbDrawFuncsSetClose(funcs, close.nativeFunction, nullptr, nullptr);
    // Kept alive for the shaper's lifetime (a process-wide singleton).
    _drawCallables.addAll([move, line, quad, cubic, close]);
    return _drawFuncsPtr = funcs;
  }

  void _moveTo(
    Pointer<HbDrawFuncs> df,
    Pointer<Void> dd,
    Pointer<HbDrawState> st,
    double x,
    double y,
    Pointer<Void> ud,
  ) => _activeSink?.moveTo(x, y);

  void _lineTo(
    Pointer<HbDrawFuncs> df,
    Pointer<Void> dd,
    Pointer<HbDrawState> st,
    double x,
    double y,
    Pointer<Void> ud,
  ) => _activeSink?.lineTo(x, y);

  void _quadTo(
    Pointer<HbDrawFuncs> df,
    Pointer<Void> dd,
    Pointer<HbDrawState> st,
    double cx,
    double cy,
    double x,
    double y,
    Pointer<Void> ud,
  ) => _activeSink?.quadTo(cx, cy, x, y);

  void _cubicTo(
    Pointer<HbDrawFuncs> df,
    Pointer<Void> dd,
    Pointer<HbDrawState> st,
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double x,
    double y,
    Pointer<Void> ud,
  ) => _activeSink?.cubicTo(c1x, c1y, c2x, c2y, x, y);

  void _closePath(
    Pointer<HbDrawFuncs> df,
    Pointer<Void> dd,
    Pointer<HbDrawState> st,
    Pointer<Void> ud,
  ) => _activeSink?.closePath();
}

/// Accumulates hb-draw path callbacks into glyf-compatible quads: Y is negated
/// to the atlas's Y-down space, lines become midpoint quads, cubics are
/// flattened, and contours are explicitly closed — identical to what the glyf
/// and CFF parsers produce, so the atlas/shader are unchanged.
class _DrawSink {
  _DrawSink(this.tolerance);

  final double tolerance;
  final List<double> out = [];
  double _cx = 0, _cy = 0, _sx = 0, _sy = 0;
  bool _open = false;

  void moveTo(double x, double y) {
    if (_open) _close();
    _cx = x;
    _cy = y;
    _sx = x;
    _sy = y;
    _open = true;
  }

  void lineTo(double x, double y) {
    _emitLine(_cx, _cy, x, y);
    _cx = x;
    _cy = y;
  }

  void quadTo(double qx, double qy, double x, double y) {
    out.addAll([_cx, -_cy, qx, -qy, x, -y]);
    _cx = x;
    _cy = y;
  }

  void cubicTo(
    double c1x,
    double c1y,
    double c2x,
    double c2y,
    double x,
    double y,
  ) {
    _flatten(_cx, _cy, c1x, c1y, c2x, c2y, x, y, 0);
    _cx = x;
    _cy = y;
  }

  void closePath() => _close();

  void finish() {
    if (_open) _close();
  }

  void _close() {
    if ((_cx - _sx).abs() > 1e-9 || (_cy - _sy).abs() > 1e-9) {
      _emitLine(_cx, _cy, _sx, _sy);
    }
    _open = false;
  }

  void _emitLine(double x0, double y0, double x1, double y1) {
    out.addAll([x0, -y0, (x0 + x1) / 2, -(y0 + y1) / 2, x1, -y1]);
  }

  void _flatten(
    double x0,
    double y0,
    double x1,
    double y1,
    double x2,
    double y2,
    double x3,
    double y3,
    int depth,
  ) {
    final ex = x0 - 3 * x1 + 3 * x2 - x3;
    final ey = y0 - 3 * y1 + 3 * y2 - y3;
    if (depth >= 8 || 0.04811 * math.sqrt(ex * ex + ey * ey) <= tolerance) {
      out.addAll([
        x0,
        -y0,
        (3 * x1 - x0 + 3 * x2 - x3) / 4,
        -(3 * y1 - y0 + 3 * y2 - y3) / 4,
        x3,
        -y3,
      ]);
      return;
    }
    final ax = (x0 + x1) / 2, ay = (y0 + y1) / 2;
    final bx = (x1 + x2) / 2, by = (y1 + y2) / 2;
    final cx = (x2 + x3) / 2, cy = (y2 + y3) / 2;
    final dx = (ax + bx) / 2, dy = (ay + by) / 2;
    final fx = (bx + cx) / 2, fy = (by + cy) / 2;
    final mx = (dx + fx) / 2, my = (dy + fy) / 2;
    _flatten(x0, y0, ax, ay, dx, dy, mx, my, depth + 1);
    _flatten(mx, my, fx, fy, cx, cy, x3, y3, depth + 1);
  }
}

// HarfBuzz TextShaper: FFI adapter producing [ShapedGlyphRun] with GPOS
// baked into advances/offsets (appliesKerning=false). Falls back is handled
// by the engine when bindings fail to load.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../font.dart';
import '../native/harfbuzz_bindings.dart';
import 'shaped_run.dart';
import 'shaper.dart';

/// Native HB objects + owned font bytes. Finalizer token must not retain the
/// Dart cache entry (or the GPUFont), only these pointers + bindings.
class _HbNativeHandles {
  _HbNativeHandles({
    required this.hb,
    required this.blob,
    required this.face,
    required this.font,
    required this.ownedBytes,
  });

  final HarfBuzzBindings hb;
  final Pointer<HbBlob> blob;
  final Pointer<HbFace> face;
  final Pointer<HbFont> font;
  final Pointer<Uint8> ownedBytes;

  var _destroyed = false;

  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    hb.hbFontDestroy(font);
    hb.hbFaceDestroy(face);
    hb.hbBlobDestroy(blob);
    calloc.free(ownedBytes);
  }
}

/// Face/font cache entry keyed by [GPUFont] identity.
class _HbFaceCache {
  _HbFaceCache(this.handles);

  final _HbNativeHandles handles;

  Pointer<HbFont> get font => handles.font;
}

/// HarfBuzz-backed shaper. Construct only when [HarfBuzzBindings.tryLoad]
/// succeeds.
class HarfBuzzShaper implements TextShaper {
  HarfBuzzShaper(this._hb);

  final HarfBuzzBindings _hb;
  final _faces = Expando<_HbFaceCache>('gputextHbFace');

  /// Weak tracking so [evictAllFonts] can find live entries (Expando is not
  /// iterable). Does not keep fonts alive.
  final _weakFonts = <WeakReference<GPUFont>>[];

  static final _finalizer = Finalizer<_HbNativeHandles>((h) => h.destroy());

  @override
  void evictFont(GPUFont font) {
    final entry = _faces[font];
    if (entry == null) return;
    _faces[font] = null;
    _finalizer.detach(entry);
    entry.handles.destroy();
  }

  @override
  void evictAllFonts() {
    for (final weak in _weakFonts) {
      final font = weak.target;
      if (font != null) evictFont(font);
    }
    _weakFonts.clear();
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

    final cache = _faceFor(request.font);
    final upem = request.font.unitsPerEm;
    // Scale font to font units so advances match GPUFont.advanceOfGlyphId.
    _hb.hbFontSetScale(cache.font, upem, upem);

    final buf = _hb.hbBufferCreate();
    Pointer<HbFeature> featPtr = nullptr;
    try {
      final units = request.text.codeUnits;
      final ptr = calloc<Uint16>(units.length);
      for (var i = 0; i < units.length; i++) {
        ptr[i] = units[i];
      }
      _hb.hbBufferAddUtf16(buf, ptr, units.length, 0, units.length);
      calloc.free(ptr);

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
      _hb.hbShape(cache.font, buf, featPtr, featCount);

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
            // Pipeline == source for HB (no PUA proxies).
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
    // Defaults matching LegacyGsubShaper / OpenType.
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
    for (final s in specs) {
      final utf = s.toNativeUtf8();
      final ok = _hb.hbFeatureFromString(utf, s.length, ptr + n);
      calloc.free(utf);
      if (ok != 0) {
        n++;
      }
    }
    return (ptr, n);
  }

  _HbFaceCache _faceFor(GPUFont font) {
    final existing = _faces[font];
    if (existing != null) return existing;

    final bytes = font.fontBytes;
    final len = bytes.lengthInBytes;
    final owned = calloc<Uint8>(len);
    final view = bytes.buffer.asUint8List(bytes.offsetInBytes, len);
    for (var i = 0; i < len; i++) {
      owned[i] = view[i];
    }
    final blob = _hb.hbBlobCreate(
      owned,
      len,
      HarfBuzzBindings.memoryModeReadonly,
      nullptr,
      nullptr,
    );
    final face = _hb.hbFaceCreate(blob, 0);
    final hbFont = _hb.hbFontCreate(face);
    _hb.hbOtFontSetFuncs(hbFont);
    _applyVariations(hbFont, font);
    final handles = _HbNativeHandles(
      hb: _hb,
      blob: blob,
      face: face,
      font: hbFont,
      ownedBytes: owned,
    );
    final entry = _HbFaceCache(handles);
    // Attach to [entry]: Expando drops it when [font] is GC'd, then Finalizer
    // runs. detach: entry so [evictFont] can destroy immediately.
    _finalizer.attach(entry, handles, detach: entry);
    _faces[font] = entry;
    _weakFonts.add(WeakReference(font));
    // Opportunistically prune dead weak refs so the list stays bounded.
    if (_weakFonts.length > 64) {
      _weakFonts.removeWhere((w) => w.target == null);
    }
    return entry;
  }

  /// Push [GPUFont.variationCoordinates] onto the HB font so HVAR/GPOS
  /// advances match the GPU outline instance. Base fonts (empty coords) skip.
  void _applyVariations(Pointer<HbFont> hbFont, GPUFont font) {
    final coords = font.variationCoordinates;
    if (coords.isEmpty) return;
    final n = coords.length;
    final ptr = calloc<HbVariation>(n);
    var i = 0;
    for (final e in coords.entries) {
      ptr[i].tag = hbTagFromString(e.key);
      ptr[i].value = e.value;
      i++;
    }
    _hb.hbFontSetVariations(hbFont, ptr, n);
    calloc.free(ptr);
  }
}

// Minimal HarfBuzz C API. Prefer @Native code assets registered by the
// package build hook. Fall back to DynamicLibrary.open of the bundled
// dylib only when the JIT native-assets map is missing (tooling bug).

// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Opaque HarfBuzz pointers.
typedef HbBlob = Opaque;
typedef HbFace = Opaque;
typedef HbFont = Opaque;
typedef HbBuffer = Opaque;

final class HbGlyphInfo extends Struct {
  @Uint32()
  external int codepoint;
  @Uint32()
  external int mask;
  @Uint32()
  external int cluster;
  @Uint32()
  external int var1;
  @Uint32()
  external int var2;
}

final class HbGlyphPosition extends Struct {
  @Int32()
  external int xAdvance;
  @Int32()
  external int yAdvance;
  @Int32()
  external int xOffset;
  @Int32()
  external int yOffset;
  @Uint32()
  external int var1;
}

final class HbFeature extends Struct {
  @Uint32()
  external int tag;
  @Uint32()
  external int value;
  @Uint32()
  external int start;
  @Uint32()
  external int end;
}

/// `hb_variation_t` — design-space axis tag + value.
final class HbVariation extends Struct {
  @Uint32()
  external int tag;
  @Float()
  external double value;
}

/// Direction values from hb-common.h.
abstract final class HbDirection {
  static const int invalid = 0;
  static const int ltr = 4;
  static const int rtl = 5;
  static const int ttb = 6;
  static const int btt = 7;
}

/// OpenType `HB_TAG(a,b,c,d)` from a 4-char axis/feature tag string.
int hbTagFromString(String tag) {
  final units = tag.codeUnits;
  final a = units.isNotEmpty ? units[0] : 0x20;
  final b = units.length > 1 ? units[1] : 0x20;
  final c = units.length > 2 ? units[2] : 0x20;
  final d = units.length > 3 ? units[3] : 0x20;
  return ((a & 0xff) << 24) | ((b & 0xff) << 16) | ((c & 0xff) << 8) | (d & 0xff);
}

const _assetId = 'package:gputext/src/native/harfbuzz_dylib.dart';

// Private Dart names (`_hb_*`) would otherwise be looked up as `_hb_*` /
// `__hb_*` on macOS; set [Native.symbol] to the real C exports.

@Native<
  Pointer<HbBlob> Function(
    Pointer<Uint8>,
    Int32,
    Int32,
    Pointer<Void>,
    Pointer<Void>,
  )
>(assetId: _assetId, isLeaf: true, symbol: 'hb_blob_create')
external Pointer<HbBlob> _hb_blob_create(
  Pointer<Uint8> data,
  int length,
  int mode,
  Pointer<Void> userData,
  Pointer<Void> destroy,
);

@Native<Void Function(Pointer<HbBlob>)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_blob_destroy',
)
external void _hb_blob_destroy(Pointer<HbBlob> blob);

@Native<Pointer<HbFace> Function(Pointer<HbBlob>, Uint32)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_face_create',
)
external Pointer<HbFace> _hb_face_create(Pointer<HbBlob> blob, int index);

@Native<Void Function(Pointer<HbFace>)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_face_destroy',
)
external void _hb_face_destroy(Pointer<HbFace> face);

@Native<Pointer<HbFont> Function(Pointer<HbFace>)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_font_create',
)
external Pointer<HbFont> _hb_font_create(Pointer<HbFace> face);

@Native<Void Function(Pointer<HbFont>)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_font_destroy',
)
external void _hb_font_destroy(Pointer<HbFont> font);

@Native<Void Function(Pointer<HbFont>, Int32, Int32)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_font_set_scale',
)
external void _hb_font_set_scale(Pointer<HbFont> font, int xScale, int yScale);

@Native<Void Function(Pointer<HbFont>, Pointer<HbVariation>, Uint32)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_font_set_variations',
)
external void _hb_font_set_variations(
  Pointer<HbFont> font,
  Pointer<HbVariation> variations,
  int variationsLength,
);

@Native<Void Function(Pointer<HbFont>)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_ot_font_set_funcs',
)
external void _hb_ot_font_set_funcs(Pointer<HbFont> font);

@Native<Pointer<HbBuffer> Function()>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_buffer_create',
)
external Pointer<HbBuffer> _hb_buffer_create();

@Native<Void Function(Pointer<HbBuffer>)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_buffer_destroy',
)
external void _hb_buffer_destroy(Pointer<HbBuffer> buffer);

@Native<
  Void Function(Pointer<HbBuffer>, Pointer<Uint16>, Int32, Uint32, Int32)
>(assetId: _assetId, isLeaf: true, symbol: 'hb_buffer_add_utf16')
external void _hb_buffer_add_utf16(
  Pointer<HbBuffer> buffer,
  Pointer<Uint16> text,
  int textLength,
  int itemOffset,
  int itemLength,
);

@Native<Void Function(Pointer<HbBuffer>, Int32)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_buffer_set_direction',
)
external void _hb_buffer_set_direction(Pointer<HbBuffer> buffer, int direction);

@Native<Void Function(Pointer<HbBuffer>, Uint32)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_buffer_set_script',
)
external void _hb_buffer_set_script(Pointer<HbBuffer> buffer, int script);

@Native<Void Function(Pointer<HbBuffer>, Pointer<Void>)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_buffer_set_language',
)
external void _hb_buffer_set_language(
  Pointer<HbBuffer> buffer,
  Pointer<Void> language,
);

@Native<Void Function(Pointer<HbBuffer>)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_buffer_guess_segment_properties',
)
external void _hb_buffer_guess_segment_properties(Pointer<HbBuffer> buffer);

@Native<Pointer<Void> Function(Pointer<Utf8>, Int32)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_language_from_string',
)
external Pointer<Void> _hb_language_from_string(Pointer<Utf8> str, int len);

@Native<Uint32 Function(Pointer<Utf8>, Int32)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_script_from_string',
)
external int _hb_script_from_string(Pointer<Utf8> str, int len);

@Native<
  Void Function(Pointer<HbFont>, Pointer<HbBuffer>, Pointer<HbFeature>, Uint32)
>(assetId: _assetId, isLeaf: true, symbol: 'hb_shape')
external void _hb_shape(
  Pointer<HbFont> font,
  Pointer<HbBuffer> buffer,
  Pointer<HbFeature> features,
  int numFeatures,
);

@Native<Uint32 Function(Pointer<HbBuffer>)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_buffer_get_length',
)
external int _hb_buffer_get_length(Pointer<HbBuffer> buffer);

@Native<Pointer<HbGlyphInfo> Function(Pointer<HbBuffer>, Pointer<Uint32>)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_buffer_get_glyph_infos',
)
external Pointer<HbGlyphInfo> _hb_buffer_get_glyph_infos(
  Pointer<HbBuffer> buffer,
  Pointer<Uint32> length,
);

@Native<Pointer<HbGlyphPosition> Function(Pointer<HbBuffer>, Pointer<Uint32>)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_buffer_get_glyph_positions',
)
external Pointer<HbGlyphPosition> _hb_buffer_get_glyph_positions(
  Pointer<HbBuffer> buffer,
  Pointer<Uint32> length,
);

@Native<Int32 Function(Pointer<Utf8>, Int32, Pointer<HbFeature>)>(
  assetId: _assetId,
  isLeaf: true,
  symbol: 'hb_feature_from_string',
)
external int _hb_feature_from_string(
  Pointer<Utf8> str,
  int len,
  Pointer<HbFeature> feature,
);

/// Loaded HarfBuzz symbols (from @Native or DynamicLibrary.open).
class HarfBuzzBindings {
  HarfBuzzBindings._({
    required this.hbBlobCreate,
    required this.hbBlobDestroy,
    required this.hbFaceCreate,
    required this.hbFaceDestroy,
    required this.hbFontCreate,
    required this.hbFontDestroy,
    required this.hbFontSetScale,
    required this.hbFontSetVariations,
    required this.hbOtFontSetFuncs,
    required this.hbBufferCreate,
    required this.hbBufferDestroy,
    required this.hbBufferAddUtf16,
    required this.hbBufferSetDirection,
    required this.hbBufferSetScript,
    required this.hbBufferSetLanguage,
    required this.hbBufferGuessSegmentProperties,
    required this.hbLanguageFromString,
    required this.hbScriptFromString,
    required this.hbShape,
    required this.hbBufferGetLength,
    required this.hbBufferGetGlyphInfos,
    required this.hbBufferGetGlyphPositions,
    required this.hbFeatureFromString,
    required this.hbFontDestroyPtr,
    required this.hbFaceDestroyPtr,
  });

  /// Memory mode: HB_MEMORY_MODE_READONLY = 1.
  static const int memoryModeReadonly = 1;

  final Pointer<HbBlob> Function(
    Pointer<Uint8>,
    int,
    int,
    Pointer<Void>,
    Pointer<Void>,
  )
  hbBlobCreate;
  final void Function(Pointer<HbBlob>) hbBlobDestroy;
  final Pointer<HbFace> Function(Pointer<HbBlob>, int) hbFaceCreate;
  final void Function(Pointer<HbFace>) hbFaceDestroy;
  final Pointer<HbFont> Function(Pointer<HbFace>) hbFontCreate;
  final void Function(Pointer<HbFont>) hbFontDestroy;
  final void Function(Pointer<HbFont>, int, int) hbFontSetScale;
  final void Function(Pointer<HbFont>, Pointer<HbVariation>, int)
  hbFontSetVariations;
  final void Function(Pointer<HbFont>) hbOtFontSetFuncs;
  final Pointer<HbBuffer> Function() hbBufferCreate;
  final void Function(Pointer<HbBuffer>) hbBufferDestroy;
  final void Function(Pointer<HbBuffer>, Pointer<Uint16>, int, int, int)
  hbBufferAddUtf16;
  final void Function(Pointer<HbBuffer>, int) hbBufferSetDirection;
  final void Function(Pointer<HbBuffer>, int) hbBufferSetScript;
  final void Function(Pointer<HbBuffer>, Pointer<Void>) hbBufferSetLanguage;
  final void Function(Pointer<HbBuffer>) hbBufferGuessSegmentProperties;
  final Pointer<Void> Function(Pointer<Utf8>, int) hbLanguageFromString;
  final int Function(Pointer<Utf8>, int) hbScriptFromString;
  final void Function(
    Pointer<HbFont>,
    Pointer<HbBuffer>,
    Pointer<HbFeature>,
    int,
  )
  hbShape;
  final int Function(Pointer<HbBuffer>) hbBufferGetLength;
  final Pointer<HbGlyphInfo> Function(Pointer<HbBuffer>, Pointer<Uint32>)
  hbBufferGetGlyphInfos;
  final Pointer<HbGlyphPosition> Function(Pointer<HbBuffer>, Pointer<Uint32>)
  hbBufferGetGlyphPositions;
  final int Function(Pointer<Utf8>, int, Pointer<HbFeature>)
  hbFeatureFromString;

  /// Raw `hb_font_destroy` / `hb_face_destroy` for [NativeFinalizer], which
  /// (unlike a Dart [Finalizer]) also runs at isolate shutdown / hot restart.
  final Pointer<NativeFinalizerFunction> hbFontDestroyPtr;
  final Pointer<NativeFinalizerFunction> hbFaceDestroyPtr;

  static HarfBuzzBindings? _cached;

  /// True when the last successful [tryLoad] used `@Native` / native assets.
  static bool loadedViaNative = false;

  /// True once the bundled dylib opened but a symbol lookup failed — a
  /// stale/partial build that cannot heal within this process. Remembered so
  /// repeated [tryLoad] calls (the engine retries on every shaper access)
  /// stop re-dlopening the library, whose handle is never closed.
  static bool _symbolLookupFailed = false;

  static HarfBuzzBindings? tryLoad() {
    if (_cached != null) return _cached;
    // 1) @Native code-asset path (requires non-empty native_assets.yaml).
    try {
      final buf = _hb_buffer_create();
      if (buf != nullptr) {
        _hb_buffer_destroy(buf);
        loadedViaNative = true;
        return _cached = HarfBuzzBindings._fromNative();
      }
    } catch (_) {}
    if (_symbolLookupFailed) return null;
    // 2) Narrow fallback: only the package-local hooks output directory.
    final lib = _openBundledDylib();
    if (lib == null) return null;
    try {
      loadedViaNative = false;
      return _cached = HarfBuzzBindings._fromLibrary(lib);
    } catch (_) {
      _symbolLookupFailed = true;
      return null;
    }
  }

  static HarfBuzzBindings _fromNative() => HarfBuzzBindings._(
    hbBlobCreate: _hb_blob_create,
    hbBlobDestroy: _hb_blob_destroy,
    hbFaceCreate: _hb_face_create,
    hbFaceDestroy: _hb_face_destroy,
    hbFontCreate: _hb_font_create,
    hbFontDestroy: _hb_font_destroy,
    hbFontSetScale: _hb_font_set_scale,
    hbFontSetVariations: _hb_font_set_variations,
    hbOtFontSetFuncs: _hb_ot_font_set_funcs,
    hbBufferCreate: _hb_buffer_create,
    hbBufferDestroy: _hb_buffer_destroy,
    hbBufferAddUtf16: _hb_buffer_add_utf16,
    hbBufferSetDirection: _hb_buffer_set_direction,
    hbBufferSetScript: _hb_buffer_set_script,
    hbBufferSetLanguage: _hb_buffer_set_language,
    hbBufferGuessSegmentProperties: _hb_buffer_guess_segment_properties,
    hbLanguageFromString: _hb_language_from_string,
    hbScriptFromString: _hb_script_from_string,
    hbShape: _hb_shape,
    hbBufferGetLength: _hb_buffer_get_length,
    hbBufferGetGlyphInfos: _hb_buffer_get_glyph_infos,
    hbBufferGetGlyphPositions: _hb_buffer_get_glyph_positions,
    hbFeatureFromString: _hb_feature_from_string,
    hbFontDestroyPtr: Native.addressOf<
      NativeFunction<Void Function(Pointer<HbFont>)>
    >(_hb_font_destroy).cast(),
    hbFaceDestroyPtr: Native.addressOf<
      NativeFunction<Void Function(Pointer<HbFace>)>
    >(_hb_face_destroy).cast(),
  );

  static HarfBuzzBindings _fromLibrary(
    DynamicLibrary lib,
  ) => HarfBuzzBindings._(
    hbBlobCreate: lib
        .lookupFunction<
          Pointer<HbBlob> Function(
            Pointer<Uint8>,
            Int32,
            Int32,
            Pointer<Void>,
            Pointer<Void>,
          ),
          Pointer<HbBlob> Function(
            Pointer<Uint8>,
            int,
            int,
            Pointer<Void>,
            Pointer<Void>,
          )
        >('hb_blob_create'),
    hbBlobDestroy: lib
        .lookupFunction<
          Void Function(Pointer<HbBlob>),
          void Function(Pointer<HbBlob>)
        >('hb_blob_destroy'),
    hbFaceCreate: lib
        .lookupFunction<
          Pointer<HbFace> Function(Pointer<HbBlob>, Uint32),
          Pointer<HbFace> Function(Pointer<HbBlob>, int)
        >('hb_face_create'),
    hbFaceDestroy: lib
        .lookupFunction<
          Void Function(Pointer<HbFace>),
          void Function(Pointer<HbFace>)
        >('hb_face_destroy'),
    hbFontCreate: lib
        .lookupFunction<
          Pointer<HbFont> Function(Pointer<HbFace>),
          Pointer<HbFont> Function(Pointer<HbFace>)
        >('hb_font_create'),
    hbFontDestroy: lib
        .lookupFunction<
          Void Function(Pointer<HbFont>),
          void Function(Pointer<HbFont>)
        >('hb_font_destroy'),
    hbFontSetScale: lib
        .lookupFunction<
          Void Function(Pointer<HbFont>, Int32, Int32),
          void Function(Pointer<HbFont>, int, int)
        >('hb_font_set_scale'),
    hbFontSetVariations: lib
        .lookupFunction<
          Void Function(Pointer<HbFont>, Pointer<HbVariation>, Uint32),
          void Function(Pointer<HbFont>, Pointer<HbVariation>, int)
        >('hb_font_set_variations'),
    hbOtFontSetFuncs: lib
        .lookupFunction<
          Void Function(Pointer<HbFont>),
          void Function(Pointer<HbFont>)
        >('hb_ot_font_set_funcs'),
    hbBufferCreate: lib
        .lookupFunction<
          Pointer<HbBuffer> Function(),
          Pointer<HbBuffer> Function()
        >('hb_buffer_create'),
    hbBufferDestroy: lib
        .lookupFunction<
          Void Function(Pointer<HbBuffer>),
          void Function(Pointer<HbBuffer>)
        >('hb_buffer_destroy'),
    hbBufferAddUtf16: lib
        .lookupFunction<
          Void Function(
            Pointer<HbBuffer>,
            Pointer<Uint16>,
            Int32,
            Uint32,
            Int32,
          ),
          void Function(Pointer<HbBuffer>, Pointer<Uint16>, int, int, int)
        >('hb_buffer_add_utf16'),
    hbBufferSetDirection: lib
        .lookupFunction<
          Void Function(Pointer<HbBuffer>, Int32),
          void Function(Pointer<HbBuffer>, int)
        >('hb_buffer_set_direction'),
    hbBufferSetScript: lib
        .lookupFunction<
          Void Function(Pointer<HbBuffer>, Uint32),
          void Function(Pointer<HbBuffer>, int)
        >('hb_buffer_set_script'),
    hbBufferSetLanguage: lib
        .lookupFunction<
          Void Function(Pointer<HbBuffer>, Pointer<Void>),
          void Function(Pointer<HbBuffer>, Pointer<Void>)
        >('hb_buffer_set_language'),
    hbBufferGuessSegmentProperties: lib
        .lookupFunction<
          Void Function(Pointer<HbBuffer>),
          void Function(Pointer<HbBuffer>)
        >('hb_buffer_guess_segment_properties'),
    hbLanguageFromString: lib
        .lookupFunction<
          Pointer<Void> Function(Pointer<Utf8>, Int32),
          Pointer<Void> Function(Pointer<Utf8>, int)
        >('hb_language_from_string'),
    hbScriptFromString: lib
        .lookupFunction<
          Uint32 Function(Pointer<Utf8>, Int32),
          int Function(Pointer<Utf8>, int)
        >('hb_script_from_string'),
    hbShape: lib
        .lookupFunction<
          Void Function(
            Pointer<HbFont>,
            Pointer<HbBuffer>,
            Pointer<HbFeature>,
            Uint32,
          ),
          void Function(
            Pointer<HbFont>,
            Pointer<HbBuffer>,
            Pointer<HbFeature>,
            int,
          )
        >('hb_shape'),
    hbBufferGetLength: lib
        .lookupFunction<
          Uint32 Function(Pointer<HbBuffer>),
          int Function(Pointer<HbBuffer>)
        >('hb_buffer_get_length'),
    hbBufferGetGlyphInfos: lib
        .lookupFunction<
          Pointer<HbGlyphInfo> Function(Pointer<HbBuffer>, Pointer<Uint32>),
          Pointer<HbGlyphInfo> Function(Pointer<HbBuffer>, Pointer<Uint32>)
        >('hb_buffer_get_glyph_infos'),
    hbBufferGetGlyphPositions: lib
        .lookupFunction<
          Pointer<HbGlyphPosition> Function(Pointer<HbBuffer>, Pointer<Uint32>),
          Pointer<HbGlyphPosition> Function(Pointer<HbBuffer>, Pointer<Uint32>)
        >('hb_buffer_get_glyph_positions'),
    hbFeatureFromString: lib
        .lookupFunction<
          Int32 Function(Pointer<Utf8>, Int32, Pointer<HbFeature>),
          int Function(Pointer<Utf8>, int, Pointer<HbFeature>)
        >('hb_feature_from_string'),
    hbFontDestroyPtr: lib
        .lookup<NativeFunction<Void Function(Pointer<HbFont>)>>(
          'hb_font_destroy',
        )
        .cast(),
    hbFaceDestroyPtr: lib
        .lookup<NativeFunction<Void Function(Pointer<HbFace>)>>(
          'hb_face_destroy',
        )
        .cast(),
  );

  /// Last-resort open of the hooks-built dylib next to the package cwd.
  /// Prefer fixing native-assets wiring over relying on this.
  static DynamicLibrary? _openBundledDylib() {
    final names = <String>[
      if (Platform.isMacOS || Platform.isIOS) 'libgputext_harfbuzz.dylib',
      if (Platform.isLinux || Platform.isAndroid) 'libgputext_harfbuzz.so',
      if (Platform.isWindows) 'gputext_harfbuzz.dll',
    ];
    final os = Platform.operatingSystem;
    final dirs = <String>[
      'build/native_assets/$os',
      // When tests run from the workspace root.
      'packages/gputext/build/native_assets/$os',
    ];
    for (final dir in dirs) {
      for (final name in names) {
        final path = '$dir${Platform.pathSeparator}$name';
        if (File(path).existsSync()) {
          try {
            return DynamicLibrary.open(path);
          } catch (_) {}
        }
      }
    }
    return null;
  }
}

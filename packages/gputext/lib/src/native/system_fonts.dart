// FFI wrapper over the native system-font resolver (`system_fonts.c`).
//
// Prefers the `@Native` code asset registered by the package build hook; falls
// back to DynamicLibrary.open of the bundled library only when the native-assets
// map is missing (tooling bug). This mirrors `harfbuzz_bindings.dart`.
//
// The resolver returns an in-memory TrueType (`glyf`) sfnt for a family name, or
// null when unavailable on this platform (Windows/Linux), the font is CFF-only,
// or the OS refuses the font's tables (some iOS system fonts). Callers treat
// null as "keep the fallback", never an error.

// ignore_for_file: non_constant_identifier_names

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

const _assetId = 'package:gputext/src/native/system_fonts_dylib.dart';

@Native<
  Pointer<Uint8> Function(Pointer<Utf8>, Int32, Int32, Pointer<Uint32>)
>(assetId: _assetId, symbol: 'gputext_system_font_data')
external Pointer<Uint8> _gputext_system_font_data(
  Pointer<Utf8> family,
  int weight,
  int italic,
  Pointer<Uint32> outLen,
);

@Native<Pointer<Uint8> Function(Int32, Int32, Pointer<Uint32>)>(
  assetId: _assetId,
  symbol: 'gputext_system_default_font_data',
)
external Pointer<Uint8> _gputext_system_default_font_data(
  int weight,
  int italic,
  Pointer<Uint32> outLen,
);

@Native<Void Function(Pointer<Uint8>)>(
  assetId: _assetId,
  symbol: 'gputext_system_font_free',
  isLeaf: true,
)
external void _gputext_system_font_free(Pointer<Uint8> ptr);

typedef _FontDataFn =
    Pointer<Uint8> Function(Pointer<Utf8>, int, int, Pointer<Uint32>);
typedef _DefaultFontDataFn =
    Pointer<Uint8> Function(int, int, Pointer<Uint32>);
typedef _FreeFn = void Function(Pointer<Uint8>);

/// Loaded system-font resolver symbols (from `@Native` or DynamicLibrary.open).
class SystemFontProvider {
  SystemFontProvider._(
    this._fontDataFn,
    this._defaultFontDataFn,
    this._freeFn,
  );

  final _FontDataFn _fontDataFn;
  final _DefaultFontDataFn _defaultFontDataFn;
  final _FreeFn _freeFn;

  static SystemFontProvider? _cached;
  static bool _loadFailed = false;

  /// True when the last successful [tryLoad] used `@Native` / native assets.
  static bool loadedViaNative = false;

  /// Last failure detail from [tryLoad] (tests / diagnostics).
  static String? lastLoadError;

  /// Platforms with a real resolver backend. Elsewhere the native shim compiles
  /// to a NULL-returning stub, so requests always resolve to null.
  static bool get isSupportedPlatform =>
      Platform.isMacOS || Platform.isIOS || Platform.isAndroid;

  /// True when a system-font backend is present and loadable on this platform.
  static bool get available => isSupportedPlatform && tryLoad() != null;

  /// Resolve the resolver once. Returns null (and sets [lastLoadError]) when
  /// neither the code asset nor the bundled library can be loaded — the whole
  /// feature then degrades to "no system fonts", never a throw.
  static SystemFontProvider? tryLoad() {
    if (_cached != null) return _cached;
    if (_loadFailed) return null;
    // 1) @Native code-asset path. Probe with the trivial free(nullptr): it
    // resolves the trampoline without allocating or calling the OS.
    try {
      _gputext_system_font_free(nullptr);
      loadedViaNative = true;
      lastLoadError = null;
      return _cached = SystemFontProvider._(
        _gputext_system_font_data,
        _gputext_system_default_font_data,
        _gputext_system_font_free,
      );
    } catch (e) {
      lastLoadError = '@Native: $e';
    }
    // 2) Narrow fallback: process-local / packaged soname, then hooks output.
    final lib = _openBundledDylib();
    if (lib == null) {
      _loadFailed = true;
      lastLoadError =
          '${lastLoadError ?? 'no @Native'}; '
          'DynamicLibrary.open fallback also failed';
      return null;
    }
    try {
      loadedViaNative = false;
      lastLoadError = null;
      return _cached = SystemFontProvider._(
        lib
            .lookupFunction<
              Pointer<Uint8> Function(
                Pointer<Utf8>,
                Int32,
                Int32,
                Pointer<Uint32>,
              ),
              _FontDataFn
            >('gputext_system_font_data'),
        lib
            .lookupFunction<
              Pointer<Uint8> Function(Int32, Int32, Pointer<Uint32>),
              _DefaultFontDataFn
            >('gputext_system_default_font_data'),
        lib.lookupFunction<Void Function(Pointer<Uint8>), _FreeFn>(
          'gputext_system_font_free',
        ),
      );
    } catch (e) {
      _loadFailed = true;
      lastLoadError = 'symbol lookup: $e';
      return null;
    }
  }

  /// TrueType sfnt bytes for the OS font family [name] at [weight]/[italic], or
  /// null when the platform cannot supply a gputext-renderable face. The
  /// returned list is a Dart-owned copy; the native buffer is freed here.
  Uint8List? fontData(String name, {int weight = 400, bool italic = false}) {
    final famPtr = name.toNativeUtf8();
    final lenPtr = calloc<Uint32>();
    try {
      final ptr = _fontDataFn(famPtr, weight, italic ? 1 : 0, lenPtr);
      return _take(ptr, lenPtr.value);
    } finally {
      calloc.free(famPtr);
      calloc.free(lenPtr);
    }
  }

  /// TrueType sfnt bytes for the platform default UI font (San Francisco /
  /// Roboto) at [weight]/[italic], or null when unavailable.
  Uint8List? defaultFontData({int weight = 400, bool italic = false}) {
    final lenPtr = calloc<Uint32>();
    try {
      final ptr = _defaultFontDataFn(weight, italic ? 1 : 0, lenPtr);
      return _take(ptr, lenPtr.value);
    } finally {
      calloc.free(lenPtr);
    }
  }

  /// Copy [len] bytes out of the native buffer [ptr] into a Dart list and free
  /// the buffer. Null when the resolver returned nothing.
  Uint8List? _take(Pointer<Uint8> ptr, int len) {
    if (ptr == nullptr) return null;
    if (len == 0) {
      _freeFn(ptr);
      return null;
    }
    final bytes = Uint8List.fromList(ptr.asTypedList(len));
    _freeFn(ptr);
    return bytes;
  }

  /// Last-resort open of the hooks-built library.
  /// Prefer fixing native-assets / `@Native` wiring over relying on this.
  static DynamicLibrary? _openBundledDylib() {
    final names = <String>[
      if (Platform.isMacOS || Platform.isIOS)
        'gputext_system_fonts.framework/gputext_system_fonts',
      if (Platform.isMacOS || Platform.isIOS) 'libgputext_system_fonts.dylib',
      if (Platform.isLinux || Platform.isAndroid)
        'libgputext_system_fonts.so',
      if (Platform.isWindows) 'gputext_system_fonts.dll',
    ];
    final openErrors = <String>[];
    for (final name in names) {
      try {
        return DynamicLibrary.open(name);
      } catch (e) {
        openErrors.add('$name: $e');
      }
    }
    if (openErrors.isNotEmpty) {
      lastLoadError =
          '${lastLoadError ?? ''}; open: ${openErrors.join('; ')}';
    }
    final os = Platform.operatingSystem;
    final dirs = <String>[
      'build/native_assets/$os',
      'packages/gputext/build/native_assets/$os',
    ];
    for (final dir in dirs) {
      for (final name in names) {
        if (name.contains('.framework/')) continue;
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

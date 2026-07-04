// Process-wide windfoil engine: GPU pipeline + font registry + the shared
// incremental glyph atlas, with ChangeNotifier readiness signaling.
//
// Two readiness gates (widgets listen and mark themselves dirty):
//   fontsReady — metrics available, layout can run (markNeedsLayout on flip)
//   gpuReady   — pipeline built, paint can render (markNeedsPaint on flip)
//
// `await Windfoil.initialize(...)` in main() is the no-FOUT path; otherwise
// the first attached widget lazily kicks ensureInitialized() and repaints
// when ready. Platforms without Impeller/flutter_gpu set isSupported=false:
// widgets still lay out (fonts are pure Dart) but paint nothing.

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_gpu/gpu.dart' as gpu;

import '../atlas.dart';
import '../font.dart';
import 'pipeline.dart';
import 'shared_atlas.dart';

const _defaultFontAsset = 'assets/Lato-Regular.ttf';
const _defaultFontFamily = 'Lato';

/// Public facade.
abstract final class Windfoil {
  static WindfoilEngine get instance => WindfoilEngine._instance;

  /// Load fonts and build the GPU pipeline up front (no first-frame flash).
  static Future<void> initialize({
    Map<String, String> fontAssets = const {},
    String? defaultFamily,
  }) =>
      instance._initializeWith(fontAssets, defaultFamily);

  /// False when flutter_gpu/Impeller is unavailable; windfoil widgets lay
  /// out but paint blank, so apps can fall back to stock RichText.
  static bool get isSupported => !instance.unsupported;
}

class WindfoilEngine extends ChangeNotifier {
  WindfoilEngine._();

  static final WindfoilEngine _instance = WindfoilEngine._();

  Future<void>? _initFuture;
  WindfoilPipeline? _pipeline;
  final atlas = SharedGlyphAtlas();
  final _fonts = <String, WindfoilFont>{};
  String? _defaultFamily;
  var _unsupported = false;

  AtlasTextures? _textures;
  var _texturesGeneration = -1;

  bool get fontsReady => _fonts.isNotEmpty;
  bool get gpuReady => _pipeline != null;
  bool get unsupported => _unsupported;
  WindfoilPipeline get pipeline => _pipeline!;

  /// Idempotent lazy init: registers the bundled default font if none were
  /// registered, then builds the pipeline. Never throws — flips
  /// [unsupported] instead so widgets degrade to blank.
  Future<void> ensureInitialized() => _initFuture ??= _init();

  Future<void> _initializeWith(
    Map<String, String> fontAssets,
    String? defaultFamily,
  ) async {
    for (final e in fontAssets.entries) {
      await loadFontAsset(e.key, e.value);
    }
    if (defaultFamily != null) _defaultFamily = defaultFamily;
    await ensureInitialized();
  }

  Future<void> _init() async {
    try {
      if (_fonts.isEmpty) {
        await loadFontAsset(_defaultFontFamily, _defaultFontAsset);
      }
    } catch (e) {
      debugPrint('windfoil: default font load failed: $e');
    }
    try {
      _pipeline = await WindfoilPipeline.create();
    } catch (e) {
      debugPrint('windfoil: GPU init failed, widgets will paint blank: $e');
      _unsupported = true;
    }
    notifyListeners();
  }

  /// Load and register a TTF from the asset bundle (bare key first, then
  /// packages/windfoil_flutter/-prefixed for package consumers).
  Future<WindfoilFont> loadFontAsset(String family, String assetKey) async {
    ByteData data;
    try {
      data = await rootBundle.load(assetKey);
    } catch (_) {
      data = await rootBundle.load('packages/windfoil_flutter/$assetKey');
    }
    final font = WindfoilFont.parse(data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    ));
    registerFont(family, font);
    return font;
  }

  void registerFont(String family, WindfoilFont font) {
    _fonts[family] = font;
    _defaultFamily ??= family;
    notifyListeners();
  }

  /// Family lookup with default-family fallback; null while no fonts loaded.
  WindfoilFont? resolveFont(String? family) {
    if (family != null) {
      final f = _fonts[family];
      if (f != null) return f;
    }
    final def = _defaultFamily;
    return def != null ? _fonts[def] : null;
  }

  /// Current curve/row textures, re-uploaded when the atlas has grown.
  /// Null until the atlas has any glyph data.
  AtlasTextures? prepareTextures() {
    if (atlas.isEmpty) return null;
    if (_texturesGeneration != atlas.generation) {
      _textures = uploadAtlasTextures(
        gpu.gpuContext,
        atlas.curvesData(),
        atlas.rowsData(),
      );
      _texturesGeneration = atlas.generation;
    }
    return _textures;
  }

  /// Test/hot-restart hook: drop GPU state so the next ensureInitialized
  /// rebuilds it (fonts and atlas are kept — they're pure Dart).
  @visibleForTesting
  void debugResetGpu() {
    _initFuture = null;
    _pipeline = null;
    _textures = null;
    _texturesGeneration = -1;
    _unsupported = false;
  }
}

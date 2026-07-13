import 'package:code_assets/code_assets.dart';
import 'package:flutter_gpu_shaders/build.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    await buildShaderBundleJson(
      buildInput: input,
      buildOutput: output,
      manifestFileName: 'gputext.shaderbundle.json',
      glesLanguageVersion: 300,
      assetMode: ShaderBundleAssetMode.dataAssetsIfAvailable,
    );

    if (!input.config.buildCodeAssets) return;

    // HarfBuzz amalgamation from the third_party/harfbuzz git submodule
    // (OT-only, no FreeType/CoreText/DirectWrite).
    // assetName must match the library URI used by @Native(assetId: ...).
    //
    // C++ runtime linking is per-OS so the shared library loads without a
    // separately packaged C++ runtime next to the Flutter app:
    // - Android: c++_static (Flutter does not ship libc++_shared.so)
    // - Linux: -static-libstdc++ embeds libstdc++ (avoids host .so skew)
    // - iOS/macOS: system libc++ is always present
    // - Windows: cppLinkStdLib is ignored; MSVC /MD matches Flutter
    final os = input.config.code.targetOS;
    final hb = CBuilder.library(
      name: 'gputext_harfbuzz',
      assetName: 'src/native/harfbuzz_dylib.dart',
      sources: ['third_party/harfbuzz/src/harfbuzz.cc'],
      includes: ['third_party/harfbuzz/src'],
      language: Language.cpp,
      std: 'c++17',
      flags: _hbFlags(os),
      // HarfBuzz uses sincosf/atanf/hypotf/tanf. Android's app linker
      // namespace does not resolve those unless libm is a DT_NEEDED.
      libraries: _hbLibraries(os),
      defines: const {
        'HB_NO_MT': '1',
        'HB_NO_PRAGMA_GCC_DIAGNOSTIC': '1',
      },
      cppLinkStdLib: _hbCppLinkStdLib(os),
    );
    await hb.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = Level.WARNING
        // ignore: avoid_print
        ..onRecord.listen((r) => print(r.message)),
    );
  });
}

/// Compiler/linker flags for the HarfBuzz amalgamation.
List<String> _hbFlags(OS os) => switch (os) {
  OS.windows => const [
    // MSVC / clang-cl: no exceptions or RTTI (matches HB_NO_* build).
    '/EHs-',
    '/GR-',
  ],
  OS.linux => const [
    '-fno-exceptions',
    '-fno-rtti',
    // Embed libstdc++/libgcc so the .so does not depend on the host's
    // shared C++ runtime (AppImage / older distros).
    '-static-libstdc++',
    '-static-libgcc',
  ],
  // Android, iOS, macOS, Fuchsia — clang.
  _ => const ['-fno-exceptions', '-fno-rtti'],
};

/// C++ standard library selection for [CBuilder.cppLinkStdLib].
///
/// Returns null on Windows (ignored by native_toolchain_c) and unknown OSes.
String? _hbCppLinkStdLib(OS os) => switch (os) {
  OS.android => 'c++_static',
  OS.iOS || OS.macOS || OS.fuchsia => 'c++',
  OS.linux => 'stdc++',
  OS.windows => null,
  _ => null,
};

/// Extra system libraries for the HarfBuzz amalgamation.
///
/// Windows links the CRT math symbols implicitly; Unix-likes need `-lm`.
List<String> _hbLibraries(OS os) => switch (os) {
  OS.windows => const [],
  _ => const ['m'],
};

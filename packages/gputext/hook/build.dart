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

    // HarfBuzz amalgamation from the third_party/harfbuzz git submodule
    // (OT-only, no FreeType/CoreText).
    // assetName must match the library URI used by @Native(assetId: ...).
    final hb = CBuilder.library(
      name: 'gputext_harfbuzz',
      assetName: 'src/native/harfbuzz_dylib.dart',
      sources: ['third_party/harfbuzz/src/harfbuzz.cc'],
      includes: ['third_party/harfbuzz/src'],
      language: Language.cpp,
      std: 'c++17',
      flags: const ['-fno-exceptions', '-fno-rtti'],
      defines: const {
        'HB_NO_MT': '1',
        'HB_NO_PRAGMA_GCC_DIAGNOSTIC': '1',
      },
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

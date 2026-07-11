// GPU initialization in the test environment.
//
// flutter_tester boots without Impeller by default, so these tests only
// exercise the real GPU path when run as:
//
//   flutter test --enable-impeller --enable-flutter-gpu
//
// (the melos `test` script passes both). Without the flags they skip, and
// the engine's degrade-to-blank contract is asserted instead.

import 'package:flutter_gpu/gpu.dart' as gpu;
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';

bool get _gpuAvailable {
  try {
    gpu.gpuContext;
    return true;
  } catch (_) {
    return false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('pipeline initializes from the hook-built shader bundle', () async {
    await GPUText.instance.ensureInitialized();
    if (!_gpuAvailable) {
      // No Impeller: init must not throw, and widgets degrade to blank.
      expect(GPUText.isSupported, isFalse);
      markTestSkipped(
        'flutter_gpu unavailable; run with '
        '--enable-impeller --enable-flutter-gpu to cover GPU init',
      );
      return;
    }
    expect(GPUText.isSupported, isTrue);
    expect(GPUText.instance.gpuReady, isTrue);
  });
}

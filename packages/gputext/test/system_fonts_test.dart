import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/gputext.dart';

// System-font resolution is platform-native (CoreText / Android matcher), so the
// behavioral assertions run only where a backend is actually available — CI on
// Linux (and the Windows stub) exercise the null-on-unavailable contract instead.
void main() {
  final engine = GPUText.instance;

  tearDown(() {
    engine
      ..unregisterFont('SysDefaultTest')
      ..unregisterFont('SysNamedTest');
  });

  test('SystemFontProvider availability reflects the platform', () {
    // Never throws; supported only on macOS/iOS/Android with the shim loaded.
    expect(SystemFontProvider.available, isA<bool>());
    if (SystemFontProvider.available) {
      expect(SystemFontProvider.isSupportedPlatform, isTrue);
    }
  });

  test(
    'loadDefaultSystemFont resolves the platform UI font when available',
    () async {
      final font = await engine.loadDefaultSystemFont(family: 'SysDefaultTest');
      if (!SystemFontProvider.available) {
        expect(font, isNull);
        return;
      }
      expect(
        font,
        isNotNull,
        reason: 'default UI font should resolve on ${Platform.operatingSystem}',
      );
      expect(font!.hasGlyph('A'), isTrue);
      expect(font.unitsPerEm, greaterThan(0));
      expect(engine.resolveFont('SysDefaultTest'), isNotNull);
    },
  );

  test(
    'loadSystemFont resolves a named installed family when available',
    () async {
      // Menlo ships with every macOS and is TrueType (glyf); on other platforms
      // this simply exercises the null / best-effort path.
      final font = await engine.loadSystemFont(
        'SysNamedTest',
        systemName: 'Menlo',
      );
      if (!SystemFontProvider.available) {
        expect(font, isNull);
        return;
      }
      if (font == null) return; // named family absent on this OS — best-effort
      expect(font.hasGlyph('A'), isTrue);
      expect(engine.resolveFont('SysNamedTest'), isNotNull);
    },
  );

  test('GPUFont.parse unwraps a .ttc collection wrapper', () {
    final ttc = File('/System/Library/Fonts/Helvetica.ttc');
    if (!Platform.isMacOS || !ttc.existsSync()) return;
    try {
      final font = GPUFont.parse(ttc.readAsBytesSync());
      expect(font.unitsPerEm, greaterThan(0));
    } on FormatException catch (e) {
      // Rejecting a CFF face is fine; the 'ttcf' wrapper (tag 0x74746366 =
      // 1953784678) must not be what tripped the parser.
      expect(e.message, isNot(contains('1953784678')));
    }
  });
}

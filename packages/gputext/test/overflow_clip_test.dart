import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';

/// RenderGPUParagraph clips exactly when RenderParagraph does: on LINE BOX
/// overflow, never on glyph ink overflow.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final engine = GPUText.instance;

  setUpAll(() {
    engine.registerFont(
      'Lato',
      GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync()),
    );
  });

  const style = TextStyle(
    inherit: false,
    fontFamily: 'Lato',
    fontSize: 18,
    color: Color(0xFFFF0000),
  );

  Future<void> pump(
    WidgetTester tester,
    Widget child, {
    double? width,
    double? height,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Center(child: SizedBox(width: width, height: height, child: child)),
    ),
  );

  testWidgets('ink escaping its line box does not clip', (tester) async {
    // Lato's 'j' has a negative left side bearing: its ink starts left of the
    // pen origin, outside the line box. The box here is self-sized, so it IS
    // the line box — testing ink would push a clip that shaves that ink off.
    await pump(
      tester,
      const GPURichText(
        text: TextSpan(text: 'jjj', style: style),
        overflow: TextOverflow.ellipsis,
      ),
    );
    expect(tester.getSize(find.byType(GPURichText)).height, closeTo(21.6, 0.1));
    expect(find.byType(GPURichText), isNot(paints..clipRect()));
  });

  testWidgets('a line box taller than the box clips', (tester) async {
    // 18px Lato needs 21.6px; give it 20 and the descenders must be cut.
    await pump(
      tester,
      const GPURichText(
        text: TextSpan(text: 'gputext', style: style),
        overflow: TextOverflow.ellipsis,
      ),
      height: 20,
    );
    expect(find.byType(GPURichText), paints..clipRect());
  });

  testWidgets('a line advancing past the box clips', (tester) async {
    await pump(
      tester,
      const GPURichText(
        text: TextSpan(text: 'a very long line that cannot fit', style: style),
        softWrap: false,
        overflow: TextOverflow.clip,
      ),
      width: 60,
    );
    expect(find.byType(GPURichText), paints..clipRect());
  });

  testWidgets('maxLines truncation clips', (tester) async {
    await pump(
      tester,
      const GPURichText(
        text: TextSpan(text: 'one two three four five six', style: style),
        maxLines: 1,
      ),
      width: 60,
    );
    expect(find.byType(GPURichText), paints..clipRect());
  });

  testWidgets('TextOverflow.visible never clips', (tester) async {
    await pump(
      tester,
      const GPURichText(
        text: TextSpan(text: 'gputext', style: style),
        overflow: TextOverflow.visible,
      ),
      height: 20,
    );
    expect(find.byType(GPURichText), isNot(paints..clipRect()));
  });
}

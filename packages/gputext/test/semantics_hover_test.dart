// Semantics tree (per-span nodes, link actions) and mouse hover
// (TextSpan.mouseCursor / onEnter / onExit via span hit-testing).

import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:gputext/src/engine/engine.dart';
import 'package:gputext/src/font.dart';
import 'package:gputext/gputext.dart' show GPURichText;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    GPUText.instance.registerFont(
      'Lato',
      GPUFont.parse(File('assets/Lato-Regular.ttf').readAsBytesSync()),
    );
  });

  Widget host(InlineSpan span) => Directionality(
    textDirection: TextDirection.ltr,
    child: Center(
      child: GPURichText(text: TextSpan(children: [span])),
    ),
  );

  const style = TextStyle(fontFamily: 'Lato', fontSize: 16);

  // Nodes assembled by the render object aren't element-attached, so
  // find.bySemanticsLabel can't see them (true for RichText links too):
  // walk the semantics tree instead.
  SemanticsNode? findByLabel(SemanticsNode root, String label) {
    if (root.label == label) return root;
    SemanticsNode? hit;
    root.visitChildren((child) {
      hit ??= findByLabel(child, label);
      return hit == null;
    });
    return hit;
  }

  group('semantics', () {
    testWidgets('plain paragraphs expose one label', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        host(const TextSpan(text: 'hello world', style: style)),
      );
      expect(find.bySemanticsLabel(RegExp('hello world')), findsOneWidget);
      handle.dispose();
    });

    testWidgets('link spans become individually tappable link nodes', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      var taps = 0;
      final rec = TapGestureRecognizer()..onTap = () => taps++;
      addTearDown(rec.dispose);
      await tester.pumpWidget(
        host(
          TextSpan(
            style: style,
            children: [
              const TextSpan(text: 'Read the '),
              TextSpan(text: 'docs', recognizer: rec),
              const TextSpan(text: ' now'),
            ],
          ),
        ),
      );

      final para = tester.getSemantics(find.byType(GPURichText));
      expect(
        para,
        matchesSemantics(
          children: [
            matchesSemantics(label: 'Read the '),
            matchesSemantics(
              label: 'docs',
              isLink: true,
              hasTapAction: true,
              textDirection: TextDirection.ltr,
            ),
            matchesSemantics(label: ' now'),
          ],
        ),
      );

      final docs = findByLabel(para, 'docs')!;
      docs.owner!.performAction(docs.id, SemanticsAction.tap);
      expect(taps, 1);
      handle.dispose();
    });

    testWidgets('semanticsLabel replaces the span text', (tester) async {
      final handle = tester.ensureSemantics();
      final rec = TapGestureRecognizer()..onTap = () {};
      addTearDown(rec.dispose);
      await tester.pumpWidget(
        host(
          TextSpan(
            style: style,
            children: [
              TextSpan(
                text: 'here',
                semanticsLabel: 'link to documentation',
                recognizer: rec,
              ),
              const TextSpan(text: ' and more'),
            ],
          ),
        ),
      );
      final para = tester.getSemantics(find.byType(GPURichText));
      expect(findByLabel(para, 'link to documentation'), isNotNull);
      expect(findByLabel(para, 'here'), isNull);
      handle.dispose();
    });

    testWidgets('WidgetSpan semantics survive explicit-child mode', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final rec = TapGestureRecognizer()..onTap = () {};
      addTearDown(rec.dispose);
      await tester.pumpWidget(
        host(
          TextSpan(
            style: style,
            children: [
              TextSpan(text: 'tap', recognizer: rec),
              const TextSpan(text: ' next to '),
              const WidgetSpan(child: Text('chip', style: style)),
            ],
          ),
        ),
      );
      final para = tester.getSemantics(find.byType(GPURichText));
      expect(findByLabel(para, 'chip'), isNotNull);
      expect(findByLabel(para, 'tap'), isNotNull);
      handle.dispose();
    });
  });

  group('hover and dispatch', () {
    testWidgets('link spans show the click cursor and fire enter/exit', (
      tester,
    ) async {
      var enters = 0;
      var exits = 0;
      final rec = TapGestureRecognizer()..onTap = () {};
      addTearDown(rec.dispose);
      await tester.pumpWidget(
        host(
          TextSpan(
            text: 'hover me',
            style: style,
            recognizer: rec, // default mouseCursor becomes click
            onEnter: (_) => enters++,
            onExit: (_) => exits++,
          ),
        ),
      );

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 1,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      expect(enters, 0);

      await gesture.moveTo(tester.getCenter(find.byType(GPURichText)));
      await tester.pump();
      expect(enters, 1);
      expect(exits, 0);
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.click,
      );

      await gesture.moveTo(Offset.zero);
      await tester.pump();
      expect(exits, 1);
    });

    testWidgets('hover-only spans (no recognizer) get hit boxes too', (
      tester,
    ) async {
      var enters = 0;
      await tester.pumpWidget(
        host(
          TextSpan(
            text: 'helpful',
            style: style,
            mouseCursor: SystemMouseCursors.help,
            onEnter: (_) => enters++,
          ),
        ),
      );

      final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
        pointer: 1,
      );
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      await gesture.moveTo(tester.getCenter(find.byType(GPURichText)));
      await tester.pump();
      expect(enters, 1);
      expect(
        RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1),
        SystemMouseCursors.help,
      );
    });

    testWidgets('taps still dispatch to the recognizer', (tester) async {
      var taps = 0;
      final rec = TapGestureRecognizer()..onTap = () => taps++;
      addTearDown(rec.dispose);
      await tester.pumpWidget(
        host(
          TextSpan(
            style: style,
            children: [
              const TextSpan(text: 'before '),
              TextSpan(text: 'tap me', recognizer: rec),
            ],
          ),
        ),
      );
      // Tap the trailing half of the paragraph, where the link run sits.
      final rect = tester.getRect(find.byType(GPURichText));
      await tester.tapAt(
        Offset(rect.right - rect.width * 0.15, rect.center.dy),
      );
      expect(taps, 1);

      // A tap on the plain leading span must NOT trigger the link.
      await tester.tapAt(Offset(rect.left + 5, rect.center.dy));
      expect(taps, 1);
    });
  });
}

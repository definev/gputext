import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gputext/gputext.dart';
import 'package:gputext_example/justification_demo.dart';
import 'package:gputext_example/pretext_demo.dart';
import 'package:gputext_example/rtl_demo.dart';
import 'package:gputext_example/widget_demo.dart';
import 'package:leak_tracker_flutter_testing/leak_tracker_flutter_testing.dart';

void main() {
  setUpAll(() {
    final bytes = File('assets/Lato-Regular.ttf').readAsBytesSync();
    GPUText.instance.registerFont('Lato', GPUFont.parse(bytes));
  });

  Future<void> mountAndPop(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context)
                        .push(MaterialPageRoute<void>(builder: (_) => page));
                  },
                  child: const Text('open'),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    Navigator.of(tester.element(find.byType(Scaffold).last)).pop();
    await tester.pumpAndSettle();
  }

  testWidgets('WidgetDemoPage mount/unmount is leak-free', (tester) async {
    await mountAndPop(tester, const WidgetDemoPage());
  }, experimentalLeakTesting: LeakTesting.settings);

  testWidgets('RtlDemoPage mount/unmount is leak-free', (tester) async {
    await mountAndPop(tester, const RtlDemoPage());
  }, experimentalLeakTesting: LeakTesting.settings);

  testWidgets('PretextDemoPage mount/unmount is leak-free', (tester) async {
    await mountAndPop(tester, const PretextDemoPage());
  }, experimentalLeakTesting: LeakTesting.settings);

  testWidgets('JustificationDemoPage mount/unmount is leak-free', (
    tester,
  ) async {
    await mountAndPop(tester, const JustificationDemoPage());
  }, experimentalLeakTesting: LeakTesting.settings);

  testWidgets('GPURichText create/dispose cycle is leak-free', (tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: GPURichText(
                text: TextSpan(
                  text: 'leak probe $i — the quick brown fox',
                  style: const TextStyle(fontFamily: 'Lato', fontSize: 18),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }
  }, experimentalLeakTesting: LeakTesting.settings);
}

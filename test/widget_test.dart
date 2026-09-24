// Widget-level tests for pieces that don't need Firebase or a real BLE link.
// (The full MyApp is not pumped: it requires Firebase.initializeApp.)

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/home_tab.dart';
import 'package:smarty_app/screens/user_context_page.dart';

void main() {
  group('Utf8ByteLimitFormatter in a TextField', () {
    Future<TextEditingController> pumpField(WidgetTester tester) async {
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              inputFormatters: [Utf8ByteLimitFormatter(10)],
            ),
          ),
        ),
      );
      return controller;
    }

    testWidgets('accepts text within the byte budget', (tester) async {
      final controller = await pumpField(tester);
      await tester.enterText(find.byType(TextField), 'abcde'); // 5 bytes
      expect(controller.text, 'abcde');
    });

    testWidgets('rejects an edit that would exceed the byte budget', (
      tester,
    ) async {
      final controller = await pumpField(tester);
      await tester.enterText(find.byType(TextField), 'ąęśćż'); // 10 bytes
      expect(controller.text, 'ąęśćż');
      // 11 bytes: rejected, previous value kept.
      await tester.enterText(find.byType(TextField), 'ąęśćża');
      expect(controller.text, 'ąęśćż');
    });
  });

  group('SetupSuccessView', () {
    Finder confetti() => find.byWidgetPredicate(
          (w) => w is CustomPaint && w.painter is ConfettiPainter,
        );

    Future<void> pump(WidgetTester tester, double progress,
        {VoidCallback? onContinue}) {
      return tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SetupSuccessView(
              animation: AlwaysStoppedAnimation<double>(progress),
              onContinue: onContinue ?? () {},
            ),
          ),
        ),
      );
    }

    testWidgets('mid-burst: lays out without errors and paints confetti', (
      tester,
    ) async {
      // Regression: CustomPaint(size: Size.infinite) inside the Column threw
      // an unbounded-height assertion.
      await pump(tester, 0.5);
      expect(tester.takeException(), isNull);
      expect(find.text('Connected!'), findsOneWidget);
      expect(confetti(), findsOneWidget);
    });

    testWidgets('no confetti before the burst or after it ends', (
      tester,
    ) async {
      await pump(tester, 0);
      expect(confetti(), findsNothing);
      await pump(tester, 1);
      expect(confetti(), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('Continue works through the confetti overlay', (
      tester,
    ) async {
      var tapped = 0;
      await pump(tester, 0.5, onContinue: () => tapped++);
      await tester.tap(find.text('Continue'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tapped, 1);
    });
  });

  test('ConfettiPainter repaints only when progress changes', () {
    final a = ConfettiPainter(progress: 0.2);
    expect(a.shouldRepaint(ConfettiPainter(progress: 0.2)), isFalse);
    expect(a.shouldRepaint(ConfettiPainter(progress: 0.3)), isTrue);
  });
}

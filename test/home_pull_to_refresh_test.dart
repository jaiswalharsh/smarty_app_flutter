// Home's pull-to-refresh must work from anywhere on the screen — including
// the empty space below short content — not only on the toy card.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/home_tab.dart';
import 'package:smarty_app/services/ble_manager.dart';

void main() {
  group('PullToRefreshArea', () {
    Future<List<int>> pumpShort(WidgetTester tester) async {
      final calls = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PullToRefreshArea(
              onRefresh: () async => calls.add(1),
              padding: const EdgeInsets.all(20),
              // Short content: one small card at the top, lots of empty
              // space below it.
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [SizedBox(height: 60, child: Text('Smarty'))],
              ),
            ),
          ),
        ),
      );
      return calls;
    }

    testWidgets('a pull starting in the empty space at the bottom refreshes',
        (tester) async {
      final calls = await pumpShort(tester);
      final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      // Well below the content (which ends at y = 80).
      final Offset start = Offset(screen.width / 2, screen.height - 40);
      expect(start.dy, greaterThan(tester.getBottomLeft(find.text('Smarty')).dy + 100));

      await tester.flingFrom(start, const Offset(0, 300), 1000);
      await tester.pump(); // start the refresh
      await tester.pump(const Duration(seconds: 1)); // finish the animation
      await tester.pump(const Duration(seconds: 1));

      expect(calls, [1]);
    });

    testWidgets('a pull in the side padding also refreshes', (tester) async {
      final calls = await pumpShort(tester);
      await tester.flingFrom(const Offset(5, 300), const Offset(0, 300), 1000);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 1));
      expect(calls, [1]);
    });

    testWidgets('short content still fills the screen, so Columns can center',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PullToRefreshArea(
              onRefresh: () async {},
              padding: const EdgeInsets.all(20),
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [Text('middle')],
              ),
            ),
          ),
        ),
      );
      final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
      expect(tester.getCenter(find.text('middle')).dy,
          moreOrLessEquals(screen.height / 2, epsilon: 1));
    });
  });

  testWidgets("Home's busy view: the pull area covers the whole screen",
      (tester) async {
    expect(BleManager().phase.value, ToyPhase.probing);
    await tester.pumpWidget(const MaterialApp(home: HomeTab()));

    final Size screen = tester.view.physicalSize / tester.view.devicePixelRatio;
    final Rect area = tester.getRect(find.byType(Scrollable));
    expect(area, Offset.zero & screen);
    // The toy card is still where it was (20 px in from the edges).
    expect(tester.getTopLeft(find.text('Looking for Smarty…')).dy,
        greaterThan(20));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

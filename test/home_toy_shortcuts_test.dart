// Home's Smarty shortcuts (moved from Settings): Wi-Fi and About your child
// under the toy card whenever a toy is saved, and "Forget this Smarty" behind
// the toy card's "⋯" button. Home runs against the real BleManager in its
// initial state, with the phase supplied by the test — nothing is connected.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smarty_app/home_tab.dart';
import 'package:smarty_app/providers/user_context_provider.dart';
import 'package:smarty_app/services/ble_manager.dart';
import 'package:smarty_app/utils/theme_provider.dart';
import 'package:smarty_app/widgets/forget_toy.dart';
import 'package:smarty_app/widgets/toy_shortcuts.dart';

void main() {
  group('homeShowsToyShortcuts', () {
    test('whenever a toy is saved — not before setup', () {
      for (final phase in ToyPhase.values) {
        expect(
          homeShowsToyShortcuts(phase),
          phase != ToyPhase.noToy,
          reason: phase.name,
        );
      }
    });
  });

  group('wifiShortcutDetail', () {
    test('the network name once Smarty is on Wi-Fi', () {
      expect(wifiShortcutDetail('HomeNet'), 'HomeNet');
    });

    test('plain words otherwise', () {
      expect(wifiShortcutDetail('Unknown'), 'Checking…');
      expect(wifiShortcutDetail(''), 'Checking…');
      expect(wifiShortcutDetail('NotConnected'), 'Checking…');
      expect(wifiShortcutDetail('Initializing'), 'Joining…');
      expect(wifiShortcutDetail('Reconnecting'), 'Joining…');
      expect(wifiShortcutDetail('Auth Failed'), 'Not connected');
      expect(wifiShortcutDetail('No credentials'), 'Not connected');
    });
  });

  group('Home', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<void> pumpHome(WidgetTester tester, ToyPhase phase) async {
      final toyPhase = ValueNotifier<ToyPhase>(phase);
      addTearDown(toyPhase.dispose);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider(create: (_) => ThemeProvider()),
            ChangeNotifierProvider(
              create:
                  (_) => UserContextProvider(
                    readFromToy: () async => null,
                    writeToToy: (_) async => false,
                    isToyConnected: () => false,
                  ),
            ),
          ],
          child: MaterialApp(home: HomeTab(toyPhase: toyPhase)),
        ),
      );
      await tester.pump();
    }

    // Dispose Home so no timers (busy hint, stall watch) are left pending.
    Future<void> unmount(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox.shrink());

    ToyShortcutRow row(WidgetTester tester, String label) => tester
        .widget<ToyShortcutRow>(find.widgetWithText(ToyShortcutRow, label));

    testWidgets('connected: Wi-Fi and About your child, both tappable', (
      tester,
    ) async {
      await pumpHome(tester, ToyPhase.connected);

      expect(find.byType(ToyShortcuts), findsOneWidget);
      expect(row(tester, 'Wi-Fi').onTap, isNotNull);
      expect(row(tester, 'About your child').onTap, isNotNull);
      // Smarty hasn't reported its Wi-Fi yet in this test.
      expect(find.text('Checking…'), findsOneWidget);
      expect(find.byTooltip(ToyMoreButton.tooltip), findsOneWidget);
      await unmount(tester);
    });

    for (final phase in [
      ToyPhase.notNearby,
      ToyPhase.probing,
      ToyPhase.connecting,
      ToyPhase.pairingBroken,
      ToyPhase.bluetoothOff,
      ToyPhase.needsPermission,
    ]) {
      testWidgets(
        '${phase.name}: both rows shown; Wi-Fi waits until Smarty is nearby',
        (tester) async {
          await pumpHome(tester, phase);

          expect(find.byType(ToyShortcuts), findsOneWidget);
          expect(row(tester, 'Wi-Fi').onTap, isNull);
          expect(find.text(wifiShortcutAwayDetail), findsOneWidget);
          expect(row(tester, 'About your child').onTap, isNotNull);
          expect(find.byTooltip(ToyMoreButton.tooltip), findsOneWidget);
          // Still inside the pull-to-refresh area.
          expect(
            find.descendant(
              of: find.byType(PullToRefreshArea),
              matching: find.byType(ToyShortcuts),
            ),
            findsOneWidget,
          );
          await unmount(tester);
        },
      );
    }

    testWidgets('no toy yet: only "Set up Smarty" — no rows, no ⋯', (
      tester,
    ) async {
      await pumpHome(tester, ToyPhase.noToy);

      expect(find.text('Set up Smarty'), findsOneWidget);
      expect(find.byType(ToyShortcuts), findsNothing);
      expect(find.text('About your child'), findsNothing);
      expect(find.byTooltip(ToyMoreButton.tooltip), findsNothing);
      await unmount(tester);
    });

    testWidgets('About your child opens the page (Smarty away: offline copy)', (
      tester,
    ) async {
      await pumpHome(tester, ToyPhase.notNearby);

      await tester.tap(find.text('About your child'));
      await tester.pumpAndSettle();

      expect(
        find.text('Tell Smarty what it should know about your child.'),
        findsOneWidget,
      );
      await unmount(tester);
    });

    testWidgets('⋯ → Forget this Smarty asks first; Cancel keeps it', (
      tester,
    ) async {
      await pumpHome(tester, ToyPhase.notNearby);
      expect(find.text('Forget this Smarty'), findsNothing); // not a big row

      await tester.tap(find.byTooltip(ToyMoreButton.tooltip));
      await tester.pumpAndSettle();
      expect(find.text('Forget this Smarty'), findsOneWidget);

      await tester.tap(find.text('Forget this Smarty'));
      await tester.pumpAndSettle();
      expect(find.text('Forget this Smarty?'), findsOneWidget);
      expect(find.text('Forget'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Forget this Smarty?'), findsNothing);
      expect(find.byType(ToyShortcuts), findsOneWidget); // still saved
      await unmount(tester);
    });
  });

  group('confirmAndForgetToy', () {
    Future<List<bool>> pumpAndOpen(
      WidgetTester tester, {
      required bool isIOS,
      required List<int> forgets,
    }) async {
      final results = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder:
                (context) => TextButton(
                  onPressed:
                      () async => results.add(
                        await confirmAndForgetToy(
                          context,
                          isIOS: isIOS,
                          forget: () async => forgets.add(1),
                        ),
                      ),
                  child: const Text('open'),
                ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return results;
    }

    testWidgets('Forget forgets Smarty on this phone', (tester) async {
      final forgets = <int>[];
      final results = await pumpAndOpen(tester, isIOS: false, forgets: forgets);
      expect(find.textContaining('Settings → Bluetooth'), findsNothing);

      await tester.tap(find.text('Forget'));
      await tester.pumpAndSettle();
      expect(forgets, [1]);
      expect(results, [true]);
    });

    testWidgets('Cancel does nothing', (tester) async {
      final forgets = <int>[];
      final results = await pumpAndOpen(tester, isIOS: false, forgets: forgets);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(forgets, isEmpty);
      expect(results, [false]);
    });

    testWidgets('iPhone: also says to forget it in Settings → Bluetooth', (
      tester,
    ) async {
      await pumpAndOpen(tester, isIOS: true, forgets: []);
      expect(
        find.text(
          'To set it up again later, also forget it in '
          'Settings → Bluetooth.',
        ),
        findsOneWidget,
      );
    });
  });
}

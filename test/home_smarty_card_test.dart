// Home's one Smarty card: whenever a toy is saved, Home is a single card —
// the toy's name and status, ONE Wi-Fi row, About your child, "⋯" → Forget
// this Smarty, and (inside the card) what to do next for the current state.
// Home runs against the real BleManager in its initial state, with the phase
// supplied by the test — nothing is connected; a test that needs a status
// from Smarty applies one with [BleManager.debugApplyStatus].
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smarty_app/home_tab.dart';
import 'package:smarty_app/providers/user_context_provider.dart';
import 'package:smarty_app/screens/devices/setup_steps.dart';
import 'package:smarty_app/services/ble_manager.dart';
import 'package:smarty_app/utils/theme_provider.dart';
import 'package:smarty_app/widgets/forget_toy.dart';
import 'package:smarty_app/widgets/smarty_card.dart';

void main() {
  group('wifiRowInfo', () {
    WifiRowInfo connected(String wifi, {bool stalled = false}) =>
        wifiRowInfo(connected: true, wifi: wifi, statusStalled: stalled);

    test('Smarty away: waits until it is nearby, nothing to tap', () {
      for (final wifi in ['HomeNet', 'Unknown', 'Auth Failed']) {
        final info = wifiRowInfo(connected: false, wifi: wifi);
        expect(info.detail, wifiRowAwayDetail);
        expect(info.action, WifiRowAction.none);
      }
    });

    test('the network name once Smarty is on Wi-Fi', () {
      final info = connected('HomeNet');
      expect(info.detail, 'HomeNet');
      expect(info.action, WifiRowAction.none);
      expect(info.isProblem, isFalse);
    });

    test('still waiting for the status: "Checking…"', () {
      for (final wifi in ['Unknown', '', 'NotConnected']) {
        expect(connected(wifi).detail, 'Checking…', reason: wifi);
        expect(connected(wifi).action, WifiRowAction.none, reason: wifi);
      }
    });

    test('the status never came: "Couldn\'t check" with a refresh', () {
      final info = connected('Unknown', stalled: true);
      expect(info.detail, "Couldn't check");
      expect(info.action, WifiRowAction.checkAgain);
    });

    test('joining: "Joining…" with a refresh', () {
      for (final wifi in ['Initializing', 'Reconnecting']) {
        expect(connected(wifi).detail, 'Joining…', reason: wifi);
        expect(connected(wifi).action, WifiRowAction.checkAgain, reason: wifi);
      }
    });

    test('not on Wi-Fi: just the state (the header says why), "Set up"', () {
      final cases = {
        'Auth Failed': 'Not connected',
        'Connection Failed': 'Not connected',
        'No credentials': 'Not set up yet',
        'Scan Failed': 'Not connected',
      };
      cases.forEach((wifi, detail) {
        final info = connected(wifi);
        expect(info.detail, detail, reason: wifi);
        expect(info.action, WifiRowAction.setUp, reason: wifi);
        expect(info.isProblem, isTrue, reason: wifi);
      });
    });
  });

  group('Home', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));
    // Status applied by a test must not leak into the next one.
    tearDown(() => BleManager().debugResetConnectionState());

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

    // Smarty reports a status (as a BLE notification would).
    Future<void> smartySays(WidgetTester tester, String json) async {
      await BleManager().debugApplyStatus(json);
      await tester.pump();
    }

    // Dispose Home so no timers (busy hint, stall watch) are left pending.
    Future<void> unmount(WidgetTester tester) =>
        tester.pumpWidget(const SizedBox.shrink());

    Finder inCard(Finder f) =>
        find.descendant(of: find.byType(SmartyCard), matching: f);

    SmartyCardRow row(WidgetTester tester, String label) =>
        tester.widget<SmartyCardRow>(find.widgetWithText(SmartyCardRow, label));

    // The one card with its header (name, ⋯) and both rows.
    void expectOneCard() {
      expect(find.byType(SmartyCard), findsOneWidget);
      expect(find.byType(Card), findsOneWidget); // no other cards on Home
      expect(inCard(find.text('Smarty')), findsOneWidget);
      expect(inCard(find.byTooltip(ToyMoreButton.tooltip)), findsOneWidget);
      expect(inCard(find.text('Wi-Fi')), findsOneWidget);
      expect(inCard(find.text('About your child')), findsOneWidget);
      // Everything is inside the pull-to-refresh area.
      expect(
        find.descendant(
          of: find.byType(PullToRefreshArea),
          matching: find.byType(SmartyCard),
        ),
        findsOneWidget,
      );
    }

    group('connected', () {
      testWidgets('one card, exactly one Wi-Fi line, one spinner', (
        tester,
      ) async {
        await pumpHome(tester, ToyPhase.connected);

        expectOneCard();
        // No separate Wi-Fi card any more: the word appears once on Home.
        expect(find.text('Wi-Fi'), findsOneWidget);
        expect(find.textContaining('Wi-Fi'), findsOneWidget);
        // Smarty hasn't reported its Wi-Fi yet in this test.
        expect(inCard(find.text('Checking on Smarty…')), findsOneWidget);
        expect(inCard(find.text('Checking…')), findsOneWidget);
        // One spinner, in the card's header.
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(inCard(find.byType(CircularProgressIndicator)), findsOneWidget);
        expect(row(tester, 'Wi-Fi').onTap, isNotNull);
        expect(row(tester, 'About your child').onTap, isNotNull);
        expect(find.text('Finish setup'), findsNothing);
        await unmount(tester);
      });

      testWidgets('on Wi-Fi: the network name, still one Wi-Fi line', (
        tester,
      ) async {
        await pumpHome(tester, ToyPhase.connected);
        await smartySays(tester, '{"wifi":"HomeNet"}');

        expectOneCard();
        expect(inCard(find.text('Ready to play')), findsOneWidget);
        expect(inCard(find.text('HomeNet')), findsOneWidget);
        expect(find.textContaining('Wi-Fi'), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(row(tester, 'Wi-Fi').onTap, isNotNull);
        expect(find.text('Finish setup'), findsNothing);
        await unmount(tester);
      });

      testWidgets('not linked yet: "Finish setup" inside the card', (
        tester,
      ) async {
        await pumpHome(tester, ToyPhase.connected);
        await smartySays(tester, '{"wifi":"HomeNet","registered":false}');

        expectOneCard();
        expect(inCard(find.text('Almost done — finish setup')), findsOneWidget);
        expect(inCard(find.text('HomeNet')), findsOneWidget);
        expect(find.text('Finish setup'), findsOneWidget);
        expect(inCard(find.text('Finish setup')), findsOneWidget);
        // Header, then the rows, then the button — all in the one card.
        final double header = tester.getTopLeft(find.text('Smarty')).dy;
        final double wifi = tester.getTopLeft(find.text('Wi-Fi')).dy;
        final double about =
            tester.getTopLeft(find.text('About your child')).dy;
        final double button = tester.getTopLeft(find.text('Finish setup')).dy;
        expect(header, lessThan(wifi));
        expect(wifi, lessThan(about));
        expect(about, lessThan(button));
        await unmount(tester);
      });

      testWidgets('not on Wi-Fi: why in the header, "Set up" on the row', (
        tester,
      ) async {
        await pumpHome(tester, ToyPhase.connected);
        await smartySays(tester, '{"wifi":"Auth Failed"}');

        expectOneCard();
        expect(find.text('Wi-Fi'), findsOneWidget);
        expect(inCard(find.text(wifiAuthFailedLine(null))), findsOneWidget);
        expect(inCard(find.text('Not connected')), findsOneWidget);
        // Said once, not repeated on the row.
        expect(find.textContaining('password'), findsOneWidget);
        expect(
          find.descendant(
            of: find.widgetWithText(SmartyCardRow, 'Wi-Fi'),
            matching: find.widgetWithText(TextButton, 'Set up'),
          ),
          findsOneWidget,
        );
        expect(row(tester, 'Wi-Fi').onTap, isNotNull);
        await unmount(tester);
      });

      testWidgets('joining: "Joining…" with a Check again button', (
        tester,
      ) async {
        await pumpHome(tester, ToyPhase.connected);
        await smartySays(tester, '{"wifi":"Initializing"}');

        expect(inCard(find.text('Smarty is joining Wi-Fi…')), findsOneWidget);
        expect(inCard(find.text('Joining…')), findsOneWidget);
        expect(
          find.descendant(
            of: find.widgetWithText(SmartyCardRow, 'Wi-Fi'),
            matching: find.byTooltip('Check again'),
          ),
          findsOneWidget,
        );
        await unmount(tester);
      });
    });

    // Each state: its status in the card's header and its actions inside
    // the card.
    final Map<ToyPhase, ({String status, List<String> inside})> states = {
      ToyPhase.notNearby: (
        status: 'Smarty is asleep or out of reach',
        inside: [
          "Turn it on — it'll connect by itself.",
          'Check again',
          'Set up a different Smarty',
        ],
      ),
      ToyPhase.probing: (status: 'Looking for Smarty…', inside: []),
      ToyPhase.connecting: (status: 'Connecting to Smarty…', inside: []),
      ToyPhase.pairingBroken: (
        status: pairingBrokenHeading,
        inside: [...pairingBrokenStepList(isIOS: false), 'Try again'],
      ),
      // Tests run as Android: Platform.isIOS is false here (the iOS copy is
      // covered in setup_steps_test.dart).
      ToyPhase.bluetoothOff: (
        status: 'Bluetooth is off on this phone',
        inside: ['Turn on Bluetooth on your phone to reach Smarty.', 'Turn on'],
      ),
      ToyPhase.needsPermission: (
        status: 'Bluetooth permission needed',
        inside: [
          'Allow Bluetooth so the app can talk to Smarty',
          'In Settings, turn on Bluetooth for this app, then come back.',
          'Open Settings',
        ],
      ),
    };

    states.forEach((phase, expected) {
      testWidgets(
        '${phase.name}: the same card, its status and actions inside it',
        (tester) async {
          await pumpHome(tester, phase);

          expectOneCard();
          expect(inCard(find.text(expected.status)), findsOneWidget);
          for (final text in expected.inside) {
            expect(inCard(find.text(text)), findsOneWidget, reason: text);
          }
          // Wi-Fi waits until Smarty is nearby; About your child doesn't.
          expect(find.text('Wi-Fi'), findsOneWidget);
          expect(row(tester, 'Wi-Fi').onTap, isNull);
          expect(inCard(find.text(wifiRowAwayDetail)), findsOneWidget);
          expect(row(tester, 'About your child').onTap, isNotNull);
          expect(find.text('Finish setup'), findsNothing);
          await unmount(tester);
        },
      );
    });

    testWidgets('no toy yet: only "Set up Smarty" — no card, no ⋯', (
      tester,
    ) async {
      await pumpHome(tester, ToyPhase.noToy);

      expect(find.text('Set up Smarty'), findsOneWidget);
      expect(find.byType(SmartyCard), findsNothing);
      expect(find.text('About your child'), findsNothing);
      expect(find.text('Wi-Fi'), findsNothing);
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
      expect(find.byType(SmartyCard), findsOneWidget); // still saved
      await unmount(tester);
    });

    testWidgets('dark mode: the card uses the dark colours', (tester) async {
      final toyPhase = ValueNotifier<ToyPhase>(ToyPhase.notNearby);
      addTearDown(toyPhase.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: Brightness.dark),
          home: HomeTab(toyPhase: toyPhase),
        ),
      );
      await tester.pump();

      final Container body = tester.widget<Container>(
        find
            .descendant(
              of: find.byType(SmartyCard),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(body.color, SmartyCard.background(true));
      final Text name = tester.widget<Text>(inCard(find.text('Smarty')));
      expect(name.style?.color, Colors.white);
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

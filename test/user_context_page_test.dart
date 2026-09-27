// "About your child": which copy of the notes the page shows on open.
// Smarty's own copy is the one that counts; the phone's copy is only shown
// when Smarty can't be reached, or when an unsent edit is waiting on the
// phone. Bluetooth is replaced by fakes; the phone's copy lives in
// (mocked) SharedPreferences, per account.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:smarty_app/providers/user_context_provider.dart';
import 'package:smarty_app/screens/user_context_page.dart';
import 'package:smarty_app/services/ble_manager.dart';
import 'package:smarty_app/utils/theme_provider.dart';

const String fetching = 'Getting the latest from Smarty…';

void main() {
  late List<String> written;
  late int reads;

  UserContextProvider makeProvider({
    required Future<String?> Function() readFromToy,
    bool toyConnected = true,
  }) {
    written = [];
    reads = 0;
    return UserContextProvider(
      readFromToy: () {
        reads++;
        return readFromToy();
      },
      writeToToy: (text) async {
        written.add(text);
        return true;
      },
      isToyConnected: () => toyConnected,
    );
  }

  Future<void> pumpPage(
    WidgetTester tester,
    UserContextProvider provider, {
    required ToyPhase phase,
  }) async {
    final toyPhase = ValueNotifier<ToyPhase>(phase);
    addTearDown(toyPhase.dispose);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider(create: (_) => ThemeProvider()),
          ChangeNotifierProvider.value(value: provider),
        ],
        child: MaterialApp(home: UserContextPage(toyPhase: toyPhase)),
      ),
    );
  }

  TextField field(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField));

  group('UserContextPage on open', () {
    testWidgets(
      "Smarty nearby: waits for Smarty's copy — never flashes the phone's",
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'user_context_parent-a': 'Old notes on this phone',
        });
        final toyCopy = Completer<String?>();
        final provider = makeProvider(readFromToy: () => toyCopy.future);
        await provider.debugSetAccount('parent-a');
        expect(provider.context, 'Old notes on this phone');

        await pumpPage(tester, provider, phase: ToyPhase.connected);
        await tester.pump(); // first frame's bootstrap
        await tester.pump();

        expect(find.text(fetching), findsOneWidget);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        expect(find.text('Old notes on this phone'), findsNothing);
        expect(field(tester).controller!.text, isEmpty);
        expect(field(tester).enabled, isFalse);

        toyCopy.complete('Ola is 5 and loves horses.');
        await tester.pumpAndSettle();

        expect(field(tester).controller!.text, 'Ola is 5 and loves horses.');
        expect(find.text('Old notes on this phone'), findsNothing);
        expect(find.text(fetching), findsNothing);
        expect(find.text('Smarty has the latest version.'), findsOneWidget);
        expect(field(tester).enabled, isTrue);
        expect(reads, 1);
        // The phone's copy for this account now matches Smarty.
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('user_context_parent-a'),
          'Ola is 5 and loves horses.',
        );
      },
    );

    testWidgets("Smarty doesn't answer in time: the phone's copy, with the "
        '"out of reach" note', (tester) async {
      SharedPreferences.setMockInitialValues({
        'user_context_parent-a': 'Notes on this phone',
      });
      final never = Completer<String?>();
      final provider = makeProvider(readFromToy: () => never.future);
      await provider.debugSetAccount('parent-a');

      await pumpPage(tester, provider, phase: ToyPhase.connected);
      await tester.pump();
      await tester.pump();
      expect(find.text(fetching), findsOneWidget);
      expect(field(tester).controller!.text, isEmpty);

      // The wait is bounded (~5 s).
      await tester.pump(UserContextProvider.defaultToyReadTimeout);
      await tester.pumpAndSettle();

      expect(field(tester).controller!.text, 'Notes on this phone');
      expect(find.text(UserContextProvider.offlineMessage), findsOneWidget);
      expect(find.text(fetching), findsNothing);
      expect(field(tester).enabled, isTrue);
    });

    testWidgets('Smarty read fails: the phone\'s copy, with the note', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'user_context_parent-a': 'Notes on this phone',
      });
      final provider = makeProvider(readFromToy: () async => null);
      await provider.debugSetAccount('parent-a');

      await pumpPage(tester, provider, phase: ToyPhase.connected);
      await tester.pumpAndSettle();

      expect(field(tester).controller!.text, 'Notes on this phone');
      expect(find.text(UserContextProvider.offlineMessage), findsOneWidget);
    });

    testWidgets(
      "Smarty away: the phone's copy right away, with the note — no wait",
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'user_context_parent-a': 'Notes on this phone',
        });
        final provider = makeProvider(
          readFromToy: () async => 'should not be read',
          toyConnected: false,
        );
        await provider.debugSetAccount('parent-a');

        await pumpPage(tester, provider, phase: ToyPhase.notNearby);
        await tester.pump();
        await tester.pump();

        expect(find.text(fetching), findsNothing);
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(field(tester).controller!.text, 'Notes on this phone');
        expect(find.text(UserContextProvider.offlineMessage), findsOneWidget);
        expect(field(tester).enabled, isTrue);
        expect(reads, 0);
      },
    );

    testWidgets(
      'an unsent edit on the phone: shown right away and sent to Smarty '
      "(Smarty's older copy is not read)",
      (tester) async {
        SharedPreferences.setMockInitialValues({
          'user_context_parent-a': 'My newer notes',
          'user_context_pending_sync_parent-a': true,
        });
        final provider = makeProvider(
          readFromToy: () async => "Smarty's older notes",
        );
        await provider.debugSetAccount('parent-a');
        expect(provider.hasPendingSync, isTrue);

        await pumpPage(tester, provider, phase: ToyPhase.connected);
        await tester.pump();
        await tester.pump();
        // No "getting the latest" wait: the phone's edit wins.
        expect(field(tester).controller!.text, 'My newer notes');

        await tester.pumpAndSettle();
        expect(field(tester).controller!.text, 'My newer notes');
        expect(find.text("Smarty's older notes"), findsNothing);
        expect(written, ['My newer notes']);
        expect(reads, 0);
        expect(provider.hasPendingSync, isFalse);
      },
    );
  });

  test(
    'waitForToyCopyOnOpen: only when Smarty is here and nothing is unsent',
    () {
      expect(
        waitForToyCopyOnOpen(toyConnected: true, hasPendingSync: false),
        isTrue,
      );
      expect(
        waitForToyCopyOnOpen(toyConnected: true, hasPendingSync: true),
        isFalse,
      );
      expect(
        waitForToyCopyOnOpen(toyConnected: false, hasPendingSync: false),
        isFalse,
      );
    },
  );

  group('UserContextProvider keeps each account\'s notes apart', () {
    test(
      'switching accounts never shows the previous account\'s notes',
      () async {
        SharedPreferences.setMockInitialValues({
          'user_context_parent-a': "A's notes",
          'user_context_parent-b': "B's notes",
        });
        final provider = makeProvider(readFromToy: () async => null);
        await provider.debugSetAccount('parent-a');
        expect(provider.context, "A's notes");

        // Cleared at once — not only after the new account's copy loads.
        final loading = provider.debugSetAccount('parent-b');
        expect(provider.context, isEmpty);
        await loading;
        expect(provider.context, "B's notes");

        await provider.debugSetAccount('parent-c');
        expect(provider.context, isEmpty);

        await provider.debugSetAccount(null);
        expect(provider.context, isEmpty);
      },
    );

    test("Smarty's copy is cached under the signed-in account only", () async {
      SharedPreferences.setMockInitialValues({
        'user_context_parent-a': 'old',
        'user_context_parent-b': "B's notes",
      });
      final provider = makeProvider(readFromToy: () async => 'from Smarty');
      await provider.debugSetAccount('parent-a');
      await provider.refreshFromDevice();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('user_context_parent-a'), 'from Smarty');
      expect(prefs.getString('user_context_parent-b'), "B's notes");
      expect(
        UserContextProvider.accountPrefsKeys('parent-a'),
        everyElement(endsWith('_parent-a')),
      );
    });
  });
}

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

  // After a factory reset (or erasing itself once removed from an account)
  // Smarty comes back unlinked with no profile; the setup page links it and
  // then sends the profile this phone keeps for the account.
  group('UserContextProvider.resendAfterLink', () {
    test(
      'the decision: whenever this phone has a profile the toy can hold',
      () {
        bool resend({
          bool signedIn = true,
          String profile = 'Loves dinosaurs',
          int maxBytes = 500,
        }) => UserContextProvider.shouldResendAfterLink(
          signedIn: signedIn,
          profile: profile,
          maxBytes: maxBytes,
        );
        expect(resend(), isTrue);
        expect(resend(signedIn: false), isFalse);
        expect(resend(profile: ''), isFalse);
        expect(resend(profile: '   \n'), isFalse);
        expect(resend(profile: 'é' * 250), isTrue); // 500 bytes
        expect(resend(profile: 'é' * 251), isFalse); // 502 bytes
        expect(resend(profile: 'é' * 251, maxBytes: 1024), isTrue);
      },
    );

    test("Smarty connected: this phone's profile is written to it", () async {
      SharedPreferences.setMockInitialValues({
        'user_context_parent-a': 'Loves dinosaurs',
      });
      // A reset toy has nothing.
      final provider = makeProvider(readFromToy: () async => '');
      await provider.debugSetAccount('parent-a');

      await provider.resendAfterLink();
      expect(written, ['Loves dinosaurs']);
      expect(reads, 0); // never replaced by the toy's empty copy
      expect(provider.context, 'Loves dinosaurs');
      expect(provider.hasPendingSync, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('user_context_parent-a'), 'Loves dinosaurs');
      expect(prefs.getBool('user_context_pending_sync_parent-a'), isNull);
    });

    test('Smarty out of reach: kept pending — it goes out on the next connect '
        '(and Smarty\'s empty copy never replaces it)', () async {
      SharedPreferences.setMockInitialValues({
        'user_context_parent-a': 'Loves dinosaurs',
      });
      final provider = makeProvider(
        readFromToy: () async => '',
        toyConnected: false,
      );
      await provider.debugSetAccount('parent-a');

      await provider.resendAfterLink();
      expect(written, isEmpty);
      expect(provider.hasPendingSync, isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('user_context_pending_sync_parent-a'), isTrue);

      // Back (e.g. the profile page opens): the phone's copy is pushed.
      final back = UserContextProvider(
        readFromToy: () async => '',
        writeToToy: (text) async {
          written.add(text);
          return true;
        },
        isToyConnected: () => true,
      );
      await back.debugSetAccount('parent-a');
      expect(back.hasPendingSync, isTrue);
      await back.refreshFromDevice();
      expect(written, ['Loves dinosaurs']);
      expect(back.context, 'Loves dinosaurs');
      expect(back.hasPendingSync, isFalse);
    });

    test('the write fails: stays pending', () async {
      SharedPreferences.setMockInitialValues({
        'user_context_parent-a': 'Loves dinosaurs',
      });
      final provider = UserContextProvider(
        readFromToy: () async => '',
        writeToToy: (_) async => false,
        isToyConnected: () => true,
      );
      await provider.debugSetAccount('parent-a');
      await provider.resendAfterLink();
      expect(provider.hasPendingSync, isTrue);
      expect(provider.context, 'Loves dinosaurs');
    });

    test('no profile on this phone (e.g. a new phone): nothing sent, nothing '
        'pending', () async {
      SharedPreferences.setMockInitialValues({});
      final provider = makeProvider(readFromToy: () async => 'on Smarty');
      await provider.debugSetAccount('parent-a');
      await provider.resendAfterLink();
      expect(written, isEmpty);
      expect(provider.hasPendingSync, isFalse);
    });

    test('signed out: nothing sent', () async {
      SharedPreferences.setMockInitialValues({
        'user_context_parent-a': 'Loves dinosaurs',
      });
      final provider = makeProvider(readFromToy: () async => '');
      await provider.resendAfterLink();
      expect(written, isEmpty);
    });
  });

  // The phone keeps the account's copy of the profile whenever the account's
  // own toy connects — not only when "About your child" is opened — so the
  // copy is there to send back after a reset.
  group("the account's copy of the profile", () {
    late String toyProfile;
    late ValueNotifier<ToyPhase> phase;
    late ValueNotifier<bool> accountToy;

    UserContextProvider watching() {
      written = [];
      reads = 0;
      phase = ValueNotifier(ToyPhase.notNearby);
      accountToy = ValueNotifier(false);
      addTearDown(phase.dispose);
      addTearDown(accountToy.dispose);
      final provider = UserContextProvider(
        readFromToy: () async {
          reads++;
          return toyProfile;
        },
        writeToToy: (text) async {
          written.add(text);
          toyProfile = text;
          return true;
        },
        isToyConnected: () => phase.value == ToyPhase.connected,
        toyPhase: phase,
        accountToyConfirmed: accountToy,
      );
      return provider;
    }

    // The account's own toy connects: BleManager reaches `connected`, then
    // its account check confirms the toy is on this account.
    Future<void> accountToyConnects() async {
      phase.value = ToyPhase.connected;
      accountToy.value = true;
      await pumpEventQueue();
    }

    test('the decision: only for the account\'s own toy, signed in, and '
        'nothing else running', () {
      bool sync({bool confirmed = true, bool signedIn = true,
              bool busy = false}) =>
          UserContextProvider.shouldSyncWithAccountToy(
              confirmed: confirmed, signedIn: signedIn, busy: busy);
      expect(sync(), isTrue);
      expect(sync(confirmed: false), isFalse);
      expect(sync(signedIn: false), isFalse);
      expect(sync(busy: true), isFalse);
    });

    test(
        "a phone that never opened About your child: the profile is kept when "
        'the toy connects, and sent back after a reset and a new link',
        () async {
      // 2026-10-01: the toy held 407 bytes; this phone had no copy for the
      // account (it had never opened About your child), so after the toy
      // erased itself resendAfterLink had nothing to send.
      SharedPreferences.setMockInitialValues({});
      toyProfile = 'Ola is 5 and loves horses.';
      final provider = watching();
      await provider.debugSetAccount('parent-a');
      provider.debugWatchToy();

      await accountToyConnects();
      expect(reads, 1);
      expect(written, isEmpty);
      expect(provider.context, 'Ola is 5 and loves horses.');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('user_context_parent-a'),
          'Ola is 5 and loves horses.');

      // Removed from the account: the toy erases itself and restarts empty.
      accountToy.value = false;
      phase.value = ToyPhase.notNearby;
      toyProfile = '';
      // Set up again: linked on this connection — never read (its empty
      // profile isn't the account's) …
      phase.value = ToyPhase.connected;
      await pumpEventQueue();
      expect(reads, 1);
      // … and the link step sends the account's copy back.
      await provider.resendAfterLink();
      expect(written, ['Ola is 5 and loves horses.']);
      expect(toyProfile, 'Ola is 5 and loves horses.');
      expect(provider.hasPendingSync, isFalse);
    });

    test('an edit that never reached Smarty is sent, not replaced by the '
        "toy's older copy", () async {
      SharedPreferences.setMockInitialValues({
        'user_context_parent-a': 'New notes',
        'user_context_pending_sync_parent-a': true,
      });
      toyProfile = 'Old notes';
      final provider = watching();
      await provider.debugSetAccount('parent-a');
      provider.debugWatchToy();

      await accountToyConnects();
      expect(written, ['New notes']);
      expect(reads, 0);
      expect(provider.context, 'New notes');
      expect(provider.hasPendingSync, isFalse);
    });

    test('already connected to it when the app starts following the toy',
        () async {
      SharedPreferences.setMockInitialValues({});
      toyProfile = 'Loves dinosaurs';
      final provider = watching();
      phase.value = ToyPhase.connected;
      accountToy.value = true;
      await provider.debugSetAccount('parent-a');
      provider.debugWatchToy();
      await pumpEventQueue();
      expect(reads, 1);
      expect(provider.context, 'Loves dinosaurs');
    });

    test('signed out: nothing read, nothing kept', () async {
      SharedPreferences.setMockInitialValues({});
      toyProfile = 'Loves dinosaurs';
      final provider = watching();
      provider.debugWatchToy();
      await accountToyConnects();
      expect(reads, 0);
      expect(provider.context, isEmpty);
    });

    test("resendAfterLink waits for the account's copy to load first",
        () async {
      SharedPreferences.setMockInitialValues({
        'user_context_parent-a': 'Loves dinosaurs',
      });
      toyProfile = '';
      final provider = watching();
      phase.value = ToyPhase.connected;
      // Not awaited: the link step can finish while the copy is loading.
      unawaited(provider.debugSetAccount('parent-a'));
      await provider.resendAfterLink();
      expect(written, ['Loves dinosaurs']);
    });
  });
}

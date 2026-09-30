// "Remove this Smarty from my account": the request to our server
// (unregisterDevice), what the app does around it (fresh sign-in token, the
// account's toys read afresh, the phone forgets its toy when it's that one),
// the confirm sheet, and the ⋯ menu's two ways to let go of a toy.
import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:smarty_app/dev_config.dart';
import 'package:smarty_app/services/known_toys_service.dart';
import 'package:smarty_app/widgets/forget_toy.dart';
import 'package:smarty_app/widgets/remove_toy.dart';

Matcher throwsRemoveProblem(RemoveToyProblem p) => throwsA(
  isA<RemoveToyException>().having((e) => e.problem, 'problem', p),
);

void main() {
  group('requestToyRemovalOnServer', () {
    test('POSTs {device_id, keep_history} to unregisterDevice with the Bearer '
        'token', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(jsonEncode({'ok': true, 'kept_history': true}), 200);
      });
      await requestToyRemovalOnServer('tok', '1cc3abc9b11c',
          keepHistory: true, client: client);
      expect(seen.method, 'POST');
      expect(seen.url.toString(), DevConfig.functionUrl('unregisterDevice'));
      expect(seen.headers['Authorization'], 'Bearer tok');
      expect(seen.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(seen.body),
          {'device_id': '1cc3abc9b11c', 'keep_history': true});
    });

    test('keep_history false is sent as false', () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response('{"ok":true,"kept_history":false}', 200);
      });
      await requestToyRemovalOnServer('tok', '1cc3abc9b11c',
          keepHistory: false, client: client);
      expect(jsonDecode(seen.body)['keep_history'], false);
    });

    test('cloud URL', () {
      expect(DevConfig.functionUrl('unregisterDevice'),
          'https://europe-west1-smarty-7e350.cloudfunctions.net/unregisterDevice');
    });

    test('404 "Device not found" = already off the account → done', () async {
      final client =
          MockClient((_) async => http.Response('Device not found', 404));
      await requestToyRemovalOnServer('tok', '1cc3abc9b11c',
          keepHistory: false, client: client);
    });

    test('any other 404 (e.g. the function is not there) → server', () async {
      final client = MockClient(
          (_) async => http.Response('<html>Page not found</html>', 404));
      await expectLater(
          requestToyRemovalOnServer('tok', 'x',
              keepHistory: false, client: client),
          throwsRemoveProblem(RemoveToyProblem.server));
    });

    test('401 → sign in again', () async {
      final client =
          MockClient((_) async => http.Response('Invalid auth token', 401));
      await expectLater(
          requestToyRemovalOnServer('tok', 'x',
              keepHistory: false, client: client),
          throwsRemoveProblem(RemoveToyProblem.signInAgain));
    });

    for (final status in [400, 405, 500, 503]) {
      test('HTTP $status → server', () async {
        final client =
            MockClient((_) async => http.Response('Internal error', status));
        await expectLater(
            requestToyRemovalOnServer('tok', 'x',
                keepHistory: true, client: client),
            throwsRemoveProblem(RemoveToyProblem.server));
      });
    }

    test('no internet → network', () async {
      final client = MockClient(
          (_) async => throw http.ClientException('Connection refused'));
      await expectLater(
          requestToyRemovalOnServer('tok', 'x',
              keepHistory: true, client: client),
          throwsRemoveProblem(RemoveToyProblem.network));
    });

    test('no answer within the timeout → network', () async {
      final never = Completer<http.Response>();
      final client = MockClient((_) => never.future);
      await expectLater(
          requestToyRemovalOnServer('tok', 'x',
              keepHistory: true,
              client: client,
              timeout: const Duration(milliseconds: 10)),
          throwsRemoveProblem(RemoveToyProblem.network));
    });

    test('the default timeout is 10 s', () {
      expect(removeToyTimeout, const Duration(seconds: 10));
    });
  });

  group('RemoveToyException.message', () {
    test('plain words for each problem', () {
      expect(const RemoveToyException(RemoveToyProblem.network).message,
          "We couldn't reach Smarty's server. Check your internet and try again.");
      for (final p in RemoveToyProblem.values) {
        final String m = RemoveToyException(p).message;
        expect(m, isNotEmpty);
        for (final jargon in ['HTTP', 'device', 'unregister', 'Exception']) {
          expect(m, isNot(contains(jargon)), reason: '$p: $m');
        }
      }
    });
  });

  group('KnownToysService.removeFromAccount', () {
    late List<http.Request> requests;
    late int reads;
    late int forgets;
    late List<(String, String?)> savedChecks;

    KnownToysService service({
      Future<String?> Function()? token,
      int status = 200,
      String body = '{"ok":true}',
      bool saved = false,
    }) {
      requests = [];
      reads = 0;
      forgets = 0;
      savedChecks = [];
      return KnownToysService(
        currentUid: () => 'parent-a',
        read: (_) async {
          reads++;
          return (
            records: [
              ('1cc3abc9b11c', <String, dynamic>{'ble_name': 'Smarty-B11E'}),
              ('0a0b0c0d0e0f', <String, dynamic>{}),
            ],
            fromCache: false,
          );
        },
        freshIdToken: token ?? () async => 'fresh-token',
        httpClient: MockClient((req) async {
          requests.add(req);
          return http.Response(body, status);
        }),
        isSavedToyCheck: (id, name) {
          savedChecks.add((id, name));
          return saved;
        },
        forgetSavedToy: () async => forgets++,
      );
    }

    test('sends the fresh token; the account is read afresh next time; the '
        'phone keeps its toy when it is another one', () async {
      final s = service();
      expect(await s.knownToysForAccount(), hasLength(2));
      await s.removeFromAccount('1cc3abc9b11c', keepHistory: true);

      expect(requests, hasLength(1));
      expect(requests.single.headers['Authorization'], 'Bearer fresh-token');
      expect(jsonDecode(requests.single.body),
          {'device_id': '1cc3abc9b11c', 'keep_history': true});
      // The name the account had for it goes into the "is it the phone's
      // toy?" check.
      expect(savedChecks, [('1cc3abc9b11c', 'Smarty-B11E')]);
      expect(forgets, 0);

      await s.knownToysForAccount();
      expect(reads, 2);
    });

    test("the phone's own toy: the phone forgets it too", () async {
      final s = service(saved: true);
      await s.removeFromAccount('0a0b0c0d0e0f', keepHistory: false);
      expect(forgets, 1);
      expect(savedChecks, [('0a0b0c0d0e0f', null)]); // nothing read yet
    });

    test('signed out (no token) → sign in again, nothing sent', () async {
      final s = service(token: () async => null);
      await expectLater(s.removeFromAccount('x', keepHistory: true),
          throwsRemoveProblem(RemoveToyProblem.signInAgain));
      expect(requests, isEmpty);
    });

    test('the token refresh has no internet → network, nothing sent',
        () async {
      final s = service(
          token: () async => throw FirebaseAuthException(
              code: 'network-request-failed'));
      await expectLater(s.removeFromAccount('x', keepHistory: true),
          throwsRemoveProblem(RemoveToyProblem.network));
      expect(requests, isEmpty);
    });

    test('the token refresh is refused → sign in again', () async {
      final s = service(
          token: () async =>
              throw FirebaseAuthException(code: 'user-token-expired'));
      await expectLater(s.removeFromAccount('x', keepHistory: true),
          throwsRemoveProblem(RemoveToyProblem.signInAgain));
    });

    test('the server fails → nothing changes on the phone', () async {
      final s = service(status: 500, body: 'Internal error', saved: true);
      await s.knownToysForAccount();
      await expectLater(s.removeFromAccount('1cc3abc9b11c', keepHistory: true),
          throwsRemoveProblem(RemoveToyProblem.server));
      expect(forgets, 0);
      await s.knownToysForAccount();
      expect(reads, 1); // still from memory
    });

    test('forgetting on the phone failing does not undo the removal',
        () async {
      final s = KnownToysService(
        currentUid: () => 'p',
        read: (_) async => (records: const <(String, Map<String, dynamic>)>[],
            fromCache: false),
        freshIdToken: () async => 't',
        httpClient: MockClient((_) async => http.Response('{"ok":true}', 200)),
        isSavedToyCheck: (_, _) => true,
        forgetSavedToy: () async => throw StateError('bluetooth'),
      );
      await s.removeFromAccount('x', keepHistory: false);
    });
  });

  group('isSavedToy', () {
    test('no toy saved on this phone → never', () {
      expect(
          isSavedToy(
              deviceId: '1cc3abc9b11c',
              savedToyId: null,
              savedToyDeviceId: '1cc3abc9b11c',
              savedToyName: 'Smarty-B11E'),
          isFalse);
    });

    test("the saved toy's id, once read, decides", () {
      expect(
          isSavedToy(
              deviceId: '1cc3abc9b11c',
              savedToyId: 'AA:BB',
              savedToyDeviceId: '1cc3abc9b11c'),
          isTrue);
      expect(
          isSavedToy(
              deviceId: '1cc3abc9b11c',
              savedToyId: 'AA:BB',
              savedToyDeviceId: '0a0b0c0d0e0f',
              savedToyName: 'Smarty-B11E'),
          isFalse);
    });

    test('else by name: the stored one, or worked out from the id', () {
      expect(
          isSavedToy(
              deviceId: '1cc3abc9b11c',
              savedToyId: 'AA:BB',
              savedToyName: 'smarty-b11e'),
          isTrue);
      expect(
          isSavedToy(
              deviceId: '1cc3abc9b11c',
              bleName: 'Smarty-ABCD',
              savedToyId: 'AA:BB',
              savedToyName: 'Smarty-ABCD'),
          isTrue);
      expect(
          isSavedToy(
              deviceId: '1cc3abc9b11c',
              savedToyId: 'AA:BB',
              savedToyName: 'Smarty-0E11'),
          isFalse);
      expect(
          isSavedToy(
              deviceId: '1cc3abc9b11c', savedToyId: 'AA:BB', savedToyName: 'Smarty'),
          isFalse);
    });
  });

  group('knownToyIdNamed', () {
    const toys = [
      KnownToy(deviceId: '1cc3abc9b11c', bleName: 'Smarty-B11E'),
      KnownToy(deviceId: '0a0b0c0d0e0f', bleName: 'Smarty-0E11'),
    ];
    test('finds the toy by its name', () {
      expect(knownToyIdNamed(toys, 'smarty-0e11'), '0a0b0c0d0e0f');
    });
    test('no such toy, or no name → null', () {
      expect(knownToyIdNamed(toys, 'Smarty-FFFF'), isNull);
      expect(knownToyIdNamed(toys, null), isNull);
      expect(knownToyIdNamed(const [], 'Smarty-B11E'), isNull);
    });
  });

  group('confirm sheet', () {
    late List<bool> calls;
    late Future<void> Function(bool keep) remove;
    bool? result;

    Future<void> openSheet(WidgetTester tester,
        {String? name = 'Smarty-B11E', bool isIOS = false}) async {
      calls = [];
      result = null;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await confirmAndRemoveToy(
                  context,
                  bleName: name,
                  isIOS: isIOS,
                  remove: (keep) {
                    calls.add(keep);
                    return remove(keep);
                  },
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    setUp(() => remove = (_) async {});

    testWidgets('says what happens; keeping the chats is OFF unless chosen',
        (tester) async {
      await openSheet(tester);
      expect(find.text('Remove Smarty-B11E from your account?'), findsOneWidget);
      expect(find.text(removeToyBody), findsOneWidget);
      expect(
          find.text('Keep its conversations in my Conversations tab '
              '(for 90 days)'),
          findsOneWidget);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
          isFalse);
      expect(find.text(eraseToyNote), findsOneWidget);
      expect(find.textContaining(eraseToyNoteIOS), findsNothing);
      expect(find.text('Remove'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('iPhone: also forget it in Settings → Bluetooth',
        (tester) async {
      await openSheet(tester, isIOS: true);
      expect(find.text('$eraseToyNote $eraseToyNoteIOS'), findsOneWidget);
    });

    testWidgets('Cancel: nothing removed', (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(result, isFalse);
      expect(find.byType(RemoveToySheet), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    testWidgets('Remove as it is: chats not kept; then the note',
        (tester) async {
      await openSheet(tester);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(calls, [false]);
      expect(result, isTrue);
      expect(find.byType(RemoveToySheet), findsNothing);
      expect(find.text('Smarty-B11E was removed from your account.'),
          findsOneWidget);
    });

    testWidgets('switched on: chats kept', (tester) async {
      await openSheet(tester);
      await tester.tap(find.byType(Switch));
      await tester.pump();
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(calls, [true]);
    });

    testWidgets('while removing: a spinner on the button, nothing else can be '
        'tapped', (tester) async {
      final gate = Completer<void>();
      remove = (_) => gate.future;
      await openSheet(tester);
      await tester.tap(find.text('Remove'));
      await tester.pump();

      expect(
          find.descendant(
              of: find.byType(FilledButton),
              matching: find.byType(CircularProgressIndicator)),
          findsOneWidget);
      expect(find.text('Remove'), findsNothing);
      expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
          isNull);
      expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, 'Cancel'))
              .onPressed,
          isNull);
      expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile))
          .onChanged, isNull);

      gate.complete();
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(find.byType(RemoveToySheet), findsNothing);
    });

    testWidgets('a failure is explained in the sheet, which stays open; '
        'trying again works', (tester) async {
      remove = (_) async =>
          throw const RemoveToyException(RemoveToyProblem.network);
      await openSheet(tester);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.byType(RemoveToySheet), findsOneWidget);
      expect(
          find.text("We couldn't reach Smarty's server. Check your internet "
              'and try again.'),
          findsOneWidget);
      expect(result, isNull);

      remove = (_) async {};
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(calls, [false, false]);
      expect(result, isTrue);
    });

    testWidgets('an unexpected error: a plain message', (tester) async {
      remove = (_) async => throw StateError('boom');
      await openSheet(tester);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Something went wrong. Please try again.'),
          findsOneWidget);
      expect(find.textContaining('boom'), findsNothing);
    });

    testWidgets('name not known: "this Smarty"', (tester) async {
      await openSheet(tester, name: null);
      expect(find.text('Remove this Smarty from your account?'), findsOneWidget);
      await tester.tap(find.text('Remove'));
      await tester.pumpAndSettle();
      expect(find.text('Smarty was removed from your account.'), findsOneWidget);
    });
  });

  group('⋯ menu', () {
    Future<void> openMenu(WidgetTester tester,
        {required VoidCallback onForget, VoidCallback? onRemove}) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ToyMoreButton(onForget: onForget, onRemove: onRemove),
        ),
      ));
      await tester.tap(find.byTooltip(ToyMoreButton.tooltip));
      await tester.pumpAndSettle();
    }

    testWidgets('Forget (this phone) and Remove (the account), each saying '
        'what it does', (tester) async {
      int forgets = 0, removes = 0;
      await openMenu(tester,
          onForget: () => forgets++, onRemove: () => removes++);
      expect(find.text('Forget this Smarty'), findsOneWidget);
      expect(find.text('This phone forgets it; your account still has it.'),
          findsOneWidget);
      expect(find.text('Remove from my account'), findsOneWidget);
      expect(
          find.text('Unlinks it from your account; frees it for another '
              'family.'),
          findsOneWidget);

      await tester.tap(find.text('Remove from my account'));
      await tester.pumpAndSettle();
      expect((forgets, removes), (0, 1));

      await tester.tap(find.byTooltip(ToyMoreButton.tooltip));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Forget this Smarty'));
      await tester.pumpAndSettle();
      expect((forgets, removes), (1, 1));
    });

    testWidgets('without onRemove: only Forget', (tester) async {
      await openMenu(tester, onForget: () {});
      expect(find.text('Forget this Smarty'), findsOneWidget);
      expect(find.text('Remove from my account'), findsNothing);
    });
  });
}

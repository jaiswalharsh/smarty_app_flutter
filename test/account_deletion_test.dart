// Account deletion: the server call and the order of steps, with fakes for
// the sign-in service, the server, Bluetooth and saved data.

import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:smarty_app/dev_config.dart';
import 'package:smarty_app/screens/account/account_helpers.dart';
import 'package:smarty_app/services/account_service.dart';

Matcher throwsProblem(AccountProblem p) => throwsA(
    isA<AccountException>().having((e) => e.problem, 'problem', p));

/// Records every step; each can be made to fail.
class FakeSteps {
  final List<String> calls = [];
  Object? reauthError;
  Object? tokenError;
  String? token = 'fresh-token';
  Object? serverError;
  Object? deleteUserError =
      FirebaseAuthException(code: 'user-not-found'); // the usual case
  Object? forgetError;

  Future<void> _step(String name, [Object? error]) async {
    calls.add(name);
    if (error != null) throw error;
  }

  AccountDeletionSteps get steps => AccountDeletionSteps(
        reauthenticate: () => _step('reauth', reauthError),
        freshIdToken: () async {
          calls.add('token');
          if (tokenError != null) throw tokenError!;
          return token;
        },
        deleteOnServer: (t) => _step('server:$t', serverError),
        deleteSignInAccount: () => _step('deleteUser', deleteUserError),
        forgetToy: () => _step('forgetToy', forgetError),
        clearLocalData: () => _step('clearLocal'),
        signOut: () => _step('signOut'),
      );
}

void main() {
  group('runAccountDeletion', () {
    late FakeSteps f;
    setUp(() => f = FakeSteps());

    test('success: server first, then the fallback delete and phone tidy-up',
        () async {
      await runAccountDeletion(f.steps);
      expect(f.calls, [
        'reauth',
        'token',
        'server:fresh-token',
        'deleteUser',
        'forgetToy',
        'clearLocal',
        'signOut',
      ]);
    });

    test('user.delete() failing after the server deleted it is fine',
        () async {
      for (final code in ['user-not-found', 'user-token-expired',
          'invalid-user-token', 'something-else']) {
        f = FakeSteps()..deleteUserError = FirebaseAuthException(code: code);
        await runAccountDeletion(f.steps);
        expect(f.calls.last, 'signOut', reason: code);
      }
    });

    test('a failed phone tidy-up step does not stop the others', () async {
      f.forgetError = Exception('bluetooth off');
      await runAccountDeletion(f.steps);
      expect(f.calls.sublist(4), ['forgetToy', 'clearLocal', 'signOut']);
    });

    test('server failure stops: nothing deleted, friendly message', () async {
      f.serverError = const AccountException(AccountProblem.deleteFailed);
      await expectLater(runAccountDeletion(f.steps),
          throwsProblem(AccountProblem.deleteFailed));
      expect(f.calls, ['reauth', 'token', 'server:fresh-token']);
      expect(accountProblemMessage(AccountProblem.deleteFailed),
          "We couldn't delete your account right now. Please check your "
          'internet and try again.');
    });

    test('an unexpected server-step error is also a deleteFailed stop',
        () async {
      f.serverError = StateError('boom');
      await expectLater(runAccountDeletion(f.steps),
          throwsProblem(AccountProblem.deleteFailed));
      expect(f.calls, ['reauth', 'token', 'server:fresh-token']);
    });

    test('token refresh failure stops before the server', () async {
      f.tokenError = FirebaseAuthException(code: 'network-request-failed');
      await expectLater(runAccountDeletion(f.steps),
          throwsProblem(AccountProblem.deleteFailed));
      expect(f.calls, ['reauth', 'token']);
    });

    test('signed out mid-way asks to sign in again', () async {
      f.token = null;
      await expectLater(runAccountDeletion(f.steps),
          throwsProblem(AccountProblem.signInAgain));
      expect(f.calls, ['reauth', 'token']);
    });

    test('wrong password stops before anything else', () async {
      f.reauthError = FirebaseAuthException(code: 'wrong-password');
      await expectLater(runAccountDeletion(f.steps),
          throwsProblem(AccountProblem.wrongPassword));
      expect(f.calls, ['reauth']);
    });
  });

  group('requestAccountDeletionOnServer', () {
    test('POSTs to deleteAccount with the Bearer token; 200 is success',
        () async {
      late http.Request seen;
      final client = MockClient((req) async {
        seen = req;
        return http.Response(
            jsonEncode({'ok': true, 'devices': 1, 'deleted_docs': 9}), 200);
      });
      await requestAccountDeletionOnServer('tok', client: client);
      expect(seen.method, 'POST');
      expect(seen.url.toString(), DevConfig.functionUrl('deleteAccount'));
      expect(seen.headers['Authorization'], 'Bearer tok');
    });

    test('cloud URL', () {
      expect(DevConfig.useEmulator, isFalse);
      expect(DevConfig.functionUrl('deleteAccount'),
          'https://europe-west1-smarty-7e350.cloudfunctions.net/deleteAccount');
    });

    for (final status in [401, 404, 500, 503]) {
      test('HTTP $status → deleteFailed', () async {
        final client =
            MockClient((_) async => http.Response('Internal error', status));
        await expectLater(
            requestAccountDeletionOnServer('tok', client: client),
            throwsProblem(AccountProblem.deleteFailed));
      });
    }

    test('no internet → deleteFailed', () async {
      final client = MockClient(
          (_) async => throw http.ClientException('Connection refused'));
      await expectLater(requestAccountDeletionOnServer('tok', client: client),
          throwsProblem(AccountProblem.deleteFailed));
    });

    test('timeout → deleteFailed', () async {
      final never = Completer<http.Response>();
      final client = MockClient((_) => never.future);
      await expectLater(
          requestAccountDeletionOnServer('tok',
              client: client, timeout: const Duration(milliseconds: 10)),
          throwsProblem(AccountProblem.deleteFailed));
    });
  });
}

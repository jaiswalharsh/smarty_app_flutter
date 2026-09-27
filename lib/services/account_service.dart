import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../dev_config.dart';
import '../providers/user_context_provider.dart';
import 'auth_service.dart';
import 'ble_manager.dart';

/// What went wrong with an account action, in terms the page can explain to a
/// parent. Raw error text is never shown.
enum AccountProblem {
  wrongPassword,
  network,
  tooManyRequests,
  signInAgain,

  /// Our server couldn't erase the account (offline, timeout, server error).
  /// Nothing was deleted; trying again is safe.
  deleteFailed,
  other,
}

class AccountException implements Exception {
  const AccountException(this.problem);
  final AccountProblem problem;

  @override
  String toString() => 'AccountException($problem)';
}

/// Maps a sign-in service error code to an [AccountProblem]. Pure (tests).
AccountProblem accountProblemFromCode(String code) {
  switch (code) {
    case 'wrong-password':
    case 'invalid-credential':
    case 'invalid-login-credentials':
    case 'user-mismatch':
      return AccountProblem.wrongPassword;
    case 'network-request-failed':
      return AccountProblem.network;
    case 'too-many-requests':
      return AccountProblem.tooManyRequests;
    case 'requires-recent-login':
    case 'user-token-expired':
      return AccountProblem.signInAgain;
    default:
      return AccountProblem.other;
  }
}

/// Every SharedPreferences key this app keeps for the account [uid] on this
/// phone: the saved toy (id, name, old last-Wi-Fi key) and the "About your
/// child" notes (cache + waiting-to-send flag). Pure (tests).
List<String> localAccountDataKeys(String uid) => [
      ...BleManager.accountPrefsKeys(uid),
      ...UserContextProvider.accountPrefsKeys(uid),
    ];

/// Removes everything [localAccountDataKeys] lists for [uid]. Keys of other
/// accounts on the same phone, and app-wide settings (dark mode), are kept.
Future<void> clearLocalAccountData(String uid) async {
  final prefs = await SharedPreferences.getInstance();
  for (final key in localAccountDataKeys(uid)) {
    await prefs.remove(key);
  }
}

/// Sign out of the app. Tears down Bluetooth first so the next account doesn't
/// inherit a live connection: cancels the pending background connect and the
/// link-lost handler before disconnecting. The caller then returns to the
/// start screen.
Future<void> signOutOfSmarty() async {
  await BleManager().disconnectAndReset();
  await AuthService().signOut();
}

/// How long to wait for the `deleteAccount` Cloud Function.
const Duration deleteAccountTimeout = Duration(seconds: 10);

/// Asks our server to erase the signed-in parent's account: their saved
/// chats, their toy's registration and the sign-in account itself (the app
/// can't do this itself — the database rules deny client writes there).
///
/// POSTs to the `deleteAccount` Cloud Function with [idToken]. Returns on
/// HTTP 200; anything else (no internet, timeout, 401, 5xx) throws
/// [AccountProblem.deleteFailed]. [client] and [url] are for tests.
Future<void> requestAccountDeletionOnServer(
  String idToken, {
  http.Client? client,
  String? url,
  Duration timeout = deleteAccountTimeout,
}) async {
  final http.Client c = client ?? http.Client();
  try {
    final response = await c
        .post(
          Uri.parse(url ?? DevConfig.functionUrl('deleteAccount')),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
          },
          body: '{}',
        )
        .timeout(timeout);
    if (response.statusCode == 200) return;
    debugPrint('Account: deleteAccount HTTP ${response.statusCode}');
  } on TimeoutException {
    debugPrint('Account: deleteAccount timed out');
  } catch (e) {
    debugPrint('Account: deleteAccount request failed: $e');
  } finally {
    if (client == null) c.close();
  }
  throw const AccountException(AccountProblem.deleteFailed);
}

/// The steps of deleting an account, as functions so [runAccountDeletion]
/// can be tested without the sign-in service, the server or Bluetooth.
class AccountDeletionSteps {
  const AccountDeletionSteps({
    required this.reauthenticate,
    required this.freshIdToken,
    required this.deleteOnServer,
    required this.deleteSignInAccount,
    required this.forgetToy,
    required this.clearLocalData,
    required this.signOut,
  });

  /// Checks the password (also makes the sign-in "recent", which the server
  /// requires). Throws [FirebaseAuthException] on a wrong password etc.
  final Future<void> Function() reauthenticate;

  /// A force-refreshed ID token, or null when signed out.
  final Future<String?> Function() freshIdToken;

  /// [requestAccountDeletionOnServer].
  final Future<void> Function(String idToken) deleteOnServer;

  /// `User.delete()` — a fallback only: the server has already removed the
  /// sign-in account by the time this runs.
  final Future<void> Function() deleteSignInAccount;

  final Future<void> Function() forgetToy;
  final Future<void> Function() clearLocalData;
  final Future<void> Function() signOut;
}

/// Deletes the account, in an order that never leaves a half-deleted account
/// the parent can't retry:
///
/// 1. Check the password (throws, nothing touched).
/// 2. Ask the server to erase the data and the sign-in account. If that
///    fails, stop with [AccountProblem.deleteFailed]: the account, the toy
///    link on this phone and the saved notes all stay, and the parent can
///    simply try again while still signed in.
/// 3. `User.delete()` as a harmless fallback — it normally fails because the
///    server already removed the account, which is fine.
/// 4. Tidy up this phone (forget the toy, clear saved data, sign out); each
///    step is best-effort because the account is already gone.
Future<void> runAccountDeletion(AccountDeletionSteps steps) async {
  await guardAccountAction(steps.reauthenticate);

  String? idToken;
  try {
    idToken = await steps.freshIdToken();
  } catch (e) {
    debugPrint('Account: token refresh before delete failed: $e');
    throw const AccountException(AccountProblem.deleteFailed);
  }
  if (idToken == null) throw const AccountException(AccountProblem.signInAgain);

  try {
    await steps.deleteOnServer(idToken);
  } on AccountException {
    rethrow;
  } catch (e) {
    debugPrint('Account: server delete failed: $e');
    throw const AccountException(AccountProblem.deleteFailed);
  }

  // The server has deleted the sign-in account, so this usually fails with
  // user-not-found / user-token-expired. Any failure is fine here.
  try {
    await steps.deleteSignInAccount();
  } catch (e) {
    debugPrint('Account: sign-in account already gone ($e)');
  }

  for (final (label, step) in [
    ('forgetting the toy', steps.forgetToy),
    ('clearing saved data', steps.clearLocalData),
    ('sign-out after delete', steps.signOut),
  ]) {
    try {
      await step();
    } catch (e) {
      debugPrint('⚠️ Account: $label failed: $e');
    }
  }
}

/// Runs [action], turning sign-in service errors into [AccountException].
Future<void> guardAccountAction(Future<void> Function() action) async {
  try {
    await action();
  } on FirebaseAuthException catch (e) {
    debugPrint('Account: ${e.code}');
    throw AccountException(accountProblemFromCode(e.code));
  } on AccountException {
    rethrow;
  } catch (e) {
    debugPrint('Account error: $e');
    throw const AccountException(AccountProblem.other);
  }
}

/// The account actions the "Your account" page needs. Abstract so the page can
/// be tested without the sign-in service; [FirebaseAccountService] is the real
/// one. Methods throw [AccountException] on failure.
abstract class AccountService {
  String? get email;
  String? get displayName;

  /// Saves [name] (already checked with `validateDisplayName`).
  Future<void> updateDisplayName(String name);

  /// Emails the parent a link to set a new password.
  Future<void> sendPasswordReset();

  Future<void> signOut();

  /// Checks [password], has the server erase the account (saved chats, toy
  /// registration, sign-in account), then forgets the toy on this phone,
  /// clears this account's saved data on the phone and signs out. See
  /// [runAccountDeletion].
  Future<void> deleteAccount(String password);
}

class FirebaseAccountService implements AccountService {
  FirebaseAccountService();

  User? get _user => FirebaseAuth.instance.currentUser;

  @override
  String? get email => _user?.email;

  @override
  String? get displayName => _user?.displayName;

  @override
  Future<void> updateDisplayName(String name) async {
    final user = _user;
    if (user == null) throw const AccountException(AccountProblem.signInAgain);
    await guardAccountAction(() async {
      await user.updateDisplayName(name);
      await user.reload();
    });
  }

  @override
  Future<void> sendPasswordReset() async {
    final address = email;
    if (address == null || address.isEmpty) {
      throw const AccountException(AccountProblem.signInAgain);
    }
    await guardAccountAction(() => AuthService().sendPasswordResetEmail(address));
  }

  @override
  Future<void> signOut() => signOutOfSmarty();

  @override
  Future<void> deleteAccount(String password) async {
    final user = _user;
    final address = user?.email;
    if (user == null || address == null) {
      throw const AccountException(AccountProblem.signInAgain);
    }
    final uid = user.uid;
    await runAccountDeletion(AccountDeletionSteps(
      reauthenticate: () => user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: address, password: password),
      ),
      freshIdToken: () => user.getIdToken(true),
      deleteOnServer: requestAccountDeletionOnServer,
      deleteSignInAccount: user.delete,
      forgetToy: () => BleManager().forgetToy(),
      clearLocalData: () => clearLocalAccountData(uid),
      signOut: signOutOfSmarty,
    ));
  }
}

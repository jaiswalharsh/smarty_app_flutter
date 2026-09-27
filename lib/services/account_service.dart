import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  /// Checks [password], deletes the account, forgets the toy on this phone,
  /// clears this account's saved data on the phone and signs out.
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
    await _guard(() async {
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
    await _guard(() => AuthService().sendPasswordResetEmail(address));
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
    await _guard(() async {
      // Checking the password also refreshes the sign-in, so delete() below
      // can't fail for "signed in too long ago".
      await user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: address, password: password),
      );
      // TODO(account-deletion): call a deleteAccount Cloud Function to erase
      // parents/{uid} and devices_by_id entries (client writes there are
      // denied by the rules, so this can only be done server-side). It must
      // run here, while the user is still signed in. Required before App
      // Store submission (guideline 5.1.1(v)).
      await user.delete();
    });

    // The account is gone; now tidy up this phone. Done after the delete so a
    // failed delete (e.g. no internet) leaves the toy and notes untouched.
    try {
      await BleManager().forgetToy();
    } catch (e) {
      debugPrint('⚠️ Account: forgetting the toy failed: $e');
    }
    try {
      await clearLocalAccountData(uid);
    } catch (e) {
      debugPrint('⚠️ Account: clearing saved data failed: $e');
    }
    try {
      await signOutOfSmarty();
    } catch (e) {
      debugPrint('⚠️ Account: sign-out after delete failed: $e');
    }
  }

  static Future<void> _guard(Future<void> Function() action) async {
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
}

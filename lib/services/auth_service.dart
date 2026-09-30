import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'known_toys_service.dart';

class AuthService {
  static final AuthService _instance = AuthService._internal();
  factory AuthService() => _instance;
  AuthService._internal();

  final FirebaseAuth _auth = FirebaseAuth.instance;

  User? get currentUser => _auth.currentUser;
  bool get isSignedIn => _auth.currentUser != null;
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<String?> get idToken async {
    final user = _auth.currentUser;
    if (user == null) return null;
    return await user.getIdToken();
  }

  Future<UserCredential> signInWithEmail(String email, String password) async {
    return await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  Future<UserCredential> signUp(String email, String password) async {
    return await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
  }

  Future<void> sendPasswordResetEmail(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  /// Signs out — and first drops the claim keys this phone kept for the
  /// account (see KnownToysService), so nothing that proves the account to
  /// its toys stays on the phone.
  Future<void> signOut() async {
    final String? uid = _auth.currentUser?.uid;
    if (uid != null) {
      try {
        await KnownToysService.clearClaimKeys(uid);
      } catch (e) {
        debugPrint('AuthService: dropping claim keys failed: $e');
      }
    }
    await _auth.signOut();
  }
}

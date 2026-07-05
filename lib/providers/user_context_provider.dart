import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ble_manager.dart';

enum ContextSyncState {
  idle,
  loadingLocal,
  fetchingFromDevice,
  saving,
  error,
}

class UserContextProvider with ChangeNotifier {
  // Legacy device-global key (pre per-user scoping). Kept only for one-time
  // migration into the uid-scoped key — one parent's child profile must not
  // leak to another account on a shared phone.
  static const String _legacyPrefsKey = 'user_context';
  String _prefsKeyFor(String uid) => 'user_context_$uid';

  String _context = '';
  ContextSyncState _state = ContextSyncState.idle;
  String? _errorMessage;
  DateTime? _lastSyncedAt;

  String? _uid;
  StreamSubscription<User?>? _authSub;

  String get context => _context;
  ContextSyncState get state => _state;
  String? get errorMessage => _errorMessage;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  bool get isBusy =>
      _state == ContextSyncState.loadingLocal ||
      _state == ContextSyncState.fetchingFromDevice ||
      _state == ContextSyncState.saving;

  Future<void> init() async {
    // Idempotent: the root provider outlives logout/login. authStateChanges
    // replays the current user on subscribe, so the initial local load still
    // happens here (via _onAuthChanged) without a separate first read.
    _authSub ??=
        FirebaseAuth.instance.authStateChanges().listen(_onAuthChanged);
  }

  // Reload (or clear) in-memory state to match the signed-in account so a
  // second parent on the same phone never inherits the first parent's context.
  Future<void> _onAuthChanged(User? user) async {
    if (user?.uid == _uid) return;
    _uid = user?.uid;

    if (_uid == null) {
      _context = '';
      _state = ContextSyncState.idle;
      _errorMessage = null;
      _lastSyncedAt = null;
      notifyListeners();
      return;
    }

    final uid = _uid!;
    _state = ContextSyncState.loadingLocal;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      final scopedKey = _prefsKeyFor(uid);
      String? value = prefs.getString(scopedKey);
      if (value == null && prefs.containsKey(_legacyPrefsKey)) {
        // One-time migration: attribute the legacy global context to the first
        // account that loads after the update, then drop the legacy key.
        value = prefs.getString(_legacyPrefsKey);
        if (value != null) {
          await prefs.setString(scopedKey, value);
        }
        await prefs.remove(_legacyPrefsKey);
      }
      // A newer auth event (sign-out / account switch) may have superseded this
      // load while we awaited prefs — its state must not be overwritten.
      if (uid != _uid) return;
      _context = value ?? '';
      _state = ContextSyncState.idle;
      _errorMessage = null;
    } catch (e) {
      if (uid != _uid) return;
      _state = ContextSyncState.error;
      _errorMessage = 'Failed to load local context: $e';
    }
    notifyListeners();
  }

  /// Fetch the currently stored context from Smarty over BLE.
  /// Falls back to the local cache if the device is not connected.
  Future<void> refreshFromDevice() async {
    if (!BleManager().isConnected) {
      _errorMessage = 'Smarty not connected — showing last saved context.';
      _state = ContextSyncState.idle;
      notifyListeners();
      return;
    }

    _state = ContextSyncState.fetchingFromDevice;
    _errorMessage = null;
    notifyListeners();

    try {
      final remote = await BleManager().readUserContext();
      if (remote != null) {
        _context = remote;
        await _writeLocalCache(remote);
        _lastSyncedAt = DateTime.now();
      }
      _state = ContextSyncState.idle;
    } catch (e) {
      _state = ContextSyncState.error;
      _errorMessage = 'Failed to read from Smarty: $e';
    }
    notifyListeners();
  }

  /// Save the new context to Smarty over BLE and to the local cache.
  Future<bool> save(String newContext) async {
    if (_uid == null) {
      // The context page requires auth, so this shouldn't happen — but never
      // fall back to writing a device-global key.
      _state = ContextSyncState.error;
      _errorMessage = 'Not signed in.';
      notifyListeners();
      return false;
    }

    _state = ContextSyncState.saving;
    _errorMessage = null;
    notifyListeners();

    if (!BleManager().isConnected) {
      // Still persist locally so the user doesn't lose their edit.
      await _writeLocalCache(newContext);
      _context = newContext;
      _state = ContextSyncState.error;
      _errorMessage = 'Smarty not connected — saved locally only.';
      notifyListeners();
      return false;
    }

    try {
      final ok = await BleManager().writeUserContext(newContext);
      if (!ok) {
        _state = ContextSyncState.error;
        _errorMessage = 'Smarty rejected the write.';
        notifyListeners();
        return false;
      }
      await _writeLocalCache(newContext);
      _context = newContext;
      _lastSyncedAt = DateTime.now();
      _state = ContextSyncState.idle;
      notifyListeners();
      return true;
    } catch (e) {
      _state = ContextSyncState.error;
      _errorMessage = 'Failed to save to Smarty: $e';
      notifyListeners();
      return false;
    }
  }

  Future<void> _writeLocalCache(String value) async {
    final uid = _uid;
    if (uid == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKeyFor(uid), value);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('UserContextProvider: failed to write local cache: $e');
      }
    }
  }

  @override
  void dispose() {
    // The root provider isn't disposed in practice; this is for correctness.
    _authSub?.cancel();
    super.dispose();
  }
}

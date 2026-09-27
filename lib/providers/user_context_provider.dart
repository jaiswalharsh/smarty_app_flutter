import 'dart:async';
import 'dart:convert';

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

/// Outcome of [UserContextProvider.save].
enum ContextSaveResult {
  /// Written to Smarty (and cached locally).
  sent,

  /// Smarty was out of reach: kept on the phone and marked pending; it is
  /// pushed automatically the next time Smarty connects. A success, not an
  /// error, from the parent's point of view.
  savedPendingSync,

  /// Nothing was sent; [UserContextProvider.errorMessage] says why.
  failed,
}

class UserContextProvider with ChangeNotifier {
  // Legacy device-global key (pre per-user scoping). Kept only for one-time
  // migration into the uid-scoped key — one parent's child profile must not
  // leak to another account on a shared phone.
  static const String _legacyPrefsKey = 'user_context';
  static String _prefsKeyFor(String uid) => 'user_context_$uid';
  // Set when an edit was saved locally but never reached the toy (it was
  // offline). While set, the local value is authoritative over the toy's.
  static String _pendingKeyFor(String uid) => 'user_context_pending_sync_$uid';

  /// Every SharedPreferences key this provider keeps for the account [uid]
  /// (used when the account is deleted).
  static List<String> accountPrefsKeys(String uid) =>
      [_prefsKeyFor(uid), _pendingKeyFor(uid)];

  String _context = '';
  ContextSyncState _state = ContextSyncState.idle;
  String? _errorMessage;
  String? _infoMessage;
  DateTime? _lastSyncedAt;
  bool _pendingSync = false;

  String? _uid;
  StreamSubscription<User?>? _authSub;
  // Watches BleManager.phase so a pending (offline) edit is pushed the moment
  // Smarty reaches ToyPhase.connected (characteristics cached, ready to write).
  bool _phaseListening = false;
  ToyPhase? _lastPhase;
  Future<void>? _refreshInFlight;

  // Parent-facing messages (no bytes, encodings, or raw errors).
  static const String tooLongMessage =
      "That's a bit too long — please shorten it.";
  static const String loadLocalFailedMessage =
      "Couldn't open your saved notes. Please try again.";
  static const String readFailedMessage =
      "Couldn't get the notes from Smarty. Make sure it's on and nearby.";
  static const String sendFailedMessage =
      "Couldn't send this to Smarty. Make sure it's on and nearby, then try "
      "again.";
  static const String savedPendingMessage =
      "Saved. We'll send it to Smarty next time it's nearby.";
  static const String offlineMessage =
      "Smarty is off or out of reach. You can still edit — we'll send "
      "changes when it's back.";
  static const String signInAgainMessage = 'Please sign in again.';

  String get context => _context;
  ContextSyncState get state => _state;
  String? get errorMessage => _errorMessage;
  /// Non-error status text (e.g. "Smarty is off…"), shown in neutral colours.
  String? get infoMessage => _infoMessage;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  /// True when the current context was saved locally while Smarty was offline
  /// and has not been pushed to the toy yet.
  bool get hasPendingSync => _pendingSync;
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
    if (!_phaseListening) {
      _phaseListening = true;
      _lastPhase = BleManager().phase.value;
      BleManager().phase.addListener(_onPhaseChanged);
    }
  }

  // Push a pending (offline) edit as soon as Smarty comes back, whether or not
  // the profile page is open. `connected` is only reached once initialize()
  // has cached the characteristics, so the write can go out right away.
  void _onPhaseChanged() {
    final phase = BleManager().phase.value;
    final reconnected =
        phase == ToyPhase.connected && _lastPhase != ToyPhase.connected;
    _lastPhase = phase;
    if (!reconnected || _uid == null || !_pendingSync || isBusy) return;
    unawaited(refreshFromDevice());
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
      _infoMessage = null;
      _lastSyncedAt = null;
      _pendingSync = false;
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
      final pending = prefs.getBool(_pendingKeyFor(uid)) ?? false;
      // A newer auth event (sign-out / account switch) may have superseded this
      // load while we awaited prefs — its state must not be overwritten.
      if (uid != _uid) return;
      _context = value ?? '';
      _pendingSync = pending;
      _state = ContextSyncState.idle;
      _errorMessage = null;
    } catch (e) {
      debugPrint('UserContextProvider: failed to load local context: $e');
      if (uid != _uid) return;
      _state = ContextSyncState.error;
      _errorMessage = loadLocalFailedMessage;
    }
    notifyListeners();
  }

  /// Fetch the currently stored context from Smarty over BLE.
  /// Falls back to the local cache if the device is not connected.
  /// If a local edit is pending sync, pushes it to Smarty instead of
  /// overwriting it with the toy's (older) value.
  ///
  /// Concurrent calls (page open + reconnect) share one in-flight refresh.
  Future<void> refreshFromDevice() {
    return _refreshInFlight ??=
        _refreshFromDeviceImpl().whenComplete(() => _refreshInFlight = null);
  }

  Future<void> _refreshFromDeviceImpl() async {
    // Capture the account now so a switch mid-read can't cache under the
    // wrong user.
    final uid = _uid;
    if (!BleManager().isConnected) {
      _errorMessage = null;
      _infoMessage = offlineMessage;
      _state = ContextSyncState.idle;
      notifyListeners();
      return;
    }
    _infoMessage = null;

    if (uid != null && _pendingSync) {
      // The local edit never reached the toy — push it (save() clears the
      // flag on success and keeps it, with an error state, on failure).
      await save(_context);
      return;
    }

    _state = ContextSyncState.fetchingFromDevice;
    _errorMessage = null;
    notifyListeners();

    try {
      final remote = await BleManager().readUserContext();
      // A sign-out / account switch superseded this read — its state wins.
      if (uid != _uid) return;
      if (remote == null) {
        _state = ContextSyncState.error;
        _errorMessage = readFailedMessage;
      } else {
        _context = remote;
        if (uid != null) await _writeLocalCache(uid, remote);
        _lastSyncedAt = DateTime.now();
        _state = ContextSyncState.idle;
      }
    } catch (e) {
      debugPrint('UserContextProvider: failed to read from Smarty: $e');
      if (uid != _uid) return;
      _state = ContextSyncState.error;
      _errorMessage = readFailedMessage;
    }
    notifyListeners();
  }

  /// Save the new context to Smarty over BLE and to the local cache.
  Future<ContextSaveResult> save(String newContext) async {
    // Capture the account now so a switch mid-save can't cache under the
    // wrong user.
    final uid = _uid;
    if (uid == null) {
      // The context page requires auth, so this shouldn't happen — but never
      // fall back to writing a device-global key.
      _state = ContextSyncState.error;
      _errorMessage = signInAgainMessage;
      notifyListeners();
      return ContextSaveResult.failed;
    }

    // Reject up front what the toy can't store, so an oversize edit is never
    // parked as a pending sync that can never succeed.
    final int bytes = utf8.encode(newContext).length;
    if (bytes > BleManager().userContextMaxBytes) {
      debugPrint('UserContextProvider: context too long ($bytes bytes)');
      _state = ContextSyncState.error;
      _errorMessage = tooLongMessage;
      notifyListeners();
      return ContextSaveResult.failed;
    }

    _state = ContextSyncState.saving;
    _errorMessage = null;
    _infoMessage = null;
    notifyListeners();

    if (!BleManager().isConnected) {
      // Still persist locally so the user doesn't lose their edit, and mark it
      // pending so the next refresh pushes it instead of overwriting it.
      await _writeLocalCache(uid, newContext);
      await _setPendingSync(uid, true);
      if (uid != _uid) return ContextSaveResult.failed;
      _context = newContext;
      _state = ContextSyncState.idle;
      _errorMessage = null;
      _infoMessage = savedPendingMessage;
      notifyListeners();
      return ContextSaveResult.savedPendingSync;
    }

    try {
      final ok = await BleManager().writeUserContext(newContext);
      if (!ok) {
        debugPrint('UserContextProvider: Smarty did not accept the write');
        if (uid != _uid) return ContextSaveResult.failed;
        _state = ContextSyncState.error;
        _errorMessage = sendFailedMessage;
        notifyListeners();
        return ContextSaveResult.failed;
      }
      await _writeLocalCache(uid, newContext);
      await _setPendingSync(uid, false);
      if (uid != _uid) return ContextSaveResult.sent;
      _context = newContext;
      _lastSyncedAt = DateTime.now();
      _state = ContextSyncState.idle;
      notifyListeners();
      return ContextSaveResult.sent;
    } catch (e) {
      debugPrint('UserContextProvider: failed to save to Smarty: $e');
      if (uid != _uid) return ContextSaveResult.failed;
      _state = ContextSyncState.error;
      _errorMessage = sendFailedMessage;
      notifyListeners();
      return ContextSaveResult.failed;
    }
  }

  Future<void> _writeLocalCache(String uid, String value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKeyFor(uid), value);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('UserContextProvider: failed to write local cache: $e');
      }
    }
  }

  // Persist the pending-sync flag for [uid]; mirror it in memory only if that
  // account is still the signed-in one.
  Future<void> _setPendingSync(String uid, bool pending) async {
    if (uid == _uid) _pendingSync = pending;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (pending) {
        await prefs.setBool(_pendingKeyFor(uid), true);
      } else {
        await prefs.remove(_pendingKeyFor(uid));
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('UserContextProvider: failed to persist pending flag: $e');
      }
    }
  }

  @override
  void dispose() {
    // The root provider isn't disposed in practice; this is for correctness.
    _authSub?.cancel();
    if (_phaseListening) {
      BleManager().phase.removeListener(_onPhaseChanged);
      _phaseListening = false;
    }
    super.dispose();
  }
}

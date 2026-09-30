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
  /// [readFromToy], [writeToToy] and [isToyConnected] replace the Bluetooth
  /// calls in tests; the app uses the defaults ([BleManager]).
  UserContextProvider({
    @visibleForTesting Future<String?> Function()? readFromToy,
    @visibleForTesting Future<bool> Function(String context)? writeToToy,
    @visibleForTesting bool Function()? isToyConnected,
    @visibleForTesting this.toyReadTimeout = defaultToyReadTimeout,
  })  : _readFromToy = readFromToy ?? (() => BleManager().readUserContext()),
        _writeToToy =
            writeToToy ?? ((context) => BleManager().writeUserContext(context)),
        _isToyConnected = isToyConnected ?? (() => BleManager().isConnected);

  /// How long to wait for Smarty's copy before showing the phone's own.
  static const Duration defaultToyReadTimeout = Duration(seconds: 5);

  final Duration toyReadTimeout;
  final Future<String?> Function() _readFromToy;
  final Future<bool> Function(String context) _writeToToy;
  final bool Function() _isToyConnected;

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
  /// Non-error status text (e.g. "Smarty is off…" — also after Smarty's copy
  /// couldn't be read in time), shown in neutral colours.
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
    // happens here (via _onAccountChanged) without a separate first read.
    _authSub ??= FirebaseAuth.instance
        .authStateChanges()
        .listen((user) => _onAccountChanged(user?.uid));
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

  /// Switch to the account [uid] (null = signed out) as a sign-in would — for
  /// tests, which have no sign-in service.
  @visibleForTesting
  Future<void> debugSetAccount(String? uid) => _onAccountChanged(uid);

  // Reload (or clear) in-memory state to match the signed-in account so a
  // second parent on the same phone never inherits the first parent's context
  // — not even while the new account's copy is still loading.
  Future<void> _onAccountChanged(String? newUid) async {
    if (newUid == _uid) return;
    _uid = newUid;
    _context = '';
    _errorMessage = null;
    _infoMessage = null;
    _lastSyncedAt = null;
    _pendingSync = false;

    if (_uid == null) {
      _state = ContextSyncState.idle;
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

  /// Fetch the currently stored context from Smarty over BLE (waiting at
  /// most [toyReadTimeout]). Falls back to the local cache — with
  /// [infoMessage] set to [offlineMessage] — if the device is not connected
  /// or its copy couldn't be read in time.
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
    if (!_isToyConnected()) {
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

    String? remote;
    try {
      remote = await _readFromToy().timeout(toyReadTimeout);
    } catch (e) {
      // Includes the timeout: a toy that doesn't answer in time counts as
      // out of reach, and the phone's copy is shown instead.
      debugPrint('UserContextProvider: failed to read from Smarty: $e');
      remote = null;
    }
    // A sign-out / account switch superseded this read — its state wins.
    if (uid != _uid) return;
    if (remote == null) {
      // Keep the phone's copy (this account's cache) and say Smarty is out
      // of reach — edits made now are sent when it's back.
      _state = ContextSyncState.idle;
      _infoMessage = offlineMessage;
    } else {
      _context = remote;
      if (uid != null) await _writeLocalCache(uid, remote);
      if (uid != _uid) return;
      _lastSyncedAt = DateTime.now();
      _state = ContextSyncState.idle;
    }
    notifyListeners();
  }

  /// Whether to send this phone's copy of the child's profile ([profile]) to
  /// a toy that was just linked to the account ([signedIn]): whenever there
  /// is one that the toy can hold ([maxBytes], UTF-8). A toy that needed
  /// linking was new, reset by hand, or erased itself after being removed
  /// from an account — its profile is empty, or not this family's — so the
  /// account's copy is the one that counts. Pure.
  static bool shouldResendAfterLink({
    required bool signedIn,
    required String profile,
    required int maxBytes,
  }) =>
      signedIn &&
      profile.trim().isNotEmpty &&
      utf8.encode(profile).length <= maxBytes;

  /// The toy was just linked to this account (setup's link step): send it
  /// the child's profile this phone keeps for the account, when
  /// [shouldResendAfterLink]. It is marked pending first — the local copy
  /// then wins over the toy's — so if Smarty isn't reachable now (the write
  /// fails, the link just dropped) it goes out the next time Smarty
  /// connects. Nothing happens without a profile on this phone (e.g. a new
  /// phone: the profile page then reads Smarty's copy).
  Future<void> resendAfterLink() async {
    final String? uid = _uid;
    if (!shouldResendAfterLink(
      signedIn: uid != null,
      profile: _context,
      maxBytes: BleManager().userContextMaxBytes,
    )) {
      return;
    }
    debugPrint('UserContextProvider: sending the profile to the newly linked '
        'Smarty');
    await _setPendingSync(uid!, true);
    if (uid != _uid) return;
    notifyListeners();
    // Connected: pushes the pending copy now (save() clears the flag once
    // Smarty has it). Not connected: stays pending for the next connect.
    await refreshFromDevice();
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

    if (!_isToyConnected()) {
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
      final ok = await _writeToToy(newContext);
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

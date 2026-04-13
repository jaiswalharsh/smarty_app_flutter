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
  static const String _prefsKey = 'user_context';

  String _context = '';
  ContextSyncState _state = ContextSyncState.idle;
  String? _errorMessage;
  DateTime? _lastSyncedAt;

  String get context => _context;
  ContextSyncState get state => _state;
  String? get errorMessage => _errorMessage;
  DateTime? get lastSyncedAt => _lastSyncedAt;
  bool get isBusy =>
      _state == ContextSyncState.loadingLocal ||
      _state == ContextSyncState.fetchingFromDevice ||
      _state == ContextSyncState.saving;

  Future<void> init() async {
    _state = ContextSyncState.loadingLocal;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      _context = prefs.getString(_prefsKey) ?? '';
      _state = ContextSyncState.idle;
      _errorMessage = null;
    } catch (e) {
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
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, value);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('UserContextProvider: failed to write local cache: $e');
      }
    }
  }
}

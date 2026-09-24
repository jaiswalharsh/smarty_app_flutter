import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../dev_config.dart';
import '../utils/wifi_utils.dart';
import 'ble_service.dart';

/// Outcome of a Wi-Fi provisioning attempt, derived from the device's own status
/// characteristic — NOT merely from the BLE credential write being acknowledged.
enum WifiProvisionResult {
  connected,        // device reported it joined the target SSID (got an IP)
  wrongPassword,    // device reported "Auth Failed"
  failed,           // device reported a non-auth connection failure
  bleDisconnected,  // the BLE link to the toy dropped — a join result can't arrive
  timeout,          // no definitive status within the wait window
  writeError,       // couldn't even deliver the credentials over BLE
}

/// Where the app stands with the parent's saved toy. The single source of truth
/// for every "is Smarty there?" UI — screens render from [BleManager.phase]
/// instead of running their own connect logic.
///
/// Firmware facts this relies on (bt_setup.c): a bonded toy advertises
/// continuously whenever it is on and not connected, so a short scan that sees
/// nothing means off / out of range / connected to another phone — we can't
/// tell which, so [notNearby] must never claim "the toy is off". Entering
/// pairing mode wipes the toy's bonds, which surfaces here as [pairingBroken].
enum ToyPhase {
  /// Signed out, or no toy saved for this account. Offer setup.
  noToy,

  /// A toy is saved but the phone's Bluetooth is off (or unavailable).
  /// Never presented as "the toy is off".
  bluetoothOff,

  /// A toy is saved but the app isn't allowed to use Bluetooth.
  needsPermission,

  /// Short (≤3 s) check for the saved toy is running. Also shown while the
  /// Bluetooth adapter hasn't reported a definite state yet.
  probing,

  /// Saved toy not seen. A pending background connect is armed and will
  /// connect by itself as soon as the toy advertises — no user action needed.
  notNearby,

  /// Link is coming up / the Smarty service is being set up.
  connecting,

  /// The phone holds a pairing the toy no longer knows (the toy was put in
  /// pairing mode, or set up with another phone). iOS: the parent must forget
  /// Smarty in Settings → Bluetooth. Android: the bond is removed
  /// automatically; the next attempt pairs fresh. Never auto-retried.
  pairingBroken,

  /// Fully set up: characteristics cached, status monitoring running.
  connected,
}

/// Why a connect/initialize attempt failed. See [ConnectException] and
/// [BleManager.classifyConnectError].
enum ConnectFailure {
  /// The phone's stored pairing is stale (toy wiped its bonds / was set up
  /// with another phone). Recovery: forget in iOS Settings; removeBond on
  /// Android (done automatically by BleManager).
  pairingBroken,

  /// The attempt was cancelled (by the app itself, or the user declined).
  cancelledByUser,

  /// Timed out / not found / generic Android 133 — most likely out of range
  /// or off.
  outOfRange,

  /// Something answered but it has no usable Smarty service.
  notSmarty,

  /// The phone's Bluetooth is off.
  bluetoothOff,

  /// The app lacks Bluetooth permission.
  needsPermission,

  /// Anything else.
  unknown,
}

/// Thrown by [BleManager.initialize] and [BleManager.connectAndInitialize].
/// [kind] is what the UI should branch on; [cause] is the underlying error, for
/// logging only — never show it to the parent.
class ConnectException implements Exception {
  final ConnectFailure kind;
  final Object? cause;
  const ConnectException(this.kind, [this.cause]);

  @override
  String toString() => 'ConnectException(${kind.name}): $cause';
}

// A singleton class to manage BLE connections and data
class BleManager {
  // Legacy device-global persistence keys (pre per-user scoping). Kept only for
  // one-time migration into the uid-scoped keys below — a second account on the
  // same phone must not inherit the first account's saved toy.
  static const String _legacyDeviceIdKey = 'smarty_saved_device_id';
  static const String _legacyDeviceNameKey = 'smarty_saved_device_name';
  String _deviceIdKeyFor(String uid) => 'smarty_saved_device_id_$uid';
  String _deviceNameKeyFor(String uid) => 'smarty_saved_device_name_$uid';
  // Last Wi-Fi name is per TOY (keyed by its BLE id), so a newly set-up toy
  // never inherits the previous toy's network name. The per-account key it
  // used to live under is migrated once, then removed.
  String _lastWifiKeyFor(String toyId) => 'smarty_last_wifi_toy_$toyId';
  String _legacyLastWifiKeyFor(String uid) => 'smarty_last_wifi_$uid';
  // Local "linked" record for firmware that can't report `registered`, keyed
  // by the toy's own id (ab06). Same key the setup page has always written.
  static String _registeredRecordKey(String toyDeviceId) =>
      'device_registered_$toyDeviceId';

  // Current Firebase uid, or null when signed out. Firebase.initializeApp is
  // awaited in main() before runApp, so this is safe to read on demand.
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // Singleton instance
  static final BleManager _instance = BleManager._internal();

  // Factory constructor
  factory BleManager() {
    return _instance;
  }

  // Private constructor
  BleManager._internal();

  /// The 16-bit Smarty service every toy advertises (bt_setup.c).
  static final Guid smartyServiceGuid = Guid("abcd");

  /// How long a launch/resume/"Check again" probe scans for the saved toy. A
  /// bonded toy advertises every 160–320 ms, so 3 s is ~10 chances.
  static const Duration probeScanDuration = Duration(seconds: 3);

  /// Timeout for a DIRECT connect once the probe has seen the toy advertise.
  static const Duration directConnectTimeout = Duration(seconds: 10);

  // Connected device
  BluetoothDevice? _connectedDevice;

  // In-flight initialize() and the device it targets. Concurrent callers for
  // the same device share this future instead of returning before the
  // characteristics are cached.
  Future<void>? _initializeFuture;
  BluetoothDevice? _initializingDevice;

  // ---- Connection-phase state machine (see watchSavedToy) -------------------

  final ValueNotifier<ToyPhase> _phase = ValueNotifier(ToyPhase.probing);

  /// Current [ToyPhase]. Every transition in BleManager goes through here, so
  /// UIs can simply `ValueListenableBuilder` on it.
  ValueListenable<ToyPhase> get phase => _phase;

  // Bumped by forgetToy()/disconnectAndReset(): async steps started under an
  // older generation abandon themselves instead of resurrecting a connection
  // the parent just forgot or signed out of.
  int _sessionGen = 0;

  // Single-flight watchSavedToy(), tagged with the session generation it was
  // started under so a run from before sign-out/sign-in is never reused.
  Future<void>? _watchFuture;
  int _watchGen = -1;

  // BLE id of a saved toy whose pairing is known broken and not yet repaired
  // (set on pairingBroken; cleared by a successful initialize() or
  // forgetToy()). While it matches the toy being watched, "not seen" stays
  // [ToyPhase.pairingBroken] instead of [ToyPhase.notNearby], and no
  // background autoConnect is armed: after the parent resets the toy its
  // bonds are gone, and once its 30-second pairing window closes it neither
  // advertises nor accepts stale keys — "it'll connect by itself" would be a
  // dead end. Kept per toy id (not a bare bool) so it survives a sign-out /
  // sign-in of the same toy but never leaks onto another account's toy.
  String? _repairToyId;
  bool _needsRepairFor(BluetoothDevice device) =>
      _repairToyId != null && _repairToyId == device.remoteId.str;

  // Device a direct connect() is in flight for (connectAndInitialize). Lets
  // forgetToy()/disconnectAndReset() cancel it — _connectedDevice is still
  // null at that point.
  BluetoothDevice? _connectingDevice;

  // Launch/resume probe scan ownership (see _probeScan / cancelProbe).
  int _probeToken = 0;
  StreamSubscription<List<ScanResult>>? _probeSub;
  Completer<bool>? _probeFound;

  // The device whose background autoConnect we armed, its connection-state
  // listener, and the backoff re-arm timer after a failed attempt.
  BluetoothDevice? _armedDevice;
  StreamSubscription<BluetoothConnectionState>? _pendingSub;
  Timer? _rearmTimer;
  int _consecutiveFailures = 0;

  // Adapter-state watch: re-runs watchSavedToy when Bluetooth comes back on.
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  bool _waitingForAdapter = false;

  // Quick-drop heuristic for a stale pairing (see _registerQuickDrop).
  DateTime? _linkUpAt;
  int _quickDrops = 0;
  Timer? _stableLinkTimer;

  // Cached saved toy for the signed-in account (null = none / not loaded).
  String? _savedToyId;
  String? _savedToyName;

  /// BLE id (remoteId string) of this account's saved toy, or null when none
  /// is saved or it hasn't been loaded yet ([watchSavedToy] loads it).
  String? get savedToyId => _savedToyId;

  /// Display name of the saved (or connected) toy, e.g. "Smarty-AB12", or
  /// null when no toy is saved. Use [toyDisplayName]/[toyCode] to render it.
  String? get savedToyName {
    final live = _connectedDevice?.platformName;
    if (live != null && live.isNotEmpty) return live;
    return _savedToyName;
  }

  /// Parent-facing name for a raw advertised name: "Smarty-AB12" → "Smarty".
  static String toyDisplayName(String? raw) {
    if (raw == null || raw.trim().isEmpty) return 'Smarty';
    final m = RegExp(r'^(smarty)[-_ ]?[0-9a-z]{4}$', caseSensitive: false)
        .firstMatch(raw.trim());
    return m != null ? 'Smarty' : raw.trim();
  }

  /// The 4-character code in "Smarty-AB12" ("AB12"), or null if the name
  /// doesn't carry one. Shown only as small secondary text.
  static String? toyCode(String? raw) {
    if (raw == null) return null;
    final m = RegExp(r'^smarty[-_ ]?([0-9a-z]{4})$', caseSensitive: false)
        .firstMatch(raw.trim());
    return m?.group(1)?.toUpperCase();
  }

  /// Largest value the firmware stores per characteristic (CHAR_VAL_LEN_MAX in
  /// bt_setup.c). Writes above the MTU go out as BLE long (prepared) writes,
  /// which the firmware supports, so this is the real limit for user context.
  static const int userContextMaxBytes = 500;

  /// Usable payload for a single acknowledged characteristic write, in UTF-8
  /// bytes. Long writes make this independent of the negotiated MTU.
  int get maxWritePayloadBytes => userContextMaxBytes;

  // Cached services
  BluetoothService? _smartyService;

  // Cached characteristics
  BluetoothCharacteristic? _statusCharacteristic;
  BluetoothCharacteristic? _wifiScanCharacteristic;
  BluetoothCharacteristic? _wifiCredsCharacteristic;
  BluetoothCharacteristic? _userDataCharacteristic;
  BluetoothCharacteristic? _deviceSecretCharacteristic;
  BluetoothCharacteristic? _deviceInfoCharacteristic;

  // Connection state subscription
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  // Status notification subscription
  StreamSubscription<List<int>>? _statusNotificationSubscription;

  // Fires when the peripheral sends a GATT "Service Changed" indication
  // (e.g. after a firmware reflash, or the post-bond Service Changed this
  // device sends). Android caches services for bonded devices, so we must
  // re-discover to pick up characteristics the cached table was missing.
  StreamSubscription<void>? _servicesResetSubscription;

  // Status information
  String _connectedWifi = "Unknown";
  int _batteryLevel = 0;
  // Whether the toy holds its backend secret — a DERIVED value: the toy's own
  // status field (`"registered"`) wins; firmware that predates that field
  // falls back to a local record kept per toy id (see [refreshRegistered]).
  // null = unknown (not read yet, or the toy's id couldn't be read).
  final ValueNotifier<bool?> _registered = ValueNotifier(null);
  bool? _statusRegistered; // from the status JSON; null = not reported
  bool? _localRegistered; // local record (old firmware); null = not loaded
  Future<void>? _localRegLoad;
  // ab06 id per BLE id, filled by readDeviceId(). Survives link drops so
  // markRegistered() can write the local record even while reconnecting.
  final Map<String, String> _toyDeviceIdByRemote = {};
  // Last real SSID the toy reported (or we provisioned), so "Auth Failed" can
  // name the network. Persisted per toy; [_lastWifiToyId] is the toy it
  // belongs to.
  String? _lastKnownWifiName;
  String? _lastWifiToyId;

  // Stream controllers for status updates
  final _wifiStatusController = StreamController<String>.broadcast();
  final _batteryStatusController = StreamController<int>.broadcast();
  final _wifiStatusMessageController = StreamController<String>.broadcast();

  // Getters
  BluetoothDevice? get connectedDevice => _connectedDevice;
  BluetoothService? get smartyService => _smartyService;
  String get connectedWifi => _connectedWifi;
  int get batteryLevel => _batteryLevel;

  /// Whether the toy holds its backend secret. The toy's status JSON
  /// (`"registered"`) wins; for firmware without that field it comes from a
  /// local record kept per toy (written by [markRegistered]) — `false` when
  /// the toy's id is readable but no record exists. null = unknown (not read
  /// yet, or the id couldn't be read).
  bool? get registered => _registered.value;

  /// Listenable form of [registered] (fires on status updates, when the
  /// local record loads, and on [markRegistered]).
  ValueListenable<bool?> get registeredListenable => _registered;

  /// Same as [registered]; kept for existing callers.
  bool? get deviceRegistered => _registered.value;

  void _updateRegistered() {
    _registered.value = _statusRegistered ?? _localRegistered;
  }

  /// Call after a successful device-secret write: the firmware does not
  /// re-notify status on that write, so flip the flag ourselves, and keep the
  /// local record (used by firmware that can't report the flag).
  void markRegistered() {
    if (_statusRegistered != null) _statusRegistered = true;
    _localRegistered = true;
    _updateRegistered();
    unawaited(_persistRegistered());
  }

  Future<void> _persistRegistered() async {
    final String? remote = _connectedDevice?.remoteId.str ?? _savedToyId;
    String? id = remote == null ? null : _toyDeviceIdByRemote[remote];
    if (!_idReadable(id) && _connectedDevice != null) {
      id = await readDeviceId();
    }
    if (!_idReadable(id)) {
      debugPrint("⚠️ BleManager: couldn't record the link locally (no toy id)");
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_registeredRecordKey(id!), true);
    } catch (e) {
      debugPrint("⚠️ BleManager: couldn't persist the link record: $e");
    }
  }

  static bool _idReadable(String? id) =>
      id != null && id.trim().isNotEmpty && id != '{}';

  /// Make [registered] as definite as possible for the connected toy and
  /// return it: reads the status if the toy hasn't reported yet, and for
  /// firmware without the `registered` field loads the local record keyed by
  /// the toy's id. Returns null if it still can't tell (or nothing is
  /// connected).
  Future<bool?> refreshRegistered() async {
    final device = _connectedDevice;
    if (device == null) return _registered.value;
    if (_statusRegistered == null) {
      await readStatusUpdate();
    }
    if (_statusRegistered != null || _connectedDevice != device) {
      return _registered.value;
    }
    await (_localRegLoad ??= _loadLocalRegistered(device)
        .whenComplete(() => _localRegLoad = null));
    return _registered.value;
  }

  Future<void> _loadLocalRegistered(BluetoothDevice device) async {
    if (_localRegistered != null) return;
    String? id = _toyDeviceIdByRemote[device.remoteId.str];
    // readDeviceId retries internally too; ~2 s worst case in total.
    for (int attempt = 0; attempt < 3 && !_idReadable(id); attempt++) {
      id = await readDeviceId();
      if (_connectedDevice != device || _statusRegistered != null) return;
    }
    if (!_idReadable(id)) return; // can't tell — stays unknown
    final bool linked;
    try {
      final prefs = await SharedPreferences.getInstance();
      linked = prefs.getBool(_registeredRecordKey(id!)) ?? false;
    } catch (e) {
      debugPrint("⚠️ BleManager: couldn't read the link record: $e");
      return;
    }
    if (_connectedDevice != device || _localRegistered != null) return;
    _localRegistered = linked;
    _updateRegistered();
  }

  String? get _currentToyId => _connectedDevice?.remoteId.str ?? _savedToyId;

  /// Last real Wi-Fi network name the current toy reported or was given, or
  /// null. Never another toy's.
  String? get lastKnownWifiName =>
      _lastWifiToyId != null && _lastWifiToyId == _currentToyId
          ? _lastKnownWifiName
          : null;

  Stream<String> get wifiStatusStream => _wifiStatusController.stream;
  Stream<int> get batteryStatusStream => _batteryStatusController.stream;
  Stream<String> get wifiStatusMessageStream =>
      _wifiStatusMessageController.stream;
  bool get isConnected => _connectedDevice != null;
  // Non-connected statuses from ESP32 (wifi_config.c) and Flutter internals
  static const _nonConnectedStatuses = {
    '', 'Unknown', 'NotConnected', 'Initializing',
    'Auth Failed', 'Connection Failed', 'No credentials', 'Reconnecting',
  };
  bool get isWifiConnected => isWifiConnectedStatus(_connectedWifi);

  /// Whether a raw `wifi` status value means "joined a network" (a real SSID
  /// rather than a status token). Pure.
  static bool isWifiConnectedStatus(String wifi) =>
      wifi.trim().isNotEmpty &&
      !_nonConnectedStatuses.contains(wifi) &&
      !wifi.contains('Failed');

  void _setPhase(ToyPhase next) {
    if (_phase.value == next) return;
    debugPrint("🧭 BleManager: phase ${_phase.value.name} → ${next.name}");
    _phase.value = next;
  }

  /// Initialize the manager with an already-connected [device]: discover the
  /// Smarty service, cache characteristics, and start status/connection
  /// monitoring.
  ///
  /// Contract: completes normally only when the required characteristics are
  /// cached; [phase] is then [ToyPhase.connected] and the device is saved as
  /// this account's toy. On failure it throws a [ConnectException] (kind from
  /// [classifyConnectError] — e.g. [ConnectFailure.notSmarty] when the Smarty
  /// service is missing, [ConnectFailure.pairingBroken] for a stale bond),
  /// disconnects the link, resets the manager state, and has already moved
  /// [phase] to the matching recovery state (pairingBroken / bluetoothOff /
  /// needsPermission / notNearby with a background reconnect armed, or noToy).
  /// Concurrent calls for the same device share one attempt; a call for a
  /// different device waits for the in-flight attempt to settle first. If a
  /// different toy is currently connected, its link is dropped first (it
  /// would otherwise stay connected with nobody listening).
  Future<void> initialize(BluetoothDevice device) =>
      _initialize(device, _sessionGen);

  // [gen] is the CALLER's session generation (e.g. taken before its
  // connect()), so a sign-out/forget during the caller's own awaits aborts
  // this attempt too.
  Future<void> _initialize(BluetoothDevice device, int gen) {
    final inFlight = _initializeFuture;
    if (inFlight != null) {
      if (_initializingDevice == device) return inFlight;
      return inFlight
          .catchError((_) {})
          .then((_) => _initialize(device, gen));
    }

    // Already fully initialized with this device (characteristics cached).
    if (_connectedDevice == device && _statusCharacteristic != null) {
      return Future.value();
    }

    _initializingDevice = device;
    return _initializeFuture = _initializeImpl(device, gen).whenComplete(() {
      _initializeFuture = null;
      _initializingDevice = null;
    });
  }

  Future<void> _initializeImpl(BluetoothDevice device, int gen) async {
    if (gen != _sessionGen) {
      // Forgotten / signed out before we even started: drop the caller's link
      // (unless it's somehow the live one) and don't touch shared state.
      if (_connectedDevice?.remoteId != device.remoteId) {
        try {
          await device.disconnect();
        } catch (_) {}
      }
      throw const ConnectException(ConnectFailure.cancelledByUser);
    }
    _linkUpAt ??= DateTime.now();
    _setPhase(ToyPhase.connecting);

    // Switching toys: drop the previous toy's link first. Reset FIRST so its
    // connection listener can't treat our own disconnect as a link loss (and
    // re-arm a reconnect to it).
    final old = _connectedDevice;
    if (old != null && old.remoteId != device.remoteId) {
      debugPrint("BleManager: switching toys — disconnecting ${old.remoteId.str}");
      _resetConnectionState();
      try {
        await old.disconnect();
      } catch (e) {
        debugPrint("⚠️ BleManager: Disconnecting previous toy failed: $e");
      }
    }

    // A background connect armed for a DIFFERENT toy (e.g. the parent is
    // setting up a new Smarty) must not hijack the link later.
    final armed = _armedDevice;
    if (armed != null && armed != device) {
      await _cancelPendingConnect(switchingTo: device);
    }

    try {
      _connectedDevice = device;
      _connectedWifi = "Unknown";
      // Fresh link: registration is re-learned from this toy's status (or
      // its local record) — never carried over from before.
      _statusRegistered = null;
      _localRegistered = null;
      _updateRegistered();
      debugPrint("🔄 BleManager: Initializing with device: ${device.platformName}");

      // Request larger MTU for WiFi scan chunks and JSON status notifications.
      // Android only — requestMtu always throws on iOS, which negotiates the
      // MTU itself. A failure here is not fatal: long writes still work.
      if (Platform.isAndroid) {
        try {
          await device.requestMtu(512);
          debugPrint("✅ BleManager: MTU negotiated");
        } catch (e) {
          debugPrint("⚠️ BleManager: MTU request failed: $e");
        }
      }

      // Trigger bonding on Android (prevents double pairing popup bug)
      // iOS handles bonding automatically when encrypted characteristics are accessed
      if (Platform.isAndroid) {
        try {
          await device.createBond();
          debugPrint("BleManager: Bond created/confirmed on Android");
        } catch (e) {
          debugPrint("BleManager: Bond creation skipped (may already be bonded): $e");
        }
      }

      // Discover services
      bool servicesReady = await _discoverServices();

      if (!servicesReady) {
        if (device.isDisconnected) {
          // The link died under discovery — not a "wrong device" verdict.
          throw StateError('Link dropped during service discovery');
        }
        debugPrint("❌ BleManager: Service discovery failed — required services/characteristics not found");
        throw const ConnectException(ConnectFailure.notSmarty);
      }

      // Enable status notifications and WAIT for the result: the firmware
      // starts encryption right after connect, so a stale pairing surfaces
      // here (insufficient authentication/encryption) rather than as a silent
      // background failure. Other errors stay non-fatal, as before — e.g. a
      // slow first-time pairing prompt must not abort setup.
      try {
        await _statusCharacteristic!.setNotifyValue(true);
      } catch (e) {
        if (classifyConnectError(e) == ConnectFailure.pairingBroken) rethrow;
        debugPrint("⚠️ BleManager: Enabling status notifications failed (non-fatal): $e");
      }
      _setupStatusUpdates();

      // Re-discover when the peripheral signals its GATT table changed. This
      // device sends a Service Changed indication right after bonding — which
      // arrives AFTER the discovery above — and again whenever the firmware is
      // reflashed. Without this, a stale/incomplete cached table (e.g. missing
      // the ab01 Wi-Fi scan characteristic) is never refreshed.
      _servicesResetSubscription?.cancel();
      _servicesResetSubscription = device.onServicesReset.listen((_) async {
        debugPrint("🔄 BleManager: Service Changed received — re-discovering services");
        final ok = await _discoverServices();
        if (ok && _statusCharacteristic != null) {
          _setupStatusUpdates();
        }
      });

      if (device.isDisconnected) {
        throw StateError('Link dropped during setup');
      }

      // Set up connection state monitoring
      _monitorDeviceConnection();

      if (gen != _sessionGen) {
        // Forgotten / signed out while we were setting up — and don't re-save
        // the toy the parent just forgot.
        throw const ConnectException(ConnectFailure.cancelledByUser);
      }

      // Persist device ID for auto-reconnect on next app launch
      try {
        await _saveDeviceId(device);
      } catch (e) {
        debugPrint("⚠️ BleManager: Failed to save device for auto-reconnect: $e");
      }

      _consecutiveFailures = 0;
      _repairToyId = null; // the pairing works again
      _rearmTimer?.cancel();
      _stableLinkTimer?.cancel();
      _stableLinkTimer = Timer(const Duration(seconds: 5), () {
        if (_connectedDevice == device && device.isConnected) _quickDrops = 0;
      });
      _setPhase(ToyPhase.connected);

      // First status read (notifications only carry changes). With the
      // account link on, also settle [registered] for firmware that can't
      // report it (local record by toy id).
      unawaited(DevConfig.linkingEnabled
          ? refreshRegistered().then((_) {})
          : readStatusUpdate());
    } catch (e) {
      // Classify BEFORE our own disconnect overwrites the disconnect reason.
      final ConnectException failure = e is ConnectException
          ? e
          : ConnectException(_classifyForDevice(e, device), e);
      debugPrint("❌ BleManager: initialize failed (${failure.kind.name}): $e");
      // Reset FIRST so the intentional disconnect below can't fire the
      // disconnect handler, then drop the link so a half-initialized device
      // isn't left connected. (disconnect() also clears a pending autoConnect;
      // _onConnectFailure re-arms it with backoff when appropriate.)
      _resetConnectionState();
      try {
        await device.disconnect();
      } catch (de) {
        debugPrint("⚠️ BleManager: Disconnect after failed initialize: $de");
      }
      if (_armedDevice == device) {
        _pendingSub?.cancel();
        _pendingSub = null;
        _armedDevice = null;
      }
      if (gen == _sessionGen) {
        await _onConnectFailure(device, failure);
      }
      throw failure;
    }
  }

  // Monitor device connection state
  void _monitorDeviceConnection() {
    final device = _connectedDevice;
    if (device == null) return;

    // Cancel any previous subscription to avoid listener accumulation
    _connectionStateSubscription?.cancel();

    _connectionStateSubscription = device.connectionState.listen((BluetoothConnectionState state) {
      debugPrint("💡 Device connection state changed: $state");

      if (state == BluetoothConnectionState.connected) {
        // When connected, ensure notifications are set up
        if (_statusCharacteristic != null) {
          _setupNotificationsIfNeeded();
        }
      } else if (state == BluetoothConnectionState.disconnected) {
        debugPrint("❌ Device disconnected from BLE manager");

        // Reset the device and service references
        _resetConnectionState();

        // Notify listeners about the disconnection (Wi-Fi pages resolve
        // pending waits on this). No snackbar: Home/Settings update in place
        // from [phase].
        _wifiStatusController.add("NotConnected");
        _wifiStatusMessageController.add("Device disconnected");

        unawaited(_onLinkLost(device));
      }
    });
  }

  // Reset the connection state when device is disconnected
  void _resetConnectionState() {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _statusNotificationSubscription?.cancel();
    _statusNotificationSubscription = null;
    _servicesResetSubscription?.cancel();
    _servicesResetSubscription = null;
    _stableLinkTimer?.cancel();
    _stableLinkTimer = null;
    _smartyService = null;
    _statusCharacteristic = null;
    _wifiScanCharacteristic = null;
    _wifiCredsCharacteristic = null;
    _userDataCharacteristic = null;
    _deviceSecretCharacteristic = null;
    _deviceInfoCharacteristic = null;
    _connectedWifi = "NotConnected";
    _statusRegistered = null;
    _localRegistered = null;
    _registered.value = null;
    _connectedDevice = null;
  }

  // Discover services and cache characteristics. Returns false if required
  // service or characteristics are missing.
  Future<bool> _discoverServices() async {
    if (_connectedDevice == null) return false;

    try {
      List<BluetoothService> services =
          await _connectedDevice!.discoverServices();
      _smartyService = BleService.findSmartyService(services);

      if (_smartyService == null) {
        debugPrint("❌ BleManager: Smarty service not found among ${services.length} services");
        return false;
      }

      // Cache characteristics
      _statusCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab04",
      );
      _wifiScanCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab01",
      );
      _wifiCredsCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab02",
      );
      _userDataCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab03",
      );
      _deviceSecretCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab05",
      );
      _deviceInfoCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab06",
      );

      debugPrint("📋 BleManager: Characteristics — "
          "status=${_statusCharacteristic != null ? 'OK' : 'MISSING'}, "
          "wifiScan=${_wifiScanCharacteristic != null ? 'OK' : 'MISSING'}, "
          "wifiCreds=${_wifiCredsCharacteristic != null ? 'OK' : 'MISSING'}, "
          "userData=${_userDataCharacteristic != null ? 'OK' : 'MISSING'}, "
          "deviceSecret=${_deviceSecretCharacteristic != null ? 'OK' : 'MISSING'}, "
          "deviceInfo=${_deviceInfoCharacteristic != null ? 'OK' : 'MISSING'}");

      // Require at least the status characteristic
      if (_statusCharacteristic == null) {
        debugPrint("❌ BleManager: Required status characteristic (ab04) not found");
        return false;
      }

      return true;
    } catch (e) {
      debugPrint("❌ BleManager: Error discovering services: $e");
      return false;
    }
  }

  // Set up status updates
  void _setupStatusUpdates() {
    if (_statusCharacteristic == null) return;

    try {
      // Enable notifications (initialize() normally already did, awaited)
      if (!_statusCharacteristic!.isNotifying) {
        _statusCharacteristic!.setNotifyValue(true).catchError((Object e) {
          debugPrint("❌ BleManager: Error enabling status notifications: $e");
          return false;
        });
      }

      // Cancel previous subscription to avoid accumulation
      _statusNotificationSubscription?.cancel();

      // Variables for debouncing
      String lastStatusString = "";
      DateTime lastUpdateTime = DateTime.now();

      // Listen for notifications
      _statusNotificationSubscription = _statusCharacteristic!.lastValueStream.listen(
        (value) {
          if (value.isEmpty) return;

          String statusString = utf8.decode(value, allowMalformed: true);

          // Debounce: Skip if this is the same status string received within the last 500ms
          if (statusString == lastStatusString &&
              DateTime.now().difference(lastUpdateTime).inMilliseconds < 500) {
            return;
          }

          // Update debounce tracking
          lastStatusString = statusString;
          lastUpdateTime = DateTime.now();

          debugPrint("📊 BleManager: Status notification received: $statusString");

          // Process status data
          _processStatusData(value);
        },
        onError: (error) {
          debugPrint("❌ BleManager: Status notification stream error: $error");
          _statusNotificationSubscription = null;
        },
        onDone: () {
          _statusNotificationSubscription = null;
        },
      );

      // Notifications will emit the current value automatically — no explicit read needed
    } catch (e) {
      debugPrint("❌ BleManager: Error setting up status updates: $e");
    }
  }

  // Read status update from the device
  Future<void> readStatusUpdate() async {
    if (_statusCharacteristic == null) {
      debugPrint("⚠️ BleManager: Status characteristic not available");
      return;
    }
    
    try {
      debugPrint("📡 BleManager: Reading status update...");
      
      // Set up notifications if needed
      await _setupNotificationsIfNeeded();
      
      // Read the characteristic value
      List<int> data = await _statusCharacteristic!.read();
      
      if (data.isEmpty) {
        // debugPrint("⚠️ BleManager: Status update empty, retrying...");
        
        // Wait a bit and try again
        await Future.delayed(Duration(milliseconds: 300));
        data = await _statusCharacteristic!.read();
        
        if (data.isEmpty) {
          // debugPrint("⚠️ BleManager: Status update still empty, retrying again...");
          
          // Try one more time
          await Future.delayed(Duration(milliseconds: 500));
          data = await _statusCharacteristic!.read();
          
          if (data.isEmpty) {
            debugPrint("⚠️ BleManager: Status update still empty after retries");
            return;
          }
        }
      }
      
      // Process the data
      await _processStatusData(data);
      
    } catch (e) {
      debugPrint("❌ BleManager: Error reading status update: $e");
    }
  }
  
  // Helper method to set up notifications if not already set up
  Future<bool> _setupNotificationsIfNeeded() async {
    if (_statusCharacteristic == null) return false;
    
    try {
      // Check if notifications are already set up
      if (!_statusCharacteristic!.isNotifying) {
        // Enable notifications
        await _statusCharacteristic!.setNotifyValue(true);
        // debugPrint("✅ BleManager: Status notifications set up");
      }
      return true;
    } catch (e) {
      debugPrint("❌ BleManager: Error setting up status notifications: $e");
      return false;
    }
  }
  
  // Helper method to process status data
  Future<void> _processStatusData(List<int> data) async {
    if (data.isEmpty) return;
    
    String statusString = utf8.decode(data, allowMalformed: true);
    debugPrint("📱 BleManager: Received status update: $statusString");
    
    // Try to parse as JSON first
    if (statusString.trim().startsWith('{')) {
      try {
        Map<String, dynamic> jsonData = jsonDecode(statusString);

        // Parse "registered" BEFORE emitting the Wi-Fi event, so listeners
        // that rebuild on it read a consistent snapshot.
        final reg = jsonData['registered'];
        if (reg is bool) {
          _statusRegistered = reg;
          _updateRegistered();
        }

        // Extract WiFi status
        if (jsonData.containsKey('wifi')) {
          String wifiName = jsonData['wifi'].toString();
          _connectedWifi = wifiName;
          _rememberWifiName(wifiName);
          _wifiStatusController.add(wifiName);
          
          // Notify with formatted message
          String message = WifiUtils.getWifiStatusMessage(wifiName);
          _wifiStatusMessageController.add(message);
        }
        
        // Extract battery level
        if (jsonData.containsKey('battery')) {
          try {
            // Handle battery value properly based on its type
            var batteryValue = jsonData['battery'];
            if (batteryValue is int) {
              _batteryLevel = batteryValue;
            } else if (batteryValue is double) {
              _batteryLevel = batteryValue.toInt();
            } else {
              // Remove any non-numeric characters if it's a string
              String batteryString = batteryValue.toString().replaceAll(RegExp(r'[^0-9]'), '');
              if (batteryString.isNotEmpty) {
                _batteryLevel = int.parse(batteryString);
              }
            }
            _batteryStatusController.add(_batteryLevel);
          } catch (e) {
            debugPrint("⚠️ BleManager: Failed to parse battery level: $e");
          }
        }
        
        return;
      } catch (e) {
        debugPrint("⚠️ BleManager: Failed to parse JSON: $e, falling back to string parsing");
        // Fall through to legacy string parsing
      }
    }
    
    // Legacy string parsing for older firmware (key-value format or simple format)
    if (statusString.contains("WIFI:") || statusString.contains("BAT:")) {
      // Handle key-value format
      Map<String, String> statusValues = {};
      List<String> parts = statusString.split(',');
      
      for (String part in parts) {
        List<String> keyValue = part.split(':');
        if (keyValue.length == 2) {
          String key = keyValue[0].trim();
          String value = keyValue[1].trim();
          statusValues[key] = value;
        }
      }
      
      // Update WiFi status
      if (statusValues.containsKey('WIFI')) {
        String wifiName = statusValues['WIFI']!;
        _connectedWifi = wifiName;
        _rememberWifiName(wifiName);
        _wifiStatusController.add(wifiName);
        
        // Notify with formatted message
        String message = WifiUtils.getWifiStatusMessage(wifiName);
        _wifiStatusMessageController.add(message);
      }
      
      // Update battery level
      if (statusValues.containsKey('BAT')) {
        try {
          String batteryString = statusValues['BAT']!.replaceAll(RegExp(r'[^0-9]'), '');
          if (batteryString.isNotEmpty) {
            _batteryLevel = int.parse(batteryString);
            _batteryStatusController.add(_batteryLevel);
          }
        } catch (e) {
          debugPrint("⚠️ BleManager: Failed to parse battery level: $e");
        }
      }
    } else {
      // Handle simple format (status,level)
      List<String> statusParts = statusString.split(',');
      if (statusParts.isNotEmpty) {
        // First part is WiFi name
        String wifiName = statusParts[0];
        _connectedWifi = wifiName;
        _rememberWifiName(wifiName);
        
        // Second part is battery level (if present)
        if (statusParts.length >= 2) {
          try {
            if (statusParts[1].isNotEmpty) {
              int batteryValue = int.parse(statusParts[1]);
              _batteryLevel = batteryValue;
            }
          } catch (e) {
            debugPrint("⚠️ BleManager: Failed to parse battery level: $e");
          }
        }
        
        // Notify listeners of status changes
        _wifiStatusController.add(wifiName);
        _batteryStatusController.add(_batteryLevel);
        
        // Notify with formatted message
        String message = WifiUtils.getWifiStatusMessage(wifiName);
        _wifiStatusMessageController.add(message);
      } else {
        debugPrint("⚠️ BleManager: Status update format invalid: $statusString");
      }
    }
  }

  // Write the free-form user context string to Smarty (char 0xAB03).
  // Uses an acknowledged (long, if needed) write so the BLE stack surfaces
  // failures. Throws [ArgumentError] if the UTF-8 encoding exceeds
  // [userContextMaxBytes] — the firmware would otherwise truncate/reject it.
  Future<bool> writeUserContext(String context) async {
    final List<int> value = utf8.encode(context);
    if (value.length > userContextMaxBytes) {
      throw ArgumentError.value(
        context,
        'context',
        'User context is ${value.length} bytes (UTF-8); Smarty accepts at most '
            '$userContextMaxBytes bytes',
      );
    }

    if (_userDataCharacteristic == null) {
      debugPrint("❌ BleManager: User context characteristic (ab03) not found");
      return false;
    }

    try {
      await _userDataCharacteristic!
          .write(value, withoutResponse: false, allowLongWrite: true);
      return true;
    } catch (e) {
      debugPrint("❌ BleManager: Error writing user context: $e");
      return false;
    }
  }

  // Read the free-form user context string currently stored on Smarty.
  // Returns the decoded string (possibly empty) on success, or null on error.
  Future<String?> readUserContext() async {
    if (_userDataCharacteristic == null) {
      debugPrint("❌ BleManager: User context characteristic (ab03) not found");
      return null;
    }

    try {
      final List<int> data = await _userDataCharacteristic!.read();
      return utf8.decode(data, allowMalformed: true);
    } catch (e) {
      debugPrint("❌ BleManager: Error reading user context: $e");
      return null;
    }
  }

  // Read device ID from ESP32 (MAC-derived hex string)
  Future<String?> readDeviceId() async {
    if (_deviceInfoCharacteristic == null) {
      debugPrint("❌ BleManager: Device info characteristic (ab06) not found");
      return null;
    }

    // ab06 uses ESP_GATT_AUTO_RSP: the first read after a fresh connection often
    // returns the "{}" placeholder, with the real MAC-derived id arriving on a
    // later read (the same quirk the status read already retries around). Retry
    // a few times, treating empty or "{}" as "not ready yet".
    const retryDelaysMs = [0, 300, 500];
    for (int attempt = 0; attempt < retryDelaysMs.length; attempt++) {
      if (retryDelaysMs[attempt] > 0) {
        await Future.delayed(Duration(milliseconds: retryDelaysMs[attempt]));
      }
      try {
        List<int> data = await _deviceInfoCharacteristic!.read();
        if (data.isNotEmpty) {
          String deviceId = utf8.decode(data, allowMalformed: true);
          if (deviceId != '{}' && deviceId.trim().isNotEmpty) {
            debugPrint("BleManager: Read device ID: $deviceId");
            final remote = _connectedDevice?.remoteId.str;
            if (remote != null) _toyDeviceIdByRemote[remote] = deviceId;
            return deviceId;
          }
          debugPrint("⚠️ BleManager: device ID not ready (got '$deviceId'), retrying...");
        }
      } catch (e) {
        debugPrint("❌ BleManager: Error reading device ID (attempt ${attempt + 1}): $e");
      }
    }
    debugPrint("❌ BleManager: device ID unavailable after retries");
    return null;
  }

  // Write device secret to ESP32 for Firebase registration
  Future<bool> writeDeviceSecret(String secret) async {
    if (_deviceSecretCharacteristic == null) {
      debugPrint("❌ BleManager: Device secret characteristic (ab05) not found");
      return false;
    }

    try {
      List<int> value = utf8.encode(secret);
      await _deviceSecretCharacteristic!
          .write(value, withoutResponse: false, allowLongWrite: true);
      debugPrint("BleManager: Device secret written (${value.length} bytes)");
      return true;
    } catch (e) {
      debugPrint("❌ BleManager: Error writing device secret: $e");
      return false;
    }
  }

  // Connect to WiFi
  Future<bool> connectToWifi(String ssid, String password) async {
    if (_wifiCredsCharacteristic == null) {
      debugPrint("❌ BleManager: WiFi credentials characteristic not found");
      return false;
    }

    try {
      // Format the credentials
      String creds = '$ssid,$password';
      List<int> value = utf8.encode(creds);

      // Write the credentials
      await _wifiCredsCharacteristic!
          .write(value, withoutResponse: false, allowLongWrite: true);
      return true;
    } catch (e) {
      debugPrint("❌ BleManager: Error connecting to WiFi: $e");
      return false;
    }
  }

  // Firmware needs ~4 connect cycles to emit "Connection Failed" for an absent
  // AP; the old 20 s window expired before the real verdict arrived, so the
  // parent got a misleading "still connecting" while a definitive answer was
  // seconds away.
  static const Duration _wifiProvisionTimeout = Duration(seconds: 45);

  /// Send Wi-Fi credentials AND wait for the device to report the real outcome.
  ///
  /// The plain [connectToWifi] returns as soon as the BLE write is acknowledged,
  /// which only means the credentials were delivered — the ESP32 then tries to
  /// join asynchronously and reports success (the SSID) or failure ("Auth
  /// Failed" / "Connection Failed") over the status characteristic. Showing
  /// "Connected!" on the bare write ack made a wrong password look like success
  /// (APP-1). This method subscribes to the status stream FIRST, writes the
  /// credentials, then resolves on the first definitive status (or a timeout).
  Future<WifiProvisionResult> connectToWifiAndAwait(
    String ssid,
    String password, {
    Duration timeout = _wifiProvisionTimeout,
  }) async {
    if (_wifiCredsCharacteristic == null) {
      debugPrint("❌ BleManager: WiFi credentials characteristic not found");
      return WifiProvisionResult.writeError;
    }

    final completer = Completer<WifiProvisionResult>();

    // The firmware truncates the reported SSID by BYTES (32 today, 31 on
    // deployed builds), possibly mid-character, and we decode status with
    // allowMalformed — so build the accepted forms the same way.
    final ssidBytes = utf8.encode(ssid);
    final acceptedSsids = <String>{
      ssid,
      for (final n in const [32, 31])
        if (ssidBytes.length > n)
          utf8.decode(ssidBytes.sublist(0, n), allowMalformed: true),
    };

    // Subscribe BEFORE writing so a fast result isn't missed. Firmware status
    // tokens come from wifi_config.c (exact strings, incl. the space).
    StreamSubscription<String>? sub;
    sub = wifiStatusStream.listen((status) {
      final s = status.trim();
      if (s == 'Auth Failed') {
        if (!completer.isCompleted) completer.complete(WifiProvisionResult.wrongPassword);
      } else if (s == 'Connection Failed' || s == 'No credentials') {
        if (!completer.isCompleted) completer.complete(WifiProvisionResult.failed);
      } else if (s == 'NotConnected') {
        // The BLE link to the toy dropped — a join result can never arrive now,
        // so resolve immediately instead of waiting out the full timeout.
        if (!completer.isCompleted) completer.complete(WifiProvisionResult.bleDisconnected);
      } else if (acceptedSsids.contains(s) || acceptedSsids.contains(status)) {
        // On IP_EVENT_STA_GOT_IP the device reports the joined SSID as its
        // status. Firmware truncates it to 32 (deployed: 31) UTF-8 bytes, so
        // accept those byte-truncated prefixes too.
        if (!completer.isCompleted) completer.complete(WifiProvisionResult.connected);
      }
      // Transient states ("Initializing", "Reconnecting") are ignored — we keep
      // waiting for a terminal result.
    });

    try {
      final wrote = await connectToWifi(ssid, password);
      if (!wrote) {
        return WifiProvisionResult.writeError;
      }
      return await completer.future
          .timeout(timeout, onTimeout: () => WifiProvisionResult.timeout);
    } catch (e) {
      debugPrint("❌ BleManager: connectToWifiAndAwait error: $e");
      return WifiProvisionResult.failed;
    } finally {
      await sub.cancel();
    }
  }

  // Reset WiFi connection
  Future<bool> resetWifiConnection() async {
    if (_wifiCredsCharacteristic == null) {
      debugPrint("❌ BleManager: WiFi credentials characteristic not found");
      return false;
    }

    try {
      // Send RESET command
      List<int> value = utf8.encode("RESET");
      await _wifiCredsCharacteristic!.write(value, withoutResponse: false);
      return true;
    } catch (e) {
      debugPrint("❌ BleManager: Error resetting WiFi connection: $e");
      return false;
    }
  }
  
  // Forget WiFi network - alias for resetWifiConnection with clearer naming
  Future<bool> forgetWifi() async {
    // debugPrint("📶 BleManager: Forgetting WiFi network");
    return resetWifiConnection();
  }

  // Scan for WiFi networks
  Future<List<WifiNetwork>> scanWifiNetworks() async {
    // Defensive: if the cached table was refreshed lazily (or the Service
    // Changed listener hasn't fired yet), try one re-discovery before giving up.
    if (_wifiScanCharacteristic == null) {
      debugPrint("⚠️ BleManager: WiFi scan characteristic missing — re-discovering services");
      await _discoverServices();
    }
    if (_wifiScanCharacteristic == null) {
      debugPrint("❌ BleManager: WiFi scan characteristic not found after re-discovery");
      return [];
    }

    StreamSubscription<List<int>>? subscription;
    try {
      // Set up a completer to wait for scan results
      Completer<List<WifiNetwork>> completer = Completer<List<WifiNetwork>>();
      List<String> networkEntries = [];
      bool receivedEndMarker = false;
      int expectedNetworks = 0;
      
      // Enable notifications
      await _wifiScanCharacteristic!.setNotifyValue(true);

      // Listen for notifications.
      //
      // Use onValueReceived, NOT lastValueStream. lastValueStream re-emits the
      // characteristic's last cached value the instant we subscribe. After the
      // first scan that cached value is the previous scan's "END" marker, so on
      // every refresh the listener would immediately see "END" with no networks
      // collected and complete with an empty list — "No WiFi networks found" —
      // before the firmware's fresh scan (~5s) even reports back. onValueReceived
      // only fires on real reads/notifications, so we wait for genuine results.
      subscription = _wifiScanCharacteristic!.onValueReceived.listen((value) {
        if (value.isEmpty) return;

        String notification = utf8.decode(value, allowMalformed: true);
        // debugPrint("📶 BleManager: Received WiFi scan notification: $notification");
        
        // Check for TOTAL marker which indicates how many networks to expect
        if (notification.startsWith("TOTAL:")) {
          try {
            expectedNetworks = int.parse(notification.substring(6));
            debugPrint("📶 BleManager: Expecting $expectedNetworks networks");
          } catch (e) {
            debugPrint("❌ BleManager: Error parsing TOTAL count: $e");
          }
          return;
        }
        
        // Check for END marker
        if (notification == "END") {
          receivedEndMarker = true;
          debugPrint("📶 BleManager: Received END marker, scan complete");
          
          // Complete the future with all collected networks
          if (!completer.isCompleted) {
            // Process all collected entries
            List<WifiNetwork> networks = WifiUtils.processWifiScanData(networkEntries.join('\n'));
            completer.complete(networks);
            subscription?.cancel();
          }
          return;
        }
        
        // Add the notification to our list of entries
        networkEntries.add(notification);
        
        // If we have received all expected networks and an END marker, or if we have more than expected
        if ((expectedNetworks > 0 && networkEntries.length >= expectedNetworks && receivedEndMarker) || 
            (expectedNetworks > 0 && networkEntries.length > expectedNetworks + 5)) {
          if (!completer.isCompleted) {
            // debugPrint("📶 BleManager: Received all expected networks or more than expected");
            List<WifiNetwork> networks = WifiUtils.processWifiScanData(networkEntries.join('\n'));
            completer.complete(networks);
            subscription?.cancel();
          }
        }
      });

      // Trigger a scan
      bool supportsWrite =
          _wifiScanCharacteristic!.properties.write ||
          _wifiScanCharacteristic!.properties.writeWithoutResponse;

      if (supportsWrite) {
        // A single "SCAN" write is the trigger. Notifications were already
        // enabled by setNotifyValue() above, so results arrive without a read —
        // avoiding a second, redundant scan trigger on the firmware.
        List<int> triggerValue = utf8.encode("SCAN");
        await _wifiScanCharacteristic!.write(
          triggerValue,
          withoutResponse:
              _wifiScanCharacteristic!.properties.writeWithoutResponse,
        );
        // debugPrint("📶 BleManager: Sent SCAN command to trigger WiFi scan");
      } else {
        // Fallback for a read/notify-only characteristic: a read triggers the
        // firmware scan instead.
        await _wifiScanCharacteristic!.read();
      }

      // Set a timeout (cancelled on completion via whenComplete below)
      final scanTimer = Timer(Duration(seconds: 15), () {
        if (!completer.isCompleted) {
          debugPrint("⏱️ BleManager: WiFi scan timeout reached");
          if (networkEntries.isNotEmpty) {
            // Process whatever entries we have received
            List<WifiNetwork> networks = WifiUtils.processWifiScanData(networkEntries.join('\n'));
            completer.complete(networks);
          } else {
            completer.complete([]);
          }
          subscription?.cancel();
        }
      });

      // Guarantee cleanup when completer resolves (any path)
      return completer.future.whenComplete(() {
        scanTimer.cancel();
        subscription?.cancel();
      });
    } catch (e) {
      subscription?.cancel();
      debugPrint("❌ BleManager: Error scanning for WiFi networks: $e");
      return [];
    }
  }

  // Save device ID for auto-reconnect
  Future<void> _saveDeviceId(BluetoothDevice device) async {
    final uid = _uid;
    if (uid == null) {
      // No signed-in user — never persist to a device-global key.
      debugPrint("BleManager: Skipped saving device — no signed-in user");
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final id = device.remoteId.str;
    await prefs.setString(_deviceIdKeyFor(uid), id);
    await prefs.setString(_deviceNameKeyFor(uid), device.platformName);
    _savedToyId = id;
    if (device.platformName.isNotEmpty) _savedToyName = device.platformName;
    // A different toy is now saved: its own last Wi-Fi name (if any), never
    // the previous toy's.
    if (_lastWifiToyId != id) {
      _lastKnownWifiName = prefs.getString(_lastWifiKeyFor(id));
      _lastWifiToyId = id;
    }
    debugPrint("BleManager: Saved device for auto-reconnect: ${device.platformName} (${device.remoteId.str})");
  }

  // Get saved device ID
  Future<String?> getSavedDeviceId() async {
    final uid = _uid;
    if (uid == null) return null;
    final prefs = await SharedPreferences.getInstance();
    // Fall back to the legacy global key so a tester who saved a toy before
    // per-user scoping still triggers auto-reconnect (which does the migration).
    return prefs.getString(_deviceIdKeyFor(uid)) ??
        prefs.getString(_legacyDeviceIdKey);
  }

  // Clear saved device
  Future<void> clearSavedDevice() async {
    final String? toyId = _savedToyId;
    // Clear the in-memory copy first, so a prefs failure can't leave the
    // forgotten toy "saved" for this session.
    _savedToyId = null;
    _savedToyName = null;
    _lastKnownWifiName = null;
    _lastWifiToyId = null;
    final prefs = await SharedPreferences.getInstance();
    final uid = _uid;
    if (uid != null) {
      final String? storedId = prefs.getString(_deviceIdKeyFor(uid));
      await prefs.remove(_deviceIdKeyFor(uid));
      await prefs.remove(_deviceNameKeyFor(uid));
      await prefs.remove(_legacyLastWifiKeyFor(uid));
      for (final id in {toyId, storedId}) {
        if (id != null) await prefs.remove(_lastWifiKeyFor(id));
      }
    } else if (toyId != null) {
      await prefs.remove(_lastWifiKeyFor(toyId));
    }
    // Also drop the legacy global keys so a forgotten toy can't linger there.
    await prefs.remove(_legacyDeviceIdKey);
    await prefs.remove(_legacyDeviceNameKey);
    debugPrint("BleManager: Cleared saved device");
  }

  // Loads this account's saved toy into the cache, doing the one-time legacy
  // key migration. Returns the saved remote id, or null when none.
  Future<String?> _loadSavedToy(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    String? savedId = prefs.getString(_deviceIdKeyFor(uid));
    String? savedName = prefs.getString(_deviceNameKeyFor(uid));

    // One-time migration from the pre per-user global keys: attribute the
    // legacy saved toy to the first account that reconnects after the update,
    // then remove the legacy keys so no other account inherits it.
    if (savedId == null) {
      final legacyId = prefs.getString(_legacyDeviceIdKey);
      if (legacyId != null) {
        savedId = legacyId;
        savedName = prefs.getString(_legacyDeviceNameKey);
        await prefs.setString(_deviceIdKeyFor(uid), legacyId);
        if (savedName != null) {
          await prefs.setString(_deviceNameKeyFor(uid), savedName);
        }
        await prefs.remove(_legacyDeviceIdKey);
        await prefs.remove(_legacyDeviceNameKey);
      }
    }

    _savedToyId = savedId;
    _savedToyName = savedId == null ? null : (savedName ?? "Smarty");
    if (savedId == null) {
      _lastKnownWifiName = null;
      _lastWifiToyId = null;
    } else if (_lastWifiToyId != savedId) {
      String? lastWifi = prefs.getString(_lastWifiKeyFor(savedId));
      // One-time move from the old per-account key to the per-toy key.
      final legacyWifi = prefs.getString(_legacyLastWifiKeyFor(uid));
      if (legacyWifi != null) {
        if (lastWifi == null) {
          lastWifi = legacyWifi;
          await prefs.setString(_lastWifiKeyFor(savedId), legacyWifi);
        }
        await prefs.remove(_legacyLastWifiKeyFor(uid));
      }
      _lastKnownWifiName = lastWifi;
      _lastWifiToyId = savedId;
    }
    return savedId;
  }

  // Remember a real SSID (never a status token) so "Auth Failed" can name it.
  void _rememberWifiName(String ssid) {
    final s = ssid.trim();
    if (s.isEmpty || _nonConnectedStatuses.contains(s) || s.contains('Failed')) {
      return;
    }
    final toyId = _currentToyId;
    if (toyId == null) return;
    if (_lastKnownWifiName == s && _lastWifiToyId == toyId) return;
    _lastKnownWifiName = s;
    _lastWifiToyId = toyId;
    if (_uid == null) return;
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setString(_lastWifiKeyFor(toyId), s))
        .catchError((Object e) {
      debugPrint("⚠️ BleManager: Couldn't persist last Wi-Fi name: $e");
      return false;
    });
  }

  // ===========================================================================
  // Launch / resume / reconnect state machine
  // ===========================================================================

  /// Bring [phase] up to date for this account's saved toy and (re)start the
  /// cheapest way of reaching it. Idempotent and single-flight: safe to call on
  /// launch (after sign-in), on app resume, on "Check again", and when the
  /// adapter turns on. Returns once the quick probe has settled — it never
  /// waits for a sleeping toy.
  ///
  /// Steps:
  /// 1. No signed-in user / no saved toy → [ToyPhase.noToy].
  /// 2. Adapter off → [ToyPhase.bluetoothOff]; unauthorized →
  ///    [ToyPhase.needsPermission]; not yet known → stays [ToyPhase.probing].
  ///    An adapter-state listener re-runs this when Bluetooth comes on. Never
  ///    turns Bluetooth on by itself (see [requestBluetoothOn]).
  /// 3. [ToyPhase.probing]: (a) saved toy already connected to the app or the
  ///    OS (e.g. after a hot restart) → initialize; (b) otherwise scan up to
  ///    [probeScanDuration] for its advert → direct connect
  ///    ([directConnectTimeout]) → initialize.
  /// 4. Not seen → [ToyPhase.notNearby] with `connect(autoConnect: true)` left
  ///    pending (no timeout): the toy connects by itself when it wakes up.
  ///
  /// Failures route through the same classification as [initialize]; a stale
  /// pairing lands in [ToyPhase.pairingBroken] and is not retried until this is
  /// called again. Until that pairing is repaired (a successful connect, or
  /// [forgetToy]), a probe that sees nothing stays in
  /// [ToyPhase.pairingBroken] and no background connect is armed.
  Future<void> watchSavedToy() {
    final running = _watchFuture;
    if (running != null && _watchGen == _sessionGen) return running;
    final gen = _sessionGen;
    _watchGen = gen;
    late final Future<void> run;
    run = _watchSavedToyImpl(gen).whenComplete(() {
      if (identical(_watchFuture, run)) _watchFuture = null;
    });
    _watchFuture = run;
    return run;
  }

  Future<void> _watchSavedToyImpl(int gen) async {
    // Yield first so a caller in the middle of a build never gets a
    // synchronous phase change (listeners would setState during build).
    await Future<void>.value();
    if (gen != _sessionGen) return;
    try {
      final uid = _uid;
      if (uid == null) {
        _setPhase(ToyPhase.noToy);
        return;
      }

      // Someone (pending autoConnect, connection page) is mid-initialize:
      // let it finish, then re-evaluate from there. Checked BEFORE "already
      // up" so we never report connected for a half-initialized link.
      for (var inFlight = _initializeFuture;
          inFlight != null;
          inFlight = _initializeFuture) {
        await inFlight.catchError((_) {});
        if (gen != _sessionGen) return;
      }

      final savedId = await _loadSavedToy(uid);
      if (gen != _sessionGen) return;

      // Already up — nothing to do, as long as it's THIS account's toy.
      final live = _connectedDevice;
      if (live != null && _statusCharacteristic != null) {
        if (savedId != null && live.remoteId.str == savedId) {
          _setPhase(ToyPhase.connected);
          return;
        }
        // A link that isn't this account's toy (e.g. left over from before a
        // sign-out) must not show as "connected" — drop it.
        debugPrint("BleManager: dropping link to ${live.remoteId.str} — not this account's toy");
        _resetConnectionState();
        try {
          await live.disconnect();
        } catch (_) {}
        if (gen != _sessionGen) return;
      }

      if (savedId == null) {
        await _cancelPendingConnect();
        _setPhase(ToyPhase.noToy);
        return;
      }

      _ensureAdapterWatch();
      final adapter = await BleService.getBluetoothState();
      if (gen != _sessionGen) return;
      switch (adapter) {
        case BluetoothAdapterState.on:
          _waitingForAdapter = false;
          break;
        case BluetoothAdapterState.off:
        case BluetoothAdapterState.turningOff:
        case BluetoothAdapterState.unavailable:
          _waitingForAdapter = true;
          _setPhase(ToyPhase.bluetoothOff);
          return;
        case BluetoothAdapterState.unauthorized:
          _waitingForAdapter = true;
          _setPhase(ToyPhase.needsPermission);
          return;
        default:
          // unknown / turningOn: undecided — NOT "off". Keep probing; the
          // adapter listener re-runs us once it settles.
          _waitingForAdapter = true;
          _setPhase(ToyPhase.probing);
          return;
      }

      _setPhase(ToyPhase.probing);
      final device = BluetoothDevice.fromId(savedId);

      // (a) Already connected to the app, or to the OS (e.g. after a hot
      // restart the native link survives but Dart state is gone).
      bool alreadyUp = device.isConnected;
      if (!alreadyUp) {
        try {
          final system = await FlutterBluePlus.systemDevices([smartyServiceGuid]);
          alreadyUp = system.any((d) => d.remoteId == device.remoteId);
        } catch (e) {
          debugPrint("⚠️ BleManager: systemDevices failed: $e");
        }
      }
      if (gen != _sessionGen) return;
      if (alreadyUp) {
        debugPrint("BleManager: Saved toy already connected — initializing");
        await _connectAndInitQuietly(device, gen);
        return;
      }

      // Pending autoConnect already fired while we were getting here?
      if (_initializeFuture != null || _connectedDevice != null) return;

      // (b) Quick scan for the saved toy's advert.
      final bool seen;
      try {
        seen = await _probeScan(device);
      } catch (e) {
        final kind = classifyConnectError(e);
        if (gen != _sessionGen) return;
        if (kind == ConnectFailure.needsPermission) {
          _setPhase(ToyPhase.needsPermission);
          return;
        }
        if (kind == ConnectFailure.bluetoothOff) {
          _setPhase(ToyPhase.bluetoothOff);
          return;
        }
        debugPrint("⚠️ BleManager: probe scan failed ($e)");
        await _settleNotSeen(device);
        return;
      }
      if (gen != _sessionGen) return;
      if (_initializeFuture != null || _connectedDevice != null) return;

      if (seen) {
        // Direct connect is much faster than autoConnect's background scans.
        // Cancel the pending request first so we don't issue two connects.
        await _cancelPendingConnect(switchingTo: device);
        await _connectAndInitQuietly(device, gen);
        return;
      }

      debugPrint("BleManager: Saved toy not seen in ${probeScanDuration.inSeconds}s");
      await _settleNotSeen(device);
    } catch (e) {
      debugPrint("❌ BleManager: watchSavedToy error: $e");
      if (gen == _sessionGen && _phase.value == ToyPhase.probing) {
        _setPhase(_repairToyId != null && _repairToyId == _savedToyId
            ? ToyPhase.pairingBroken
            : ToyPhase.notNearby);
      }
    }
  }

  // The saved toy wasn't reached. Normally: [ToyPhase.notNearby] with a
  // background connect armed. While its pairing awaits repair: stay on
  // [ToyPhase.pairingBroken] (Home keeps the repair instructions) and arm
  // nothing — see [_repairToyId].
  Future<void> _settleNotSeen(BluetoothDevice device) async {
    if (_needsRepairFor(device)) {
      debugPrint("BleManager: pairing still needs repair — staying on pairingBroken");
      _setPhase(ToyPhase.pairingBroken);
      return;
    }
    _setPhase(ToyPhase.notNearby);
    await _armPendingConnect(device);
  }

  // Scan up to [probeScanDuration] for [device]'s advert. Returns true on the
  // first sighting. Throws on scan errors (e.g. permission) for the caller to
  // classify. Skips (returns false) if another screen is already scanning, so
  // a resume never kills the setup page's scan — the pending autoConnect
  // covers that case.
  //
  // FBP has ONE scan: startScan replaces whatever runs and stopScan stops it,
  // whoever started it. So the probe holds an owner token: a screen that
  // needs the scanner calls [cancelProbe] first, after which this probe
  // ignores results (they're the screen's) and leaves the scan running.
  Future<bool> _probeScan(BluetoothDevice device) async {
    if (FlutterBluePlus.isScanningNow) {
      debugPrint("BleManager: another scan is running — skipping probe scan");
      return false;
    }
    final int token = ++_probeToken;
    final found = Completer<bool>();
    _probeFound = found;
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      if (found.isCompleted) return;
      // Not our scan any more (cancelled, or replaced/stopped by a screen).
      if (token != _probeToken || !FlutterBluePlus.isScanningNow) return;
      if (results.any((r) => r.device.remoteId == device.remoteId)) {
        found.complete(true);
      }
    }, onError: (Object e) {
      debugPrint("⚠️ BleManager: probe scan stream error: $e");
    });
    _probeSub = sub;
    try {
      await FlutterBluePlus.startScan(
        withServices: [smartyServiceGuid],
        // Scan filters are OR-ed; on Android also match the saved MAC in case
        // the service UUID only rides in the scan response.
        withRemoteIds: Platform.isAndroid ? [device.remoteId.str] : const [],
        timeout: probeScanDuration,
      );
      if (token != _probeToken) return false; // cancelled while starting
      return await found.future.timeout(
        probeScanDuration + const Duration(milliseconds: 300),
        onTimeout: () => false,
      );
    } finally {
      await sub.cancel();
      if (identical(_probeSub, sub)) _probeSub = null;
      if (identical(_probeFound, found)) _probeFound = null;
      // Stop the scan only if it is still ours — after cancelProbe() the
      // running scan belongs to whoever asked for the cancel.
      if (token == _probeToken) {
        try {
          await FlutterBluePlus.stopScan();
        } catch (e) {
          debugPrint("⚠️ BleManager: stopScan failed: $e");
        }
      }
    }
  }

  /// Give up the launch/resume probe scan (if one is running) so a screen can
  /// start its own scan: the probe stops listening, won't stop the screen's
  /// scan, and resolves as "not seen" — [phase] then settles as for a probe
  /// that found nothing ([ToyPhase.notNearby], or [ToyPhase.pairingBroken]
  /// while a pairing awaits repair). Call right before your own `startScan`.
  void cancelProbe() {
    final found = _probeFound;
    if (found == null) return;
    debugPrint("BleManager: probe scan cancelled — a screen needs the scanner");
    _probeToken++;
    _probeFound = null;
    final sub = _probeSub;
    _probeSub = null;
    unawaited(sub?.cancel());
    if (!found.isCompleted) found.complete(false);
  }

  /// Direct-connect [device] (skipped if already connected) and [initialize]
  /// it. Cancels any pending background connect first.
  ///
  /// Contract: completes when [phase] is [ToyPhase.connected]; otherwise throws
  /// a [ConnectException] after [phase] has been moved to the matching
  /// recovery state (see [initialize]). Intended for the setup page's "tap a
  /// toy" path so it shares classification with the launch flow.
  Future<void> connectAndInitialize(
    BluetoothDevice device, {
    Duration timeout = directConnectTimeout,
  }) async {
    final gen = _sessionGen;
    await _cancelPendingConnect(switchingTo: device);
    if (gen != _sessionGen) {
      throw const ConnectException(ConnectFailure.cancelledByUser);
    }
    _setPhase(ToyPhase.connecting);
    if (!device.isConnected) {
      _linkUpAt = null;
      _connectingDevice = device;
      try {
        await device.connect(timeout: timeout, mtu: null);
      } catch (e) {
        if (gen != _sessionGen) {
          // forgetToy()/disconnectAndReset() cancelled this connect.
          throw ConnectException(ConnectFailure.cancelledByUser, e);
        }
        final failure = ConnectException(_classifyForDevice(e, device), e);
        debugPrint("❌ BleManager: connect failed (${failure.kind.name}): $e");
        await _onConnectFailure(device, failure);
        throw failure;
      } finally {
        if (_connectingDevice?.remoteId == device.remoteId) {
          _connectingDevice = null;
        }
      }
      if (gen != _sessionGen) {
        // Signed out / forgotten while the link came up: it must not carry
        // over to the next account.
        try {
          await device.disconnect();
        } catch (_) {}
        throw const ConnectException(ConnectFailure.cancelledByUser);
      }
      _linkUpAt = DateTime.now();
    }
    await _initialize(device, gen);
  }

  // connectAndInitialize for the state machine: failures are already reflected
  // in [phase], so just log them.
  Future<void> _connectAndInitQuietly(BluetoothDevice device, int gen) async {
    if (gen != _sessionGen) return;
    try {
      await connectAndInitialize(device);
    } on ConnectException catch (e) {
      debugPrint("BleManager: connect attempt ended: ${e.kind.name}");
    } catch (e) {
      debugPrint("BleManager: connect attempt error: $e");
    }
  }

  // Arm `connect(autoConnect: true)` for [device] and leave it pending with no
  // timeout; when the OS connects, initialize. Idempotent per device.
  Future<void> _armPendingConnect(BluetoothDevice device) async {
    final gen = _sessionGen;
    _rearmTimer?.cancel();
    _rearmTimer = null;
    if (_uid == null) return;
    if (_needsRepairFor(device)) {
      // Reconnecting would only replay the stale keys (and on iOS FBP would
      // keep retrying). Recovery goes through the setup page instead.
      debugPrint("BleManager: not arming background connect — pairing needs repair");
      return;
    }
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      // The adapter listener re-runs watchSavedToy when it comes back on.
      return;
    }
    if (_armedDevice != null && _armedDevice != device) {
      await _cancelPendingConnect(switchingTo: device);
    }
    // Our listener still attached = we armed it and nothing failed since.
    final bool wasArmed = _pendingSub != null && _armedDevice == device;
    _armedDevice = device;

    _pendingSub?.cancel();
    final sub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.connected) {
        _onPendingConnected(device, gen);
      }
    });
    _pendingSub = sub;

    // FBP keeps autoConnect devices armed across link drops / adapter
    // restarts itself, so normally we only issue the request when it isn't
    // already. But FBP flags the device BEFORE calling the platform and never
    // unflags it if that call throws — so a flag without our listener
    // (never armed by us, or a failed attempt) counts as NOT armed.
    if (device.isConnected) return;
    if (device.isAutoConnectEnabled && wasArmed) return;
    try {
      await device.connect(autoConnect: true, mtu: null);
      debugPrint("BleManager: Background connect armed for ${device.remoteId.str}");
    } catch (e) {
      final kind = classifyConnectError(e);
      debugPrint("⚠️ BleManager: Arming background connect failed (${kind.name}): $e");
      // Leave nothing half-armed: drop our listener and clear FBP's stale
      // autoConnect flag (disconnect() removes it), so the next attempt
      // really re-arms.
      if (identical(_pendingSub, sub)) {
        _pendingSub = null;
        if (_armedDevice == device) _armedDevice = null;
      }
      unawaited(sub.cancel());
      try {
        await device.disconnect();
      } catch (_) {}
      if (gen != _sessionGen) return;
      if (kind == ConnectFailure.needsPermission) {
        _setPhase(ToyPhase.needsPermission);
      } else if (kind == ConnectFailure.bluetoothOff) {
        _setPhase(ToyPhase.bluetoothOff);
      }
    }
  }

  void _onPendingConnected(BluetoothDevice device, int gen) {
    if (gen != _sessionGen) return;
    if (_connectedDevice == device && _statusCharacteristic != null) return;
    if (_initializeFuture != null) {
      final other = _initializingDevice;
      if (other != null && other.remoteId != device.remoteId) {
        // A different toy is being set up right now; this background link
        // would be left connected with nobody using it. Drop it.
        debugPrint("BleManager: background connect fired while setting up another toy — dropping it");
        if (_armedDevice == device) {
          _pendingSub?.cancel();
          _pendingSub = null;
          _armedDevice = null;
        }
        unawaited(device.disconnect().catchError((Object e) {
          debugPrint("⚠️ BleManager: dropping background link failed: $e");
        }));
      }
      return; // same toy: that initialize is already on it
    }
    debugPrint("BleManager: Background connect fired — initializing");
    _pendingSub?.cancel();
    _pendingSub = null;
    _linkUpAt = DateTime.now();
    _initialize(device, gen).catchError((Object e) {
      debugPrint("BleManager: initialize after background connect failed: $e");
    });
  }

  // Cancel the pending background connect (if any) and the backoff timer.
  // Never drops a live, initialized link. [switchingTo]: the toy the caller
  // is about to connect/initialize instead — an armed device that has
  // ALREADY connected (but isn't that toy) is then disconnected, since
  // nobody would take over its link.
  Future<void> _cancelPendingConnect({BluetoothDevice? switchingTo}) async {
    _rearmTimer?.cancel();
    _rearmTimer = null;
    _pendingSub?.cancel();
    _pendingSub = null;
    final armed = _armedDevice;
    _armedDevice = null;
    if (armed == null) return;
    if (armed.isConnected) {
      // Connected already: it is being (or has been) initialized — leave it,
      // unless we are switching to a different toy.
      if (switchingTo == null || armed.remoteId == switchingTo.remoteId) return;
      // A live, initialized link is dropped by initialize() itself (after
      // detaching its listeners), never from here.
      if (_connectedDevice?.remoteId == armed.remoteId) return;
      if (_initializingDevice?.remoteId == armed.remoteId) return;
    }
    try {
      await armed.disconnect();
    } catch (_) {
      // Nothing pending / already disconnected — ignore.
    }
  }

  // Link to an initialized toy dropped.
  Future<void> _onLinkLost(BluetoothDevice device) async {
    final gen = _sessionGen;
    final reason = device.disconnectReason;
    debugPrint("BleManager: link lost ($reason)");
    if (_uid == null) {
      _setPhase(ToyPhase.noToy);
      return;
    }
    final adapter = FlutterBluePlus.adapterStateNow;
    if (adapter == BluetoothAdapterState.off ||
        adapter == BluetoothAdapterState.turningOff) {
      _waitingForAdapter = true;
      _setPhase(ToyPhase.bluetoothOff);
      return;
    }
    if (_isPairingBrokenReason(reason) || _registerQuickDrop(device)) {
      await _enterPairingBroken(device);
      return;
    }
    _linkUpAt = null;
    if (gen != _sessionGen) return;
    if (_savedToyId != null && _savedToyId != device.remoteId.str) {
      // Not the saved toy — let the state machine sort it out.
      unawaited(watchSavedToy());
      return;
    }
    await _settleNotSeen(device);
  }

  // Central failure → phase mapping for initialize/connect attempts.
  Future<void> _onConnectFailure(
      BluetoothDevice device, ConnectException failure) async {
    _consecutiveFailures++;
    switch (failure.kind) {
      case ConnectFailure.pairingBroken:
        await _enterPairingBroken(device);
        return;
      case ConnectFailure.bluetoothOff:
        _waitingForAdapter = true;
        _setPhase(ToyPhase.bluetoothOff);
        return;
      case ConnectFailure.needsPermission:
        _waitingForAdapter = true;
        _setPhase(ToyPhase.needsPermission);
        return;
      default:
        break;
    }
    _linkUpAt = null;
    final savedId = _savedToyId;
    if (_uid == null || savedId == null) {
      _setPhase(ToyPhase.noToy);
      return;
    }
    if (_needsRepairFor(BluetoothDevice.fromId(savedId))) {
      // Still waiting on the repair: keep its instructions up, arm nothing.
      _setPhase(ToyPhase.pairingBroken);
      return;
    }
    // Keep waiting for the saved toy in the background, backing off so a toy
    // that connects-then-fails can't spin us in a tight loop.
    _setPhase(ToyPhase.notNearby);
    final int exp = _consecutiveFailures <= 1
        ? 0
        : (_consecutiveFailures - 1 > 5 ? 5 : _consecutiveFailures - 1);
    final int secs = 2 << exp; // 2, 4, 8 … 64
    final delay = Duration(seconds: secs > 60 ? 60 : secs);
    final gen = _sessionGen;
    _rearmTimer?.cancel();
    _rearmTimer = Timer(delay, () {
      if (gen != _sessionGen || _phase.value != ToyPhase.notNearby) return;
      _armPendingConnect(BluetoothDevice.fromId(savedId));
    });
    debugPrint("BleManager: will re-arm background connect in ${delay.inSeconds}s");
  }

  Future<void> _enterPairingBroken(BluetoothDevice device) async {
    _linkUpAt = null;
    _quickDrops = 0;
    _repairToyId = device.remoteId.str;
    await _cancelPendingConnect();
    _setPhase(ToyPhase.pairingBroken);
    // disconnect() also clears FBP's autoConnect flag — on iOS FBP would
    // otherwise keep reconnecting by itself with the stale keys.
    try {
      await device.disconnect();
    } catch (_) {}
    if (Platform.isAndroid) {
      // Drop the stale bond so the next attempt pairs fresh. (iOS has no API
      // for this — the parent forgets Smarty in Settings → Bluetooth.)
      try {
        await device.removeBond();
        debugPrint("BleManager: Removed stale bond on Android");
      } catch (e) {
        debugPrint("⚠️ BleManager: removeBond failed: $e");
      }
    }
  }

  // "Disconnected within ~2 s of connecting" is the signature of a toy that
  // rejects our stale pairing (it starts encryption right after connect). One
  // such drop could also be a toy switched off at the wrong moment, so it takes
  // two in a row (the pending reconnect makes the second one come fast).
  bool _registerQuickDrop(BluetoothDevice device) {
    final up = _linkUpAt;
    if (up == null || device.remoteId.str != _savedToyId) return false;
    if (DateTime.now().difference(up) > const Duration(milliseconds: 2500)) {
      _quickDrops = 0; // a normal drop breaks the streak
      return false;
    }
    _quickDrops++;
    debugPrint("BleManager: quick drop #$_quickDrops after connect");
    return _quickDrops >= 2;
  }

  // Classification for a failure on [device]: the error itself first, then
  // the link's own disconnect reason, then the quick-drop heuristic.
  ConnectFailure _classifyForDevice(Object error, BluetoothDevice device) {
    final kind = classifyConnectError(error);
    if (kind == ConnectFailure.pairingBroken ||
        kind == ConnectFailure.needsPermission ||
        kind == ConnectFailure.bluetoothOff ||
        kind == ConnectFailure.notSmarty) {
      return kind;
    }
    if (device.isDisconnected) {
      if (_isPairingBrokenReason(device.disconnectReason)) {
        return ConnectFailure.pairingBroken;
      }
      if (_registerQuickDrop(device)) return ConnectFailure.pairingBroken;
    }
    return kind;
  }

  static const List<String> _pairingMarkers = [
    'peer removed pairing',
    'pairing information',
    'authentication',
    'encrypt',
    'insufficient auth',
    'insuf_auth',
    'bond',
    'pin_or_key_missing',
    'key missing',
  ];

  static bool _hasPairingMarker(String lower) =>
      _pairingMarkers.any(lower.contains);

  // Disconnect reasons that mean "the toy rejected our keys":
  //  - iOS CBError 14 peerRemovedPairingInformation, 15 encryptionTimedOut
  //  - Android HCI 0x05 AUTHENTICATION_FAILURE, 0x06 PIN_OR_KEY_MISSING,
  //    0x3D CONNECTION_TERMINATED_MIC_FAILURE
  static bool _isPairingBrokenReason(DisconnectReason? reason) {
    if (reason == null) return false;
    final code = reason.code;
    if (reason.platform == ErrorPlatform.apple && (code == 14 || code == 15)) {
      return true;
    }
    if (reason.platform == ErrorPlatform.android &&
        (code == 0x05 || code == 0x06 || code == 0x3D)) {
      return true;
    }
    final desc = reason.description?.toLowerCase() ?? '';
    return desc.isNotEmpty && _hasPairingMarker(desc);
  }

  /// Map any BLE error to a [ConnectFailure]. Pure; exposed so the setup page
  /// can branch on the same classification.
  ///
  /// - pairingBroken: messages with "peer removed pairing", "pairing
  ///   information", "authentication", "encrypt", "insufficient auth", "bond";
  ///   GATT op errors 5/8/15 (insufficient authentication / authorization /
  ///   encryption); iOS connect errors 14/15; Android HCI 5/6/0x3D.
  /// - needsPermission: "permission" anywhere (Android runtime permissions).
  /// - bluetoothOff: FBP adapterIsOff / "Bluetooth must be turned on".
  /// - cancelledByUser: FBP connectionCanceled / userRejected, "cancel".
  ///   (Not bare "user": HCI 0x13 "remote user terminated" is a normal drop.)
  /// - outOfRange: timeouts, Android 133 / 147 / HCI 0x08, "not found".
  /// - notSmarty: missing service/characteristic.
  static ConnectFailure classifyConnectError(Object error) {
    if (error is ConnectException) return error.kind;
    if (error is TimeoutException) return ConnectFailure.outOfRange;

    final String lower;
    if (error is PlatformException) {
      lower = '${error.code} ${error.message ?? ''} ${error.details ?? ''}'
          .toLowerCase();
    } else {
      lower = error.toString().toLowerCase();
    }

    if (lower.contains('permission')) return ConnectFailure.needsPermission;
    if (lower.contains('bluetooth must be turned on') ||
        lower.contains('adapter is off') ||
        lower.contains('bluetooth turned off')) {
      return ConnectFailure.bluetoothOff;
    }

    if (error is FlutterBluePlusException) {
      final code = error.code;
      if (error.platform == ErrorPlatform.fbp) {
        if (code == FbpErrorCode.connectionCanceled.index ||
            code == FbpErrorCode.userRejected.index) {
          return ConnectFailure.cancelledByUser;
        }
        if (code == FbpErrorCode.timeout.index) return ConnectFailure.outOfRange;
        if (code == FbpErrorCode.adapterIsOff.index) {
          return ConnectFailure.bluetoothOff;
        }
        if (code == FbpErrorCode.serviceNotFound.index ||
            code == FbpErrorCode.characteristicNotFound.index) {
          return ConnectFailure.notSmarty;
        }
      } else if (error.function == 'connect') {
        // Native connect failure: code is a disconnect reason.
        if (error.platform == ErrorPlatform.apple &&
            (code == 14 || code == 15)) {
          return ConnectFailure.pairingBroken;
        }
        if (error.platform == ErrorPlatform.android) {
          if (code == 0x05 || code == 0x06 || code == 0x3D) {
            return ConnectFailure.pairingBroken;
          }
          if (code == 133 || code == 147 || code == 0x08) {
            return ConnectFailure.outOfRange;
          }
        }
      } else if (code == 5 || code == 8 || code == 15) {
        // GATT operation (read/write/notify) rejected for security reasons.
        return ConnectFailure.pairingBroken;
      }
    }

    if (_hasPairingMarker(lower)) return ConnectFailure.pairingBroken;
    if (lower.contains('cancel')) return ConnectFailure.cancelledByUser;
    // Before the generic "not found": "service not found" is a wrong toy,
    // not an absent one.
    if (lower.contains('smarty service') ||
        lower.contains('service not found') ||
        lower.contains('characteristic not found')) {
      return ConnectFailure.notSmarty;
    }
    if (lower.contains('timeout') ||
        lower.contains('timed out') ||
        lower.contains('not found')) {
      return ConnectFailure.outOfRange;
    }
    return ConnectFailure.unknown;
  }

  // Listen to the adapter for the whole signed-in session: re-run the state
  // machine when Bluetooth comes on, and reflect it going off in place.
  void _ensureAdapterWatch() {
    if (_adapterSub != null) return;
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (_uid == null) return;
      switch (state) {
        case BluetoothAdapterState.on:
          if (_waitingForAdapter ||
              _phase.value == ToyPhase.bluetoothOff ||
              _phase.value == ToyPhase.needsPermission) {
            _waitingForAdapter = false;
            unawaited(watchSavedToy());
          }
          break;
        case BluetoothAdapterState.off:
        case BluetoothAdapterState.turningOff:
          _rearmTimer?.cancel();
          if (_phase.value != ToyPhase.noToy) {
            _waitingForAdapter = true;
            _setPhase(ToyPhase.bluetoothOff);
          }
          break;
        case BluetoothAdapterState.unauthorized:
          if (_phase.value != ToyPhase.noToy) {
            _waitingForAdapter = true;
            _setPhase(ToyPhase.needsPermission);
          }
          break;
        default:
          break;
      }
    }, onError: (Object e) {
      debugPrint("⚠️ BleManager: adapter state stream error: $e");
    });
  }

  /// Explicit, user-initiated "turn Bluetooth on" (for a button — never called
  /// automatically). Android shows the system dialog; iOS has no API for it,
  /// so this opens Settings instead. The adapter listener takes it from there.
  Future<void> requestBluetoothOn() async {
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
        return;
      } catch (e) {
        debugPrint("⚠️ BleManager: turnOn failed/declined: $e");
      }
    }
    await BleService.openBluetoothSettings();
  }

  /// Forget this account's toy: cancel any pending connect, drop the link,
  /// remove the Android bond, clear the saved id/name, and go to
  /// [ToyPhase.noToy]. (On iOS the parent must also forget Smarty in
  /// Settings → Bluetooth to set it up again later.)
  Future<void> forgetToy() async {
    _sessionGen++;
    _watchFuture = null;
    _repairToyId = null;
    final device = _connectedDevice ??
        (_savedToyId != null ? BluetoothDevice.fromId(_savedToyId!) : null);
    // A direct connect still in flight (setup page) — cancel it too.
    final connecting = _connectingDevice;
    _connectingDevice = null;
    if (connecting != null && connecting.remoteId != device?.remoteId) {
      try {
        await connecting.disconnect();
      } catch (_) {}
    }
    await _cancelPendingConnect();
    // Reset FIRST: cancels the connection-state listener so the intentional
    // disconnect below doesn't fire the link-lost handler, which would re-arm
    // a connect to the toy we're forgetting.
    _resetConnectionState();
    _linkUpAt = null;
    _quickDrops = 0;
    _consecutiveFailures = 0;
    if (device != null) {
      try {
        await device.disconnect();
      } catch (e) {
        debugPrint("BleManager: Error disconnecting: $e");
      }
      // Remove OS-level bond on Android (iOS manages bonds internally)
      if (Platform.isAndroid) {
        try {
          await device.removeBond();
          debugPrint("BleManager: Bond removed on Android");
        } catch (e) {
          debugPrint("BleManager: Bond removal failed: $e");
        }
      }
    }
    try {
      await clearSavedDevice();
    } catch (e) {
      // The in-memory copy is already cleared; don't let a prefs error
      // escape (callers expect forgetToy to always land on noToy).
      debugPrint("⚠️ BleManager: clearing the saved toy failed: $e");
    }
    _wifiStatusController.add("NotConnected");
    _wifiStatusMessageController.add("Device forgotten");
    _setPhase(ToyPhase.noToy);
  }

  /// Tear down the current BLE session without killing the singleton (sign-out,
  /// app detach): cancels the pending connect and the adapter watch, drops the
  /// link. The stream controllers are process-lifetime and must NEVER be
  /// closed: this singleton survives logout/login, and closed broadcast
  /// controllers cannot be reopened (closing them here bricked BLE until app
  /// restart). The next [watchSavedToy] (after sign-in) settles [phase].
  Future<void> disconnectAndReset() async {
    _sessionGen++;
    _watchFuture = null;
    final device = _connectedDevice;
    // A direct connect still in flight has no _connectedDevice yet — cancel
    // it, or the link would come up under the next account.
    final connecting = _connectingDevice;
    _connectingDevice = null;
    await _cancelPendingConnect();
    await _adapterSub?.cancel();
    _adapterSub = null;
    _waitingForAdapter = false;
    // Reset FIRST: cancels the connection-state listener so the intentional
    // disconnect below doesn't fire the link-lost handler (which would re-arm
    // a reconnect right after logout).
    _resetConnectionState();
    _linkUpAt = null;
    _quickDrops = 0;
    _consecutiveFailures = 0;
    _savedToyId = null;
    _savedToyName = null;
    _lastKnownWifiName = null;
    _lastWifiToyId = null;
    _wifiStatusController.add("NotConnected");
    final toDrop = <BluetoothDevice>[
      if (device != null) device,
      if (connecting != null && connecting.remoteId != device?.remoteId)
        connecting,
    ];
    for (final d in toDrop) {
      try {
        await d.disconnect();
      } catch (e) {
        debugPrint("BleManager: Error disconnecting during reset: $e");
      }
    }
    _setPhase(ToyPhase.probing);
  }
}

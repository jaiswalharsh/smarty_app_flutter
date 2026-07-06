import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

// A singleton class to manage BLE connections and data
class BleManager {
  // Legacy device-global persistence keys (pre per-user scoping). Kept only for
  // one-time migration into the uid-scoped keys below — a second account on the
  // same phone must not inherit the first account's saved toy.
  static const String _legacyDeviceIdKey = 'smarty_saved_device_id';
  static const String _legacyDeviceNameKey = 'smarty_saved_device_name';
  String _deviceIdKeyFor(String uid) => 'smarty_saved_device_id_$uid';
  String _deviceNameKeyFor(String uid) => 'smarty_saved_device_name_$uid';

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

  // Connected device
  BluetoothDevice? _connectedDevice;

  // Guards against concurrent auto-reconnect attempts
  bool _isAutoReconnecting = false;

  // Guards against concurrent initialize() calls
  Completer<void>? _initializeLock;

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
  // null = firmware predates the "registered" status field (deployed toys);
  // callers must treat null as unknown, not as unregistered.
  bool? _deviceRegistered;

  // Stream controllers for status updates
  final _wifiStatusController = StreamController<String>.broadcast();
  final _batteryStatusController = StreamController<int>.broadcast();
  final _wifiStatusMessageController = StreamController<String>.broadcast();
  final _showSnackBarController = StreamController<String>.broadcast();

  // Getters
  BluetoothDevice? get connectedDevice => _connectedDevice;
  BluetoothService? get smartyService => _smartyService;
  String get connectedWifi => _connectedWifi;
  int get batteryLevel => _batteryLevel;
  bool? get deviceRegistered => _deviceRegistered;
  Stream<String> get wifiStatusStream => _wifiStatusController.stream;
  Stream<int> get batteryStatusStream => _batteryStatusController.stream;
  Stream<String> get wifiStatusMessageStream =>
      _wifiStatusMessageController.stream;
  Stream<String> get showSnackBarStream => _showSnackBarController.stream;
  bool get isConnected => _connectedDevice != null;
  // Non-connected statuses from ESP32 (wifi_config.c) and Flutter internals
  static const _nonConnectedStatuses = {
    '', 'Unknown', 'NotConnected', 'Initializing',
    'Auth Failed', 'Connection Failed', 'No credentials', 'Reconnecting',
  };
  bool get isWifiConnected =>
      _connectedWifi.trim().isNotEmpty &&
      !_nonConnectedStatuses.contains(_connectedWifi) &&
      !_connectedWifi.contains('Failed');

  // Initialize the manager with a connected device
  Future<void> initialize(BluetoothDevice device) async {
    if (_connectedDevice == device) {
      // Already initialized with this device
      return;
    }

    // Serialize concurrent initialize() calls
    if (_initializeLock != null) {
      await _initializeLock!.future;
      return;
    }
    _initializeLock = Completer<void>();

    try {
      _connectedDevice = device;
      print("🔄 BleManager: Initializing with device: ${device.platformName}");

      // Request larger MTU for WiFi scan chunks and JSON status notifications
      try {
        await device.requestMtu(512);
        print("✅ BleManager: MTU negotiated");
      } catch (e) {
        print("⚠️ BleManager: MTU request failed: $e");
      }

      // Trigger bonding on Android (prevents double pairing popup bug)
      // iOS handles bonding automatically when encrypted characteristics are accessed
      if (Platform.isAndroid) {
        try {
          await device.createBond();
          print("BleManager: Bond created/confirmed on Android");
        } catch (e) {
          print("BleManager: Bond creation skipped (may already be bonded): $e");
        }
      }

      // Discover services
      bool servicesReady = await _discoverServices();

      if (!servicesReady) {
        print("❌ BleManager: Service discovery failed — required services/characteristics not found");
        _showSnackBarController.add("Device missing required Smarty service");
        _resetConnectionState();
        return;
      }

      // Set up status updates
      if (_statusCharacteristic != null) {
        _setupStatusUpdates();
      }

      // Re-discover when the peripheral signals its GATT table changed. This
      // device sends a Service Changed indication right after bonding — which
      // arrives AFTER the discovery above — and again whenever the firmware is
      // reflashed. Without this, a stale/incomplete cached table (e.g. missing
      // the ab01 Wi-Fi scan characteristic) is never refreshed.
      _servicesResetSubscription?.cancel();
      _servicesResetSubscription = device.onServicesReset.listen((_) async {
        print("🔄 BleManager: Service Changed received — re-discovering services");
        final ok = await _discoverServices();
        if (ok && _statusCharacteristic != null) {
          _setupStatusUpdates();
        }
      });

      // Set up connection state monitoring
      _monitorDeviceConnection();

      // Persist device ID for auto-reconnect on next app launch
      _saveDeviceId(device);
      _initializeLock!.complete();
    } catch (e) {
      _initializeLock!.completeError(e);
      rethrow;
    } finally {
      _initializeLock = null;
    }
  }

  // Monitor device connection state
  void _monitorDeviceConnection() {
    if (_connectedDevice == null) return;

    // Cancel any previous subscription to avoid listener accumulation
    _connectionStateSubscription?.cancel();

    _connectionStateSubscription = _connectedDevice!.connectionState.listen((BluetoothConnectionState state) {
      print("💡 Device connection state changed: $state");
      
      if (state == BluetoothConnectionState.connected) {
        // When connected, ensure notifications are set up
        if (_statusCharacteristic != null) {
          _setupNotificationsIfNeeded().then((success) {
            if (success) {
              // print("✅ Connection established, notifications set up");
            }
          });
        }
      } else if (state == BluetoothConnectionState.disconnected) {
        print("❌ Device disconnected from BLE manager");

        // Reset the device and service references
        _resetConnectionState();

        // Notify listeners about the disconnection
        _wifiStatusController.add("NotConnected");
        _wifiStatusMessageController.add("Device disconnected");
        _showSnackBarController.add("Device disconnected");

        // Attempt auto-reconnect if we have a saved device
        _attemptAutoReconnect();
      }
    });
  }
  
  // Attempt to auto-reconnect after a mid-session disconnect
  void _attemptAutoReconnect() async {
    if (_isAutoReconnecting) return;
    _isAutoReconnecting = true;

    try {
      // Wait a few seconds for the device to power back on and start advertising
      await Future.delayed(const Duration(seconds: 3));

      // Don't reconnect if something else already reconnected
      if (_connectedDevice != null) return;

      print("🔄 BleManager: Attempting auto-reconnect after disconnect...");
      final success = await autoReconnectToSavedDevice();
      if (success) {
        print("✅ BleManager: Auto-reconnect succeeded");
        _wifiStatusController.add(_connectedWifi);
        _showSnackBarController.add("Reconnected to ${_connectedDevice?.platformName ?? 'Smarty'}");
      } else {
        print("❌ BleManager: Auto-reconnect failed, will retry in 10s");
        // Retry once more after a longer delay (device may still be booting)
        await Future.delayed(const Duration(seconds: 10));
        if (_connectedDevice != null) return;
        final retrySuccess = await autoReconnectToSavedDevice();
        if (retrySuccess) {
          print("✅ BleManager: Auto-reconnect succeeded on retry");
          _wifiStatusController.add(_connectedWifi);
          _showSnackBarController.add("Reconnected to ${_connectedDevice?.platformName ?? 'Smarty'}");
        }
      }
    } finally {
      _isAutoReconnecting = false;
    }
  }

  // Reset the connection state when device is disconnected
  void _resetConnectionState() {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _statusNotificationSubscription?.cancel();
    _statusNotificationSubscription = null;
    _servicesResetSubscription?.cancel();
    _servicesResetSubscription = null;
    _smartyService = null;
    _statusCharacteristic = null;
    _wifiScanCharacteristic = null;
    _wifiCredsCharacteristic = null;
    _userDataCharacteristic = null;
    _deviceSecretCharacteristic = null;
    _deviceInfoCharacteristic = null;
    _connectedWifi = "NotConnected";
    _deviceRegistered = null;
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
        print("❌ BleManager: Smarty service not found among ${services.length} services");
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

      print("📋 BleManager: Characteristics — "
          "status=${_statusCharacteristic != null ? 'OK' : 'MISSING'}, "
          "wifiScan=${_wifiScanCharacteristic != null ? 'OK' : 'MISSING'}, "
          "wifiCreds=${_wifiCredsCharacteristic != null ? 'OK' : 'MISSING'}, "
          "userData=${_userDataCharacteristic != null ? 'OK' : 'MISSING'}, "
          "deviceSecret=${_deviceSecretCharacteristic != null ? 'OK' : 'MISSING'}, "
          "deviceInfo=${_deviceInfoCharacteristic != null ? 'OK' : 'MISSING'}");

      // Require at least the status characteristic
      if (_statusCharacteristic == null) {
        print("❌ BleManager: Required status characteristic (ab04) not found");
        return false;
      }

      return true;
    } catch (e) {
      print("❌ BleManager: Error discovering services: $e");
      return false;
    }
  }

  // Set up status updates
  void _setupStatusUpdates() {
    if (_statusCharacteristic == null) return;

    try {
      // Enable notifications
      _statusCharacteristic!.setNotifyValue(true).then((_) {
        // print("✅ BleManager: Status notifications enabled");
      }).catchError((e) {
        print("❌ BleManager: Error enabling status notifications: $e");
      });

      // Cancel previous subscription to avoid accumulation
      _statusNotificationSubscription?.cancel();

      // Variables for debouncing
      String lastStatusString = "";
      DateTime lastUpdateTime = DateTime.now();

      // Listen for notifications
      _statusNotificationSubscription = _statusCharacteristic!.lastValueStream.listen(
        (value) {
          if (value.isEmpty) return;

          String statusString = String.fromCharCodes(value);

          // Debounce: Skip if this is the same status string received within the last 500ms
          if (statusString == lastStatusString &&
              DateTime.now().difference(lastUpdateTime).inMilliseconds < 500) {
            return;
          }

          // Update debounce tracking
          lastStatusString = statusString;
          lastUpdateTime = DateTime.now();

          print("📊 BleManager: Status notification received: $statusString");

          // Process status data
          _processStatusData(value);
        },
        onError: (error) {
          print("❌ BleManager: Status notification stream error: $error");
          _statusNotificationSubscription = null;
        },
        onDone: () {
          _statusNotificationSubscription = null;
        },
      );

      // Notifications will emit the current value automatically — no explicit read needed
    } catch (e) {
      print("❌ BleManager: Error setting up status updates: $e");
    }
  }

  // Read status update from the device
  Future<void> readStatusUpdate() async {
    if (_statusCharacteristic == null) {
      print("⚠️ BleManager: Status characteristic not available");
      return;
    }
    
    try {
      print("📡 BleManager: Reading status update...");
      
      // Set up notifications if needed
      await _setupNotificationsIfNeeded();
      
      // Read the characteristic value
      List<int> data = await _statusCharacteristic!.read();
      
      if (data.isEmpty) {
        // print("⚠️ BleManager: Status update empty, retrying...");
        
        // Wait a bit and try again
        await Future.delayed(Duration(milliseconds: 300));
        data = await _statusCharacteristic!.read();
        
        if (data.isEmpty) {
          // print("⚠️ BleManager: Status update still empty, retrying again...");
          
          // Try one more time
          await Future.delayed(Duration(milliseconds: 500));
          data = await _statusCharacteristic!.read();
          
          if (data.isEmpty) {
            print("⚠️ BleManager: Status update still empty after retries");
            return;
          }
        }
      }
      
      // Process the data
      await _processStatusData(data);
      
    } catch (e) {
      print("❌ BleManager: Error reading status update: $e");
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
        // print("✅ BleManager: Status notifications set up");
      }
      return true;
    } catch (e) {
      print("❌ BleManager: Error setting up status notifications: $e");
      return false;
    }
  }
  
  // Helper method to process status data
  Future<void> _processStatusData(List<int> data) async {
    if (data.isEmpty) return;
    
    String statusString = String.fromCharCodes(data);
    print("📱 BleManager: Received status update: $statusString");
    
    // Try to parse as JSON first
    if (statusString.trim().startsWith('{')) {
      try {
        Map<String, dynamic> jsonData = jsonDecode(statusString);
        
        // Extract WiFi status
        if (jsonData.containsKey('wifi')) {
          String wifiName = jsonData['wifi'].toString();
          _connectedWifi = wifiName;
          _wifiStatusController.add(wifiName);
          
          // Notify with formatted message
          String message = WifiUtils.getWifiStatusMessage(wifiName);
          _wifiStatusMessageController.add(message);
        }

        final reg = jsonData['registered'];
        if (reg is bool) _deviceRegistered = reg;
        
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
            print("⚠️ BleManager: Failed to parse battery level: $e");
          }
        }
        
        return;
      } catch (e) {
        print("⚠️ BleManager: Failed to parse JSON: $e, falling back to string parsing");
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
          print("⚠️ BleManager: Failed to parse battery level: $e");
        }
      }
    } else {
      // Handle simple format (status,level)
      List<String> statusParts = statusString.split(',');
      if (statusParts.isNotEmpty) {
        // First part is WiFi name
        String wifiName = statusParts[0];
        _connectedWifi = wifiName;
        
        // Second part is battery level (if present)
        if (statusParts.length >= 2) {
          try {
            if (statusParts[1].isNotEmpty) {
              int batteryValue = int.parse(statusParts[1]);
              _batteryLevel = batteryValue;
            }
          } catch (e) {
            print("⚠️ BleManager: Failed to parse battery level: $e");
          }
        }
        
        // Notify listeners of status changes
        _wifiStatusController.add(wifiName);
        _batteryStatusController.add(_batteryLevel);
        
        // Notify with formatted message
        String message = WifiUtils.getWifiStatusMessage(wifiName);
        _wifiStatusMessageController.add(message);
      } else {
        print("⚠️ BleManager: Status update format invalid: $statusString");
      }
    }
  }

  // Write the free-form user context string to Smarty (char 0xAB03).
  // Uses an acknowledged write so the BLE stack surfaces failures.
  Future<bool> writeUserContext(String context) async {
    if (_userDataCharacteristic == null) {
      print("❌ BleManager: User context characteristic (ab03) not found");
      return false;
    }

    try {
      final List<int> value = utf8.encode(context);
      await _userDataCharacteristic!.write(value, withoutResponse: false);
      return true;
    } catch (e) {
      print("❌ BleManager: Error writing user context: $e");
      return false;
    }
  }

  // Read the free-form user context string currently stored on Smarty.
  // Returns the decoded string (possibly empty) on success, or null on error.
  Future<String?> readUserContext() async {
    if (_userDataCharacteristic == null) {
      print("❌ BleManager: User context characteristic (ab03) not found");
      return null;
    }

    try {
      final List<int> data = await _userDataCharacteristic!.read();
      return utf8.decode(data, allowMalformed: true);
    } catch (e) {
      print("❌ BleManager: Error reading user context: $e");
      return null;
    }
  }

  // Read device ID from ESP32 (MAC-derived hex string)
  Future<String?> readDeviceId() async {
    if (_deviceInfoCharacteristic == null) {
      print("❌ BleManager: Device info characteristic (ab06) not found");
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
          String deviceId = String.fromCharCodes(data);
          if (deviceId != '{}' && deviceId.trim().isNotEmpty) {
            print("BleManager: Read device ID: $deviceId");
            return deviceId;
          }
          print("⚠️ BleManager: device ID not ready (got '$deviceId'), retrying...");
        }
      } catch (e) {
        print("❌ BleManager: Error reading device ID (attempt ${attempt + 1}): $e");
      }
    }
    print("❌ BleManager: device ID unavailable after retries");
    return null;
  }

  // Write device secret to ESP32 for Firebase registration
  Future<bool> writeDeviceSecret(String secret) async {
    if (_deviceSecretCharacteristic == null) {
      print("❌ BleManager: Device secret characteristic (ab05) not found");
      return false;
    }

    try {
      List<int> value = utf8.encode(secret);
      await _deviceSecretCharacteristic!.write(value, withoutResponse: false);
      print("BleManager: Device secret written (${value.length} bytes)");
      return true;
    } catch (e) {
      print("❌ BleManager: Error writing device secret: $e");
      return false;
    }
  }

  // Connect to WiFi
  Future<bool> connectToWifi(String ssid, String password) async {
    if (_wifiCredsCharacteristic == null) {
      print("❌ BleManager: WiFi credentials characteristic not found");
      return false;
    }

    try {
      // Format the credentials
      String creds = '$ssid,$password';
      List<int> value = utf8.encode(creds);

      // Write the credentials
      await _wifiCredsCharacteristic!.write(value, withoutResponse: false);
      return true;
    } catch (e) {
      print("❌ BleManager: Error connecting to WiFi: $e");
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
      print("❌ BleManager: WiFi credentials characteristic not found");
      return WifiProvisionResult.writeError;
    }

    final completer = Completer<WifiProvisionResult>();

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
      } else if (s == ssid ||
          (ssid.length > 31 && s == ssid.substring(0, 31))) {
        // On IP_EVENT_STA_GOT_IP the device reports the joined SSID as its
        // status. Deployed firmware truncates the SSID to 31 chars, so a full
        // 32-char SSID never matched exactly — accept the 31-char prefix too.
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
      print("❌ BleManager: connectToWifiAndAwait error: $e");
      return WifiProvisionResult.failed;
    } finally {
      await sub.cancel();
    }
  }

  // Reset WiFi connection
  Future<bool> resetWifiConnection() async {
    if (_wifiCredsCharacteristic == null) {
      print("❌ BleManager: WiFi credentials characteristic not found");
      return false;
    }

    try {
      // Send RESET command
      List<int> value = utf8.encode("RESET");
      await _wifiCredsCharacteristic!.write(value, withoutResponse: false);
      return true;
    } catch (e) {
      print("❌ BleManager: Error resetting WiFi connection: $e");
      return false;
    }
  }
  
  // Forget WiFi network - alias for resetWifiConnection with clearer naming
  Future<bool> forgetWifi() async {
    // print("📶 BleManager: Forgetting WiFi network");
    return resetWifiConnection();
  }

  // Scan for WiFi networks
  Future<List<WifiNetwork>> scanWifiNetworks() async {
    // Defensive: if the cached table was refreshed lazily (or the Service
    // Changed listener hasn't fired yet), try one re-discovery before giving up.
    if (_wifiScanCharacteristic == null) {
      print("⚠️ BleManager: WiFi scan characteristic missing — re-discovering services");
      await _discoverServices();
    }
    if (_wifiScanCharacteristic == null) {
      print("❌ BleManager: WiFi scan characteristic not found after re-discovery");
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

        String notification = String.fromCharCodes(value);
        // print("📶 BleManager: Received WiFi scan notification: $notification");
        
        // Check for TOTAL marker which indicates how many networks to expect
        if (notification.startsWith("TOTAL:")) {
          try {
            expectedNetworks = int.parse(notification.substring(6));
            print("📶 BleManager: Expecting $expectedNetworks networks");
          } catch (e) {
            print("❌ BleManager: Error parsing TOTAL count: $e");
          }
          return;
        }
        
        // Check for END marker
        if (notification == "END") {
          receivedEndMarker = true;
          print("📶 BleManager: Received END marker, scan complete");
          
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
            // print("📶 BleManager: Received all expected networks or more than expected");
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
        // print("📶 BleManager: Sent SCAN command to trigger WiFi scan");
      } else {
        // Fallback for a read/notify-only characteristic: a read triggers the
        // firmware scan instead.
        await _wifiScanCharacteristic!.read();
      }

      // Set a timeout (cancelled on completion via whenComplete below)
      final scanTimer = Timer(Duration(seconds: 15), () {
        if (!completer.isCompleted) {
          print("⏱️ BleManager: WiFi scan timeout reached");
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
      print("❌ BleManager: Error scanning for WiFi networks: $e");
      return [];
    }
  }

  // Restore connection after hot restart
  Future<bool> restoreConnectionsAfterHotRestart() async {
    try {
      // Wait for Bluetooth to be ready before querying devices
      if (!await BleService.isBluetoothReady()) {
        print("⚠️ BleManager: Bluetooth not ready, skipping hot-restart restore");
        return false;
      }

      // Get connected devices from BLE service
      List<BluetoothDevice> devices = await BleService.getConnectedDevices();

      if (devices.isNotEmpty) {
        // Use the first found device
        BluetoothDevice device = devices.first;
        print("✅ BleManager: Restoring connection to ${device.platformName}");
        
        // Initialize with the device
        await initialize(device);
        
        // If we have a service, consider the restoration successful
        if (_smartyService != null) {
          // Set connected status
          _connectedDevice = device;
          
          // Allow some time for the connection to stabilize
          await Future.delayed(Duration(milliseconds: 500));
          
          // Set up notification handlers for status updates
          await _setupNotificationsIfNeeded();
          
          // Request status update with retry mechanism
          bool statusSuccess = await _requestStatusUpdateWithRetry();
          
          if (!statusSuccess) {
            print("⚠️ BleManager: Could not get valid status update after reconnection");
          }
          
          // Notify listeners of connection state change
          _wifiStatusController.add(_connectedWifi);
          
          return true;
        }
      }
      
      return false;
    } catch (e) {
      print("❌ BleManager: Error restoring connections: $e");
      return false;
    }
  }
  
  Future<bool> _requestStatusUpdateWithRetry() async {
    int retries = 0;
    const maxRetries = 3;
    
    while (retries < maxRetries) {
      // print("📡 BleManager: Requesting status update after hot restart");
      
      try {
        // Make sure notifications are enabled
        await _setupNotificationsIfNeeded();
        
        // Request status update by reading
        List<int> data = await _statusCharacteristic!.read();
        
        if (data.isNotEmpty) {
          // Process the data
          await _processStatusData(data);
          
          // Check if we have valid status data
          if (_connectedWifi.isNotEmpty && _connectedWifi != "Unknown") {
            // print("✅ BleManager: Successfully received status update");
            return true;
          }
        }
        
        print("⚠️ BleManager: Status update empty or incomplete, retry ${retries + 1}/$maxRetries");
        retries++;
        await Future.delayed(Duration(milliseconds: 500 * retries));
      } catch (e) {
        print("⚠️ BleManager: Error requesting status update: $e");
        retries++;
        await Future.delayed(Duration(milliseconds: 500 * retries));
      }
    }
    
    print("⚠️ BleManager: Status update still empty after retries");
    return false;
  }

  // Save device ID for auto-reconnect
  Future<void> _saveDeviceId(BluetoothDevice device) async {
    final uid = _uid;
    if (uid == null) {
      // No signed-in user — never persist to a device-global key.
      print("BleManager: Skipped saving device — no signed-in user");
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_deviceIdKeyFor(uid), device.remoteId.str);
    await prefs.setString(_deviceNameKeyFor(uid), device.platformName);
    print("BleManager: Saved device for auto-reconnect: ${device.platformName} (${device.remoteId.str})");
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
    final prefs = await SharedPreferences.getInstance();
    final uid = _uid;
    if (uid != null) {
      await prefs.remove(_deviceIdKeyFor(uid));
      await prefs.remove(_deviceNameKeyFor(uid));
    }
    // Also drop the legacy global keys so a forgotten toy can't linger there.
    await prefs.remove(_legacyDeviceIdKey);
    await prefs.remove(_legacyDeviceNameKey);
    print("BleManager: Cleared saved device");
  }

  // Disconnect and forget the saved device
  Future<void> disconnectAndForget() async {
    final device = _connectedDevice;
    // Reset FIRST: cancels the connection-state listener so the intentional
    // disconnect below doesn't fire the disconnect handler, whose
    // _attemptAutoReconnect would reconnect the device we're forgetting.
    _resetConnectionState();
    try {
      if (device != null) {
        // Remove OS-level bond on Android (iOS manages bonds internally)
        if (Platform.isAndroid) {
          try {
            await device.removeBond();
            print("BleManager: Bond removed on Android");
          } catch (e) {
            print("BleManager: Bond removal failed: $e");
          }
        }
        await device.disconnect();
      }
    } catch (e) {
      print("BleManager: Error disconnecting: $e");
    }
    await clearSavedDevice();
    _wifiStatusController.add("NotConnected");
    _wifiStatusMessageController.add("Device forgotten");
  }

  Future<bool>? _autoReconnectFuture;

  // Concurrent callers (Home's device check, the connection page, the
  // disconnect handler) share one attempt instead of stacking parallel
  // connect() calls to the same device.
  Future<bool> autoReconnectToSavedDevice() {
    return _autoReconnectFuture ??= _autoReconnectToSavedDeviceImpl()
        .whenComplete(() => _autoReconnectFuture = null);
  }

  // Auto-reconnect to previously saved device
  Future<bool> _autoReconnectToSavedDeviceImpl() async {
    try {
      final uid = _uid;
      if (uid == null) return false;

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

      if (savedId == null) {
        return false;
      }
      savedName ??= "Smarty";

      print("BleManager: Attempting auto-reconnect to $savedName ($savedId)");

      final device = BluetoothDevice.fromId(savedId);

      // Wait for Bluetooth to be ready before attempting anything
      if (!await BleService.isBluetoothReady()) {
        print("BleManager: Bluetooth not ready, skipping auto-reconnect");
        return false;
      }

      // Check if already connected at OS level
      if ((await device.connectionState.first) == BluetoothConnectionState.connected) {
        print("BleManager: Device already connected, initializing...");
        await initialize(device);
        return _smartyService != null;
      }

      // Connect with autoConnect for low-power background reconnect
      // autoConnect returns immediately — must wait for actual connection via stream
      await device.connect(autoConnect: true, mtu: null);

      final connected = await device.connectionState
          .firstWhere((s) => s == BluetoothConnectionState.connected)
          .timeout(const Duration(seconds: 15),
              onTimeout: () => BluetoothConnectionState.disconnected);

      if (connected == BluetoothConnectionState.connected) {
        print("BleManager: Auto-reconnect successful to $savedName");
        await initialize(device);
        return _smartyService != null;
      }

      return false;
    } catch (e) {
      print("BleManager: Auto-reconnect failed: $e");
      return false;
    }
  }

  /// Tear down the current BLE session without killing the singleton.
  /// The stream controllers are process-lifetime and must NEVER be closed:
  /// this singleton survives logout/login, and closed broadcast controllers
  /// cannot be reopened (closing them here bricked BLE until app restart).
  Future<void> disconnectAndReset() async {
    final device = _connectedDevice;
    // Reset FIRST: cancels the connection-state listener so the intentional
    // disconnect below doesn't fire the disconnect handler (snackbar +
    // _attemptAutoReconnect would reconnect right after logout).
    _resetConnectionState();
    _wifiStatusController.add("NotConnected");
    if (device != null) {
      try {
        await device.disconnect();
      } catch (e) {
        print("BleManager: Error disconnecting during reset: $e");
      }
    }
  }
}

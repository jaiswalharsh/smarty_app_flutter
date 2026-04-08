import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../utils/wifi_utils.dart';
import 'ble_service.dart';

// A singleton class to manage BLE connections and data
class BleManager {
  // Saved device persistence keys
  static const String _savedDeviceIdKey = 'smarty_saved_device_id';
  static const String _savedDeviceNameKey = 'smarty_saved_device_name';

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

  // Status information
  String _connectedWifi = "Unknown";
  int _batteryLevel = 0;

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
  Stream<String> get wifiStatusStream => _wifiStatusController.stream;
  Stream<int> get batteryStatusStream => _batteryStatusController.stream;
  Stream<String> get wifiStatusMessageStream =>
      _wifiStatusMessageController.stream;
  Stream<String> get showSnackBarStream => _showSnackBarController.stream;
  bool get isConnected => _connectedDevice != null;
  bool get isWifiConnected =>
      _connectedWifi.trim().isNotEmpty &&
      _connectedWifi != "Unknown" &&
      _connectedWifi != "NotConnected" &&
      _connectedWifi != "Init" &&
      _connectedWifi != "Initializing" &&
      _connectedWifi != "Auth Failed" &&
      _connectedWifi != "AuthFailed" &&
      _connectedWifi != "Reset Failed" &&
      _connectedWifi != "No credentials" &&
      _connectedWifi != "Connection Failed" &&
      _connectedWifi != "Reconnecting" &&
      !_connectedWifi.contains("Failed");

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

      // Set up connection state monitoring
      _monitorDeviceConnection();

      // Persist device ID for auto-reconnect on next app launch
      _saveDeviceId(device);
    } finally {
      _initializeLock!.complete();
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
    _smartyService = null;
    _statusCharacteristic = null;
    _wifiScanCharacteristic = null;
    _wifiCredsCharacteristic = null;
    _userDataCharacteristic = null;
    _deviceSecretCharacteristic = null;
    _deviceInfoCharacteristic = null;
    _connectedWifi = "NotConnected";
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

  // Send user data
  Future<bool> sendUserData(String name, String age, String hobby, {String avatar = ''}) async {
    if (_userDataCharacteristic == null) {
      print("❌ BleManager: User data characteristic not found");
      return false;
    }

    try {
      // Format the user data, include avatar if provided
      String userData = avatar.isEmpty
          ? "NAME:$name,AGE:$age,HOBBY:$hobby"
          : "NAME:$name,AGE:$age,HOBBY:$hobby,AVATAR:$avatar";
          
      // print("📤 Sending user data: $userData");
      List<int> value = utf8.encode(userData);

      // Check if the characteristic supports write without response
      bool supportsWriteWithoutResponse =
          _userDataCharacteristic!.properties.writeWithoutResponse;

      // Write the data
      await _userDataCharacteristic!.write(
        value,
        withoutResponse: supportsWriteWithoutResponse,
      );
      return true;
    } catch (e) {
      print("❌ BleManager: Error sending user data: $e");
      return false;
    }
  }

  // Read device ID from ESP32 (MAC-derived hex string)
  Future<String?> readDeviceId() async {
    if (_deviceInfoCharacteristic == null) {
      print("❌ BleManager: Device info characteristic (ab06) not found");
      return null;
    }

    try {
      List<int> data = await _deviceInfoCharacteristic!.read();
      if (data.isEmpty) return null;
      String deviceId = String.fromCharCodes(data);
      print("BleManager: Read device ID: $deviceId");
      return deviceId;
    } catch (e) {
      print("❌ BleManager: Error reading device ID: $e");
      return null;
    }
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
  Future<List<String>> scanWifiNetworks() async {
    if (_wifiScanCharacteristic == null) {
      print("❌ BleManager: WiFi scan characteristic not found");
      return [];
    }

    StreamSubscription<List<int>>? subscription;
    try {
      // Set up a completer to wait for scan results
      Completer<List<String>> completer = Completer<List<String>>();
      List<String> networkEntries = [];
      bool receivedEndMarker = false;
      int expectedNetworks = 0;
      
      // Enable notifications
      await _wifiScanCharacteristic!.setNotifyValue(true);

      // Listen for notifications
      subscription = _wifiScanCharacteristic!.lastValueStream.listen((value) {
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
            List<String> networks = WifiUtils.processWifiScanData(networkEntries.join('\n'));
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
            List<String> networks = WifiUtils.processWifiScanData(networkEntries.join('\n'));
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
        List<int> triggerValue = utf8.encode("SCAN");
        await _wifiScanCharacteristic!.write(
          triggerValue,
          withoutResponse:
              _wifiScanCharacteristic!.properties.writeWithoutResponse,
        );
        // print("📶 BleManager: Sent SCAN command to trigger WiFi scan");
      }

      // Read the characteristic to start receiving notifications
      await _wifiScanCharacteristic!.read();
      // print("📶 BleManager: Initial read completed to start notifications");

      // Set a timeout (cancelled on completion via whenComplete below)
      final scanTimer = Timer(Duration(seconds: 15), () {
        if (!completer.isCompleted) {
          print("⏱️ BleManager: WiFi scan timeout reached");
          if (networkEntries.isNotEmpty) {
            // Process whatever entries we have received
            List<String> networks = WifiUtils.processWifiScanData(networkEntries.join('\n'));
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
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_savedDeviceIdKey, device.remoteId.str);
    await prefs.setString(_savedDeviceNameKey, device.platformName);
    print("BleManager: Saved device for auto-reconnect: ${device.platformName} (${device.remoteId.str})");
  }

  // Get saved device ID
  Future<String?> getSavedDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_savedDeviceIdKey);
  }

  // Clear saved device
  Future<void> clearSavedDevice() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_savedDeviceIdKey);
    await prefs.remove(_savedDeviceNameKey);
    print("BleManager: Cleared saved device");
  }

  // Disconnect and forget the saved device
  Future<void> disconnectAndForget() async {
    try {
      if (_connectedDevice != null) {
        // Remove OS-level bond on Android (iOS manages bonds internally)
        if (Platform.isAndroid) {
          try {
            await _connectedDevice!.removeBond();
            print("BleManager: Bond removed on Android");
          } catch (e) {
            print("BleManager: Bond removal failed: $e");
          }
        }
        await _connectedDevice!.disconnect();
      }
    } catch (e) {
      print("BleManager: Error disconnecting: $e");
    }
    _resetConnectionState();
    await clearSavedDevice();
    _wifiStatusController.add("NotConnected");
    _wifiStatusMessageController.add("Device forgotten");
  }

  // Auto-reconnect to previously saved device
  Future<bool> autoReconnectToSavedDevice() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedId = prefs.getString(_savedDeviceIdKey);
      final savedName = prefs.getString(_savedDeviceNameKey) ?? "Smarty";

      if (savedId == null) {
        return false;
      }

      print("BleManager: Attempting auto-reconnect to $savedName ($savedId)");

      final device = BluetoothDevice.fromId(savedId);

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

  // Dispose resources
  void dispose() {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _statusNotificationSubscription?.cancel();
    _statusNotificationSubscription = null;
    // Close stream controllers
    _wifiStatusController.close();
    _batteryStatusController.close();
    _wifiStatusMessageController.close();
    _showSnackBarController.close();
  }
}

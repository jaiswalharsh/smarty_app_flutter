import 'dart:async';
import 'dart:convert';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../utils/wifi_utils.dart';
import 'ble_service.dart';

// A singleton class to manage BLE connections and data
class BleManager {
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

  // Cached services
  BluetoothService? _smartyService;

  // Cached characteristics
  BluetoothCharacteristic? _statusCharacteristic;
  BluetoothCharacteristic? _wifiScanCharacteristic;
  BluetoothCharacteristic? _wifiCredsCharacteristic;
  BluetoothCharacteristic? _userDataCharacteristic;
  // BluetoothCharacteristic? _statusUpdateCharacteristic;

  // Status information
  String _connectedWifi = "Unknown";
  int _batteryLevel = 0;
  final String _wifiStatusMessage = "";

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
  String get wifiStatusMessage => _wifiStatusMessage;
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

    _connectedDevice = device;
    print("🔄 BleManager: Initializing with device: ${device.platformName}");

    // Discover services
    await _discoverServices();

    // Set up status updates
    if (_statusCharacteristic != null) {
      _setupStatusUpdates();
    }
    
    // Set up connection state monitoring
    _monitorDeviceConnection();
  }

  // Monitor device connection state
  void _monitorDeviceConnection() {
    if (_connectedDevice == null) return;
    
    // print("🔄 Setting up device connection monitoring");
    
    _connectedDevice!.connectionState.listen((BluetoothConnectionState state) {
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
      }
    });
  }
  
  // Reset the connection state when device is disconnected
  void _resetConnectionState() {
    _smartyService = null;
    _statusCharacteristic = null;
    _wifiScanCharacteristic = null;
    _wifiCredsCharacteristic = null;
    _userDataCharacteristic = null;
    // _statusUpdateCharacteristic = null;
    _connectedWifi = "NotConnected";
    _connectedDevice = null;
  }

  // Discover services and cache characteristics
  Future<void> _discoverServices() async {
    if (_connectedDevice == null) return;

    try {
      List<BluetoothService> services =
          await _connectedDevice!.discoverServices();
      _smartyService = BleService.findSmartyService(services);

      if (_smartyService != null) {
        // print("✅ BleManager: Found Smarty service: ${_smartyService!.uuid}");

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
        // _statusUpdateCharacteristic = BleService.findCharacteristic(
        //   _smartyService!,
        //   BleService.statusUpdateUuid,
        // );

        // print("✅ BleManager: Cached characteristics:");
        // print(
        //   "  - Status: ${_statusCharacteristic != null ? 'Found' : 'Not found'}",
        // );
        // print(
        //   "  - WiFi Scan: ${_wifiScanCharacteristic != null ? 'Found' : 'Not found'}",
        // );
        // print(
        //   "  - WiFi Creds: ${_wifiCredsCharacteristic != null ? 'Found' : 'Not found'}",
        // );
        // print(
        //   "  - User Data: ${_userDataCharacteristic != null ? 'Found' : 'Not found'}",
        // );
        // print(
        //   "  - Status Update: ${_statusUpdateCharacteristic != null ? 'Found' : 'Not found'}",
        // );
      }
    } catch (e) {
      print("❌ BleManager: Error discovering services: $e");
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

      // Variables for debouncing
      String lastStatusString = "";
      DateTime lastUpdateTime = DateTime.now();

      // Listen for notifications
      _statusCharacteristic!.lastValueStream.listen((value) {
        if (value.isEmpty) {
          // print("⚠️ BleManager: Received empty status notification");
          return;
        }

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
      });

      // Schedule an initial read after a small delay to allow notifications to be set up
      Future.delayed(Duration(milliseconds: 500), () {
        readStatusUpdate();
      });
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

    try {
      // Set up a completer to wait for scan results
      Completer<List<String>> completer = Completer<List<String>>();
      List<String> networkEntries = [];
      bool receivedEndMarker = false;
      int expectedNetworks = 0;
      
      // Enable notifications
      await _wifiScanCharacteristic!.setNotifyValue(true);

      // Listen for notifications
      StreamSubscription<List<int>>? subscription;
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

      // Set a timeout
      Timer(Duration(seconds: 15), () {
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

      return completer.future;
    } catch (e) {
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

  // Dispose resources
  void dispose() {
    // Close stream controllers
    _wifiStatusController.close();
    _batteryStatusController.close();
    _wifiStatusMessageController.close();
    _showSnackBarController.close();
  }
}

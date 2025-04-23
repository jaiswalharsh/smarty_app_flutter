import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
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

  // Status information
  String _connectedWifi = "Unknown";
  String _batteryLevel = "Unknown";
  String _wifiStatusMessage = "";
  String _lastWifiStatus = "Unknown";

  // Stream controllers for status updates
  final _wifiStatusController = StreamController<String>.broadcast();
  final _batteryStatusController = StreamController<String>.broadcast();
  final _wifiStatusMessageController = StreamController<String>.broadcast();
  final _showSnackBarController = StreamController<String>.broadcast();

  // Getters
  BluetoothDevice? get connectedDevice => _connectedDevice;
  BluetoothService? get smartyService => _smartyService;
  String get connectedWifi => _connectedWifi;
  String get batteryLevel => _batteryLevel;
  String get wifiStatusMessage => _wifiStatusMessage;
  Stream<String> get wifiStatusStream => _wifiStatusController.stream;
  Stream<String> get batteryStatusStream => _batteryStatusController.stream;
  Stream<String> get wifiStatusMessageStream =>
      _wifiStatusMessageController.stream;
  Stream<String> get showSnackBarStream => _showSnackBarController.stream;
  bool get isConnected => _connectedDevice != null;
  bool get isWifiConnected =>
      _connectedWifi != "Unknown" &&
      _connectedWifi != "Reset" &&
      _connectedWifi != "NotConnected" &&
      !_connectedWifi.contains("Failed");

  // Initialize the manager with a connected device
  Future<void> initialize(BluetoothDevice device) async {
    if (_connectedDevice == device) {
      // Already initialized with this device
      return;
    }

    _connectedDevice = device;

    // Discover services
    await _discoverServices();

    // Set up status updates
    if (_statusCharacteristic != null) {
      _setupStatusUpdates();
    }
  }

  // Discover services and cache characteristics
  Future<void> _discoverServices() async {
    if (_connectedDevice == null) return;

    try {
      List<BluetoothService> services =
          await _connectedDevice!.discoverServices();
      _smartyService = BleService.findSmartyService(services);

      if (_smartyService != null) {
        print("✅ BleManager: Found Smarty service: ${_smartyService!.uuid}");

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

        print("✅ BleManager: Cached characteristics:");
        print(
          "  - Status: ${_statusCharacteristic != null ? 'Found' : 'Not found'}",
        );
        print(
          "  - WiFi Scan: ${_wifiScanCharacteristic != null ? 'Found' : 'Not found'}",
        );
        print(
          "  - WiFi Creds: ${_wifiCredsCharacteristic != null ? 'Found' : 'Not found'}",
        );
        print(
          "  - User Data: ${_userDataCharacteristic != null ? 'Found' : 'Not found'}",
        );
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
      _statusCharacteristic!.setNotifyValue(true);

      // Variables for debouncing
      String lastStatusString = "";
      DateTime lastUpdateTime = DateTime.now();

      // Listen for notifications
      _statusCharacteristic!.lastValueStream.listen((value) {
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

        print("📊 BleManager: Status update: $statusString");

        // Parse the status string
        Map<String, String> statusValues = WifiUtils.parseStatusUpdate(
          statusString,
        );

        // Update status values
        if (statusValues.containsKey('WIFI')) {
          String newWifiStatus = statusValues['WIFI']!;

          // Only process if the status has changed
          if (newWifiStatus != _lastWifiStatus) {
            _lastWifiStatus = newWifiStatus;
            _connectedWifi = newWifiStatus;
            _wifiStatusController.add(_connectedWifi);

            // Set appropriate status message based on WiFi status
            switch (_connectedWifi) {
              case "Unknown":
                _wifiStatusMessage =
                    "Failed to fetch WiFi status. Please try again.";
                _showSnackBarController.add("WiFi status unknown");
                break;
              case "Reset":
                _wifiStatusMessage =
                    "WiFi reset successful. Ready to connect to a new network.";
                _showSnackBarController.add("WiFi reset successful");
                break;
              case "NotConnected":
                _wifiStatusMessage = "Not connected to any WiFi network.";
                _showSnackBarController.add("WiFi not connected");
                break;
              case "Connection Failed":
                _wifiStatusMessage =
                    "Failed to connect to WiFi. Please try again.";
                _showSnackBarController.add("WiFi connection failed");
                break;
              case "Reset Failed":
                _wifiStatusMessage = "Failed to reset WiFi. Please try again.";
                _showSnackBarController.add("WiFi reset failed");
                break;
              default:
                if (_connectedWifi.contains("Failed")) {
                  _wifiStatusMessage =
                      "WiFi connection failed. Please try again.";
                  _showSnackBarController.add("WiFi connection failed");
                } else {
                  _wifiStatusMessage = "Connected to $_connectedWifi";
                  _showSnackBarController.add("Connected to $_connectedWifi");
                }
            }

            // Send the status message
            _wifiStatusMessageController.add(_wifiStatusMessage);
          }
        }

        if (statusValues.containsKey('BAT')) {
          _batteryLevel = statusValues['BAT']!;
          _batteryStatusController.add(_batteryLevel);
        }
      });

      // Read initial status
      _readStatusUpdate();
    } catch (e) {
      print("❌ BleManager: Error setting up status updates: $e");
    }
  }

  // Read status update (public method)
  Future<void> readStatusUpdate() async {
    return _readStatusUpdate();
  }
  
  // Read status update (private implementation)
  Future<void> _readStatusUpdate() async {
    if (_statusCharacteristic == null) return;

    try {
      List<int> value = await _statusCharacteristic!.read();
      String statusString = String.fromCharCodes(value);

      // If empty, try again
      if (statusString.isEmpty) {
        await Future.delayed(Duration(milliseconds: 500));
        value = await _statusCharacteristic!.read();
        statusString = String.fromCharCodes(value);
      }

      if (statusString.isNotEmpty) {
        Map<String, String> statusValues = WifiUtils.parseStatusUpdate(
          statusString,
        );

        if (statusValues.containsKey('WIFI')) {
          String newWifiStatus = statusValues['WIFI']!;

          // Only process if the status has changed
          if (newWifiStatus != _lastWifiStatus) {
            _lastWifiStatus = newWifiStatus;
            _connectedWifi = newWifiStatus;
            _wifiStatusController.add(_connectedWifi);

            // Set appropriate status message based on WiFi status
            switch (_connectedWifi) {
              case "Unknown":
                _wifiStatusMessage =
                    "Failed to fetch WiFi status. Please try again.";
                _showSnackBarController.add("WiFi status unknown");
                break;
              case "Reset":
                _wifiStatusMessage =
                    "WiFi reset successful. Ready to connect to a new network.";
                _showSnackBarController.add("WiFi reset successful");
                break;
              case "NotConnected":
                _wifiStatusMessage = "Not connected to any WiFi network.";
                _showSnackBarController.add("WiFi not connected");
                break;
              case "Connection Failed":
                _wifiStatusMessage =
                    "Failed to connect to WiFi. Please try again.";
                _showSnackBarController.add("WiFi connection failed");
                break;
              case "Reset Failed":
                _wifiStatusMessage = "Failed to reset WiFi. Please try again.";
                _showSnackBarController.add("WiFi reset failed");
                break;
              default:
                if (_connectedWifi.contains("Failed")) {
                  _wifiStatusMessage =
                      "WiFi connection failed. Please try again.";
                  _showSnackBarController.add("WiFi connection failed");
                } else {
                  _wifiStatusMessage = "Connected to $_connectedWifi";
                  _showSnackBarController.add("Connected to $_connectedWifi");
                }
            }

            // Send the status message
            _wifiStatusMessageController.add(_wifiStatusMessage);
          }
        }

        if (statusValues.containsKey('BAT')) {
          _batteryLevel = statusValues['BAT']!;
          _batteryStatusController.add(_batteryLevel);
        }
      }
    } catch (e) {
      print("❌ BleManager: Error reading status update: $e");
    }
  }

  // Send user data
  Future<bool> sendUserData(String name, String age, String hobby) async {
    if (_userDataCharacteristic == null) {
      print("❌ BleManager: User data characteristic not found");
      return false;
    }

    try {
      // Format the user data
      String userData = "NAME:$name,AGE:$age,HOBBY:$hobby";
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

  // Scan for WiFi networks
  Future<List<String>> scanWifiNetworks() async {
    if (_wifiScanCharacteristic == null) {
      print("❌ BleManager: WiFi scan characteristic not found");
      return [];
    }

    try {
      // Set up a completer to wait for scan results
      Completer<List<String>> completer = Completer<List<String>>();
      Map<int, String> chunks = {};
      int totalChunks = 0;

      // Enable notifications
      await _wifiScanCharacteristic!.setNotifyValue(true);

      // Listen for notifications
      StreamSubscription<List<int>>? subscription;
      subscription = _wifiScanCharacteristic!.lastValueStream.listen((value) {
        if (value.isEmpty) return;

        String chunkData = String.fromCharCodes(value);

        // Parse the chunk format
        if (chunkData.contains('/') && chunkData.contains(':')) {
          int separatorIndex = chunkData.indexOf(':');
          String header = chunkData.substring(0, separatorIndex);
          String data = chunkData.substring(separatorIndex + 1);

          List<String> headerParts = header.split('/');
          if (headerParts.length == 2) {
            int chunkIndex = int.tryParse(headerParts[0]) ?? 0;
            int totalChunksCount = int.tryParse(headerParts[1]) ?? 0;

            if (chunkIndex > 0 && totalChunksCount > 0) {
              chunks[chunkIndex] = data;
              totalChunks = totalChunksCount;

              // Check if we have all chunks
              if (chunks.length == totalChunks) {
                // Combine all chunks
                String completeData = '';
                for (int i = 1; i <= totalChunks; i++) {
                  completeData += chunks[i] ?? '';
                }

                // Process the data
                List<String> networks = WifiUtils.processWifiScanData(
                  completeData,
                );

                // Complete the future
                if (!completer.isCompleted) {
                  completer.complete(networks);
                }

                // Cancel the subscription
                subscription?.cancel();
              }
            }
          }
        } else {
          // Handle non-chunked data
          List<String> networks = WifiUtils.processWifiScanData(chunkData);

          // Complete the future
          if (!completer.isCompleted) {
            completer.complete(networks);
          }

          // Cancel the subscription
          subscription?.cancel();
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
      }

      // Read the characteristic to start receiving notifications
      await _wifiScanCharacteristic!.read();

      // Set a timeout
      Timer(Duration(seconds: 10), () {
        if (!completer.isCompleted) {
          if (chunks.isNotEmpty) {
            // Process whatever chunks we have
            String partialData = '';
            for (int i = 1; i <= totalChunks; i++) {
              if (chunks.containsKey(i)) {
                partialData += chunks[i] ?? '';
              }
            }

            if (partialData.isNotEmpty) {
              List<String> networks = WifiUtils.processWifiScanData(
                partialData,
              );
              completer.complete(networks);
            } else {
              completer.complete([]);
            }
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

  // Dispose resources
  void dispose() {
    _wifiStatusController.close();
    _batteryStatusController.close();
    _wifiStatusMessageController.close();
    _showSnackBarController.close();
  }
}

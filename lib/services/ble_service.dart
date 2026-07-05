import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:app_settings/app_settings.dart';

// Why a Smarty scan produced no devices — lets the connect UI show an
// actionable fix (turn on Bluetooth / grant permission) instead of a dead-end
// "nothing found". `none` means the scan ran normally (there just may be no
// toy nearby / in pairing mode).
enum BleScanIssue { none, bluetoothOff, permissionDenied, unsupported, unknown }

class BleService {
  // BLE UUIDs
  static const String smartyServiceUuid = "0000abcd-0000-1000-8000-00805f9b34fb";
  static const String wifiScanUuid = "0000ab01-0000-1000-8000-00805f9b34fb";
  static const String wifiCredsUuid = "0000ab02-0000-1000-8000-00805f9b34fb";
  static const String userDataUuid = "0000ab03-0000-1000-8000-00805f9b34fb";
  static const String statusUpdateUuid = "0000ab04-0000-1000-8000-00805f9b34fb";

  // Bluetooth dialog functionality
  static BuildContext? _globalContext;
  static bool _isShowingDialog = false;
  static bool _userDismissedDialog = false;
  
  // Initialize global context for BLE service
  static void initialize(BuildContext context) {
    _globalContext = context;
    _isShowingDialog = false;
    _userDismissedDialog = false;
  }
  
  // Check Bluetooth and prompt if needed (uses system dialog only)
  static Future<bool> ensureBluetoothEnabled(BuildContext context) async {
    bool ready = await isBluetoothReady();
    if (!ready) {
      // Just use the native FlutterBluePlus.turnOn() which will show the iOS system dialog
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        print("⚠️ Error requesting Bluetooth enable: $e");
      }
      
      // Check if Bluetooth is now enabled
      ready = await isBluetoothReady();
    }
    return ready;
  }

  // Check if Bluetooth is available and enabled
  static Future<BluetoothAdapterState> getBluetoothState() async {
    return await FlutterBluePlus.adapterState.first;
  }

  // Stream to monitor Bluetooth state changes
  static Stream<BluetoothAdapterState> getBluetoothStateChanges() {
    return FlutterBluePlus.adapterState;
  }

  // Request to turn on Bluetooth
  static Future<bool> requestBluetoothEnable() async {
    try {
      print("🔄 Attempting to turn on Bluetooth...");
      
      // First check if we're already on
      BluetoothAdapterState currentState = await getBluetoothState();
      if (currentState == BluetoothAdapterState.on) {
        return true;
      }
      
      // Try to use the native approach first
      try {
        await FlutterBluePlus.turnOn();
      } catch (e) {
        print("Native Bluetooth enabling failed: $e");
        
        // If the native approach fails, open system Bluetooth settings
        await _openBluetoothSettings();
      }
      
      // We can't know when the user returns or if they enabled Bluetooth
      // So we return false and let the caller check the Bluetooth state later
      return false;
    } catch (e) {
      print("❌ Error requesting Bluetooth enable: $e");
      return false;
    }
  }

  // Attempt to open Bluetooth settings directly
  static Future<void> _openBluetoothSettings() async {
    try {
      await AppSettings.openAppSettings(type: AppSettingsType.bluetooth);
    } catch (e) {
      print('❌ Error opening Bluetooth settings: $e');
    }
  }
  
  // Public method to open Bluetooth settings
  static Future<void> openBluetoothSettings() async {
    await _openBluetoothSettings();
  }

  // Open this app's own settings page, where the user can grant the Bluetooth
  // permission they previously denied.
  static Future<void> openAppPermissionSettings() =>
      AppSettings.openAppSettings(type: AppSettingsType.settings);

  // Check if Bluetooth is ready for scanning
  static Future<bool> isBluetoothReady() async {
    BluetoothAdapterState state = await getBluetoothState();
    return state == BluetoothAdapterState.on;
  }

  // Find a specific service in a list of services
  static BluetoothService? findSmartyService(List<BluetoothService> services) {
    for (BluetoothService service in services) {
      if (service.uuid.toString().toUpperCase().contains("ABCD") ||
          service.uuid.toString() == smartyServiceUuid) {
        // print("✅ Found potential Smarty service: ${service.uuid.toString()}");
        return service;
      }
    }
    return null;
  }

  // Find a characteristic by UUID pattern in a service
  static BluetoothCharacteristic? findCharacteristic(
    BluetoothService service,
    String uuidPattern,
  ) {
    for (BluetoothCharacteristic characteristic in service.characteristics) {
      String charUuid = characteristic.uuid.toString();
      if (charUuid.toLowerCase().contains(uuidPattern.toLowerCase())) {
        // print("✅ Found characteristic matching $uuidPattern: $charUuid");
        return characteristic;
      }
    }
    return null;
  }

  // Scan for BLE devices with "Smarty" in the name with Bluetooth check and prompt
  static Stream<List<ScanResult>> scanForSmartyDevicesWithPrompt(BuildContext context) {
    StreamController<List<ScanResult>> controller = StreamController<List<ScanResult>>();

    () async {
      try {
        bool isEnabled = await ensureBluetoothEnabled(context);
        if (!isEnabled) {
          print("⚠️ Bluetooth is not enabled after prompt. Cannot scan.");
          controller.add([]);
          return;
        }
        await _performScan(controller);
      } catch (e) {
        print("❌ Error in scanForSmartyDevicesWithPrompt: $e");
      } finally {
        if (!controller.isClosed) controller.close();
      }
    }();

    return controller.stream;
  }

  // Scan for BLE devices with "Smarty" in the name
  static Stream<List<ScanResult>> scanForSmartyDevices() {
    StreamController<List<ScanResult>> controller = StreamController<List<ScanResult>>();

    () async {
      try {
        bool isReady = await isBluetoothReady();
        if (!isReady) {
          print("⚠️ Bluetooth is not ready for scanning");

          // Try native Bluetooth enabling if we have a global context
          if (_globalContext != null && _globalContext!.mounted) {
            FlutterBluePlus.turnOn();
          }

          controller.add([]);
          return;
        }
        await _performScan(controller);
      } catch (e) {
        print("❌ Error in scanForSmartyDevices: $e");
      } finally {
        if (!controller.isClosed) controller.close();
      }
    }();

    return controller.stream;
  }
  
  // Scan for BLE devices with "Smarty" in the name and call a callback for each
  // discovered device. Returns WHY the scan found nothing (BleScanIssue.none on
  // a normal scan) so the caller can steer the user to fix a Bluetooth/
  // permission dead-end instead of showing a silent "nothing found".
  static Future<BleScanIssue> scanForSmartyDevicesWithCallback(Function(ScanResult) onDeviceDiscovered) async {
    // Classify blockers BEFORE scanning so we never mistake "can't scan" for
    // "no toy nearby".
    if (!await FlutterBluePlus.isSupported) {
      print("⚠️ Bluetooth is not supported on this device");
      return BleScanIssue.unsupported;
    }
    final BluetoothAdapterState state = await FlutterBluePlus.adapterState.first;
    if (state == BluetoothAdapterState.off ||
        state == BluetoothAdapterState.turningOff) {
      print("⚠️ Bluetooth is off — cannot scan");
      return BleScanIssue.bluetoothOff;
    }
    if (state == BluetoothAdapterState.unauthorized) {
      print("⚠️ Bluetooth permission denied — cannot scan");
      return BleScanIssue.permissionDenied;
    }

    StreamSubscription? subscription;
    try {
      // Stop any ongoing scan first
      await FlutterBluePlus.stopScan();

      // Start a new scan
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
      print("✅ Started scanning for BLE devices with callback");

      // Subscribe to scan results
      subscription = FlutterBluePlus.scanResults.listen((results) {
        final smartyResults = results
            .where(
              (result) =>
                  result.device.platformName.isNotEmpty &&
                  result.device.platformName.toLowerCase().contains("smarty"),
            )
            .toList();

        // Call the callback for each Smarty device
        for (var result in smartyResults) {
          onDeviceDiscovered(result);
        }
      });

      // Wait for scan to complete
      await Future.delayed(const Duration(seconds: 5));
      return BleScanIssue.none;
    } catch (e) {
      // flutter_blue_plus requests Android runtime permissions on startScan and
      // THROWS when they're denied — classify that so the caller can point the
      // user at app settings rather than a generic error.
      final String msg = e.toString().toLowerCase();
      if (msg.contains('permission') || msg.contains('denied')) {
        print("⚠️ Scan blocked by permission: $e");
        return BleScanIssue.permissionDenied;
      }
      print("❌ Error in scanForSmartyDevicesWithCallback: $e");
      return BleScanIssue.unknown;
    } finally {
      subscription?.cancel();
      await FlutterBluePlus.stopScan();
    }
  }
  
  // Helper method to perform the scan. Controller is closed by the caller.
  static Future<void> _performScan(StreamController<List<ScanResult>> controller) async {
    StreamSubscription? subscription;
    try {
      // Stop any ongoing scan first
      await FlutterBluePlus.stopScan();

      // Then start a new scan
      await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
      print("✅ Started scanning for BLE devices");

      // Subscribe to scan results
      subscription = FlutterBluePlus.scanResults.listen((results) {
        final smartyResults = results
            .where(
              (result) =>
                  result.device.platformName.isNotEmpty &&
                  result.device.platformName.toLowerCase().contains("smarty"),
            )
            .toList();

        if (smartyResults.isNotEmpty) {
          print("🔍 Found ${smartyResults.length} Smarty devices in this scan");
        }

        if (!controller.isClosed) {
          controller.add(smartyResults);
        }
      });

      // Wait for scan to complete
      await Future.delayed(const Duration(seconds: 5));
    } finally {
      subscription?.cancel();
    }
  }

  // Stop scanning
  static Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  // Get already connected devices with Bluetooth check and prompt
  static Future<List<BluetoothDevice>> getConnectedDevicesWithPrompt(BuildContext context) async {
    try {
      // Ensure Bluetooth is enabled with UI prompt
      bool isEnabled = await ensureBluetoothEnabled(context);
      if (!isEnabled) {
        print("⚠️ Bluetooth is not enabled after prompt. Cannot get connected devices.");
        return [];
      }
      
      return await _getConnectedDevicesInternal();
    } catch (e) {
      print("❌ Error getting connected devices: $e");
      return [];
    }
  }

  // Get already connected devices
  static Future<List<BluetoothDevice>> getConnectedDevices() async {
    try {
      // Check if Bluetooth is ready
      bool isReady = await isBluetoothReady();
      if (!isReady) {
        print("⚠️ Bluetooth is not enabled. Cannot get connected devices.");
        
        // Try native Bluetooth enabling if we have a global context
        if (_globalContext != null && _globalContext!.mounted) {
          // Just trigger the system prompt directly
          FlutterBluePlus.turnOn();
        }
        
        return [];
      }
      
      return await _getConnectedDevicesInternal();
    } catch (e) {
      print("❌ Error getting connected devices: $e");
      return [];
    }
  }
  
  // Internal method for getting connected devices.
  //
  // Returns only devices the OS already reports as connected, filtered to Smarty.
  // It deliberately does NOT scan for and auto-connect to arbitrary nearby
  // "smarty"-named devices (APP-3) — in a household/building with more than one
  // Smarty that silently attached the app to the wrong unit. Reconnecting to the
  // user's OWN device is handled by autoReconnectToSavedDevice(), which targets
  // the saved remoteId; discovering a new device is user-driven via the scan UI.
  static Future<List<BluetoothDevice>> _getConnectedDevicesInternal() async {
    final connectedDevices = FlutterBluePlus.connectedDevices
        .where((d) => d.platformName.toLowerCase().contains("smarty"))
        .toList();

    if (connectedDevices.isNotEmpty) {
      print("✅ Connected Smarty devices: ${connectedDevices.length}");
    }

    return connectedDevices;
  }
  
  // Check for any connected Smarty devices with Bluetooth check and prompt
  static Future<List<Map<String, dynamic>>> checkForSmartyDevicesWithPrompt(BuildContext context) async {
    // Ensure Bluetooth is enabled with UI prompt
    bool isEnabled = await ensureBluetoothEnabled(context);
    if (!isEnabled) {
      print("⚠️ Bluetooth is not enabled after prompt. Cannot check for Smarty devices.");
      return [];
    }
    
    return await _checkForSmartyDevicesInternal();
  }
  
  // Check for any connected devices with "Smarty" in the name and ABCD service UUID
  static Future<List<Map<String, dynamic>>> checkForSmartyDevicesWithService() async {
    // Check if Bluetooth is ready
    bool isReady = await isBluetoothReady();
    if (!isReady) {
      print("⚠️ Bluetooth is not enabled. Cannot check for Smarty devices.");
      
      // Try native Bluetooth enabling if we have a global context
      if (_globalContext != null && _globalContext!.mounted) {
        // Just trigger the system prompt directly
        FlutterBluePlus.turnOn();
      }
      
      return [];
    }
    
    return await _checkForSmartyDevicesInternal();
  }
  
  // Internal method for Smarty device checking
  static Future<List<Map<String, dynamic>>> _checkForSmartyDevicesInternal() async {
    List<Map<String, dynamic>> results = [];
    
    try {
      // print("🔍 Looking for connected Smarty devices with ABCD service...");
      
      // First get all connected devices
      List<BluetoothDevice> connectedDevices = FlutterBluePlus.connectedDevices;
      
      // If no devices in cache, scan for nearby devices
      if (connectedDevices.isEmpty) {
        // print("No devices in connected cache, scanning for nearby devices...");
        
        // Verify Bluetooth is still ready before scanning
        bool isReady = await isBluetoothReady();
        if (!isReady) {
          print("⚠️ Bluetooth is not enabled. Cannot scan for devices.");
          return [];
        }
        
        await FlutterBluePlus.startScan(timeout: Duration(seconds: 3));
        await Future.delayed(Duration(seconds: 3));
        
        // Get scan results
        final scanResults = FlutterBluePlus.lastScanResults;
        
        // Filter for devices with "Smarty" in the name
        final smartyResults = scanResults
            .where((result) => 
              result.device.platformName.toLowerCase().contains("smarty"))
            .toList();
            
        if (smartyResults.isNotEmpty) {
          print("Found ${smartyResults.length} Smarty devices in scan");
          for (var result in smartyResults) {
            connectedDevices.add(result.device);
          }
        }
        
        await FlutterBluePlus.stopScan();
      }
      
      // print("Examining ${connectedDevices.length} connected devices...");
      
      // Check each connected device for the ABCD service
      for (var device in connectedDevices) {
        // print("Checking device: ${device.platformName} (${device.remoteId})");
        
        try {
          // Connect if not already connected
          if (!device.isConnected) {
            print("  - Connecting to ${device.platformName}...");
            await device.connect(timeout: Duration(seconds: 5));
          }
          
          // Discover services
          // print("  - Discovering services...");
          List<BluetoothService> services = await device.discoverServices();
          // print("  - Found ${services.length} services");
          
          // Look for ABCD service
          BluetoothService? smartyService;
          List<Map<String, dynamic>> serviceCharacteristics = [];
          
          for (var service in services) {
            // print("  - Service: ${service.uuid}");
            
            if (service.uuid.toString().toUpperCase().contains("ABCD")) {
              smartyService = service;
              print("  - ✅ Found ABCD service: ${service.uuid}");
              
              // Get characteristics
              for (var characteristic in service.characteristics) {
                String uuid = characteristic.uuid.toString();
                
                // Create properties description
                List<String> properties = [];
                if (characteristic.properties.read) properties.add("Read");
                if (characteristic.properties.write) properties.add("Write");
                if (characteristic.properties.writeWithoutResponse) properties.add("WriteNoResp");
                if (characteristic.properties.notify) properties.add("Notify");
                if (characteristic.properties.indicate) properties.add("Indicate");
                
                // print("    - Characteristic: $uuid (${properties.join(", ")})");
                
                // Add to list
                serviceCharacteristics.add({
                  'uuid': uuid,
                  'properties': properties.join(", ")
                });
              }
              
              break;
            }
          }
          
          // Check all services for any that have "AB" characteristics (potential Smarty)
          bool hasPotentialSmartyCharacteristics = false;
          for (var service in services) {
            for (var characteristic in service.characteristics) {
              String uuid = characteristic.uuid.toString().toUpperCase();
              if (uuid.contains("AB01") || uuid.contains("AB02") || 
                  uuid.contains("AB03") || uuid.contains("AB04")) {
                hasPotentialSmartyCharacteristics = true;
                print("  - ⚠️ Found potential Smarty characteristic in different service: $uuid");
              }
            }
          }
          
          // Add to results
          Map<String, dynamic> deviceInfo = {
            'device': device,
            'name': device.platformName,
            'id': device.remoteId.toString(),
            'hasSmartySevice': smartyService != null,
            'serviceUuid': smartyService?.uuid.toString() ?? 'Not found',
            'characteristics': serviceCharacteristics,
            'hasPotentialSmartyCharacteristics': hasPotentialSmartyCharacteristics
          };
          
          results.add(deviceInfo);
          
          // If this isn't a Smarty device, disconnect to save resources
          if (smartyService == null && !device.platformName.toLowerCase().contains("smarty")) {
            print("  - Not a Smarty device, disconnecting...");
            device.disconnect();
          }
        } catch (e) {
          print("  - ❌ Error checking device ${device.platformName}: $e");
        }
      }
      
      // Log summary
      print("📋 Device inspection summary:");
      for (var deviceInfo in results) {
        print("  - ${deviceInfo['name']} (${deviceInfo['id']}): ${deviceInfo['hasSmartySevice'] ? '✅ Has ABCD service' : '❌ No ABCD service found'}");
        if (deviceInfo['hasPotentialSmartyCharacteristics']) {
          print("    ⚠️ Has potential Smarty characteristics");
        }
      }
      
      return results;
    } catch (e) {
      print("❌ Error checking for Smarty devices: $e");
      return [];
    }
  }
}

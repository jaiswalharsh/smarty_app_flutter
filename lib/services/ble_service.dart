import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:app_settings/app_settings.dart';

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
    
    ensureBluetoothEnabled(context).then((isEnabled) {
      if (!isEnabled) {
        print("⚠️ Bluetooth is not enabled after prompt. Cannot scan.");
        controller.add([]);
        controller.close();
        return;
      }
      
      // Continue with scanning since Bluetooth is enabled
      _performScan(controller);
    });
    
    return controller.stream;
  }

  // Scan for BLE devices with "Smarty" in the name
  static Stream<List<ScanResult>> scanForSmartyDevices() {
    StreamController<List<ScanResult>> controller = StreamController<List<ScanResult>>();
    
    isBluetoothReady().then((isReady) {
      if (!isReady) {
        print("⚠️ Bluetooth is not ready for scanning");
        
        // Try native Bluetooth enabling if we have a global context
        if (_globalContext != null && _globalContext!.mounted) {
          // Just trigger the system prompt directly
          FlutterBluePlus.turnOn();
        }
        
        controller.add([]);
        controller.close();
        return;
      }
      
      _performScan(controller);
    });
    
    return controller.stream;
  }
  
  // Scan for BLE devices with "Smarty" in the name and call a callback for each discovered device
  static Future<void> scanForSmartyDevicesWithCallback(Function(ScanResult) onDeviceDiscovered) async {
    if (!await isBluetoothReady()) {
      print("⚠️ Bluetooth is not ready for scanning");
      return;
    }
    
    // Stop any ongoing scan first
    await FlutterBluePlus.stopScan();
    
    // Start a new scan
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
    print("✅ Started scanning for BLE devices with callback");
    
    // Subscribe to scan results
    var subscription = FlutterBluePlus.scanResults.listen((results) {
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
    
    // Wait for scan to complete and then cancel subscription
    await Future.delayed(const Duration(seconds: 5));
    subscription.cancel();
    await FlutterBluePlus.stopScan();
  }
  
  // Helper method to perform the scan
  static void _performScan(StreamController<List<ScanResult>> controller) {
    // Stop any ongoing scan first
    FlutterBluePlus.stopScan().then((_) {
      // Then start a new scan
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 4)).then((_) {
        print("✅ Started scanning for BLE devices");
        
        // Subscribe to scan results
        var subscription = FlutterBluePlus.scanResults.listen((results) {
          final smartyResults = results
              .where(
                (result) =>
                    result.device.platformName.isNotEmpty &&
                    result.device.platformName.toLowerCase().contains("smarty"),
              )
              .toList();
          
          // Log found devices for debugging
          if (smartyResults.isNotEmpty) {
            print("🔍 Found ${smartyResults.length} Smarty devices in this scan");
          }
          
          controller.add(smartyResults);
        });
        
        // Close the controller when the scan is done
        Future.delayed(const Duration(seconds: 5), () {
          subscription.cancel();
          controller.close();
        });
      });
    });
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
  
  // Internal method for getting connected devices
  static Future<List<BluetoothDevice>> _getConnectedDevicesInternal() async {
    // Get the list of connected devices from the cache
    List<BluetoothDevice> connectedDevices = FlutterBluePlus.connectedDevices;
    
    // If no devices found in cache, try to get system-connected devices
    if (connectedDevices.isEmpty) {
      // print("🔄 No devices in cache, trying additional methods...");
      
      try {
        // Try to reconnect to previously known devices by scanning 
        print("📱 Scanning for nearby Smarty devices to reconnect...");
        
        // Verify Bluetooth is still ready before scanning
        bool isReady = await isBluetoothReady();
        if (!isReady) {
          print("⚠️ Bluetooth is not enabled. Cannot scan for devices.");
          return [];
        }
        
        await FlutterBluePlus.startScan(timeout: Duration(seconds: 2));
        
        // Wait for 2 seconds to allow scan to complete
        await Future.delayed(Duration(seconds: 2));
        
        // Get scan results
        final results = FlutterBluePlus.lastScanResults;
        
        // Filter for Smarty devices
        final smartyResults = results
            .where((result) => 
                result.device.platformName.isNotEmpty && 
                result.device.platformName.toLowerCase().contains("smarty"))
            .toList();
            
        if (smartyResults.isNotEmpty) {
          print("✅ Found ${smartyResults.length} nearby Smarty devices");
          
          for (var result in smartyResults) {
            BluetoothDevice device = result.device;
            // print("  - ${device.platformName} (${device.remoteId})");
            
            // Check if it's already connected
            if (!device.isConnected) {
              try {
                // Attempt to connect
                print("🔄 Attempting to connect to ${device.platformName}...");
                await device.connect();
                print("✅ Connected to ${device.platformName}");
              } catch (e) {
                print("⚠️ Connection attempt to ${device.platformName} failed: $e");
              }
            } else {
              // print("✅ ${device.platformName} is already connected");
            }
          }
          
          // Update connected devices list
          connectedDevices = FlutterBluePlus.connectedDevices;
        }
        
        // Stop the scan
        await FlutterBluePlus.stopScan();
      } catch (e) {
        print("⚠️ Error during scan and connect: $e");
      }
    }
    
    // Log the final list of connected devices
    if (connectedDevices.isNotEmpty) {
      print("✅ Connected devices count: ${connectedDevices.length}");
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

import 'package:flutter_blue_plus/flutter_blue_plus.dart';

class BleService {
  // BLE UUIDs
  static const String smartyServiceUuid = "0000abcd-0000-1000-8000-00805f9b34fb";
  static const String wifiScanUuid = "0000ab01-0000-1000-8000-00805f9b34fb";
  static const String wifiCredsUuid = "0000ab02-0000-1000-8000-00805f9b34fb";
  static const String userDataUuid = "0000ab03-0000-1000-8000-00805f9b34fb";
  static const String statusUpdateUuid = "0000ab04-0000-1000-8000-00805f9b34fb";

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

  // Scan for BLE devices with "Smarty" in the name
  static Stream<List<ScanResult>> scanForSmartyDevices() {
    // Stop any ongoing scan first
    FlutterBluePlus.stopScan().then((_) {
      // Then start a new scan
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));
      // print("✅ Started scanning for BLE devices");
    });

    // Filter for devices with "Smarty" in the name
    return FlutterBluePlus.scanResults.map((results) {
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
        // for (var result in smartyResults) {
        //   print("  - ${result.device.platformName} (${result.device.remoteId}), RSSI: ${result.rssi}");
        // }
      }
      
      return smartyResults;
    });
  }

  // Stop scanning
  static Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  // Get already connected devices
  static Future<List<BluetoothDevice>> getConnectedDevices() async {
    try {
      // Get the list of connected devices from the cache
      List<BluetoothDevice> connectedDevices = FlutterBluePlus.connectedDevices;
      
      // If no devices found in cache, try to get system-connected devices
      if (connectedDevices.isEmpty) {
        // print("🔄 No devices in cache, trying additional methods...");
        
        try {
          // Try to reconnect to previously known devices by scanning 
          // print("📱 Scanning for nearby Smarty devices to reconnect...");
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
        // for (var device in connectedDevices) {
        //   print("  - ${device.platformName} (${device.remoteId})");
        // }
      }
      
      return connectedDevices;
    } catch (e) {
      print("❌ Error getting connected devices: $e");
      return [];
    }
  }
  
  // Check for any connected devices with "Smarty" in the name and ABCD service UUID
  static Future<List<Map<String, dynamic>>> checkForSmartyDevicesWithService() async {
    List<Map<String, dynamic>> results = [];
    
    try {
      // print("🔍 Looking for connected Smarty devices with ABCD service...");
      
      // First get all connected devices
      List<BluetoothDevice> connectedDevices = FlutterBluePlus.connectedDevices;
      
      // If no devices in cache, scan for nearby devices
      if (connectedDevices.isEmpty) {
        // print("No devices in connected cache, scanning for nearby devices...");
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

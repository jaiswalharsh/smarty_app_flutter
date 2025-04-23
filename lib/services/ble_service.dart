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
        print("✅ Found potential Smarty service: ${service.uuid.toString()}");
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
        print("✅ Found characteristic matching $uuidPattern: $charUuid");
        return characteristic;
      }
    }
    return null;
  }

  // Scan for BLE devices with "Smarty" in the name
  static Stream<List<ScanResult>> scanForSmartyDevices() {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 4));

    // Filter for devices with "Smarty" in the name
    return FlutterBluePlus.scanResults.map((results) {
      return results
          .where(
            (result) =>
                result.device.platformName.isNotEmpty &&
                result.device.platformName.toLowerCase().contains("smarty"),
          )
          .toList();
    });
  }

  // Stop scanning
  static Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
  }

  // Get already connected devices
  static List<BluetoothDevice> getConnectedDevices() {
    try {
      // Get the list of connected devices
      List<BluetoothDevice> connectedDevices = FlutterBluePlus.connectedDevices;
      
      // Log the connected devices
      print("✅ Found ${connectedDevices.length} connected devices:");
      for (var device in connectedDevices) {
        print("  - ${device.platformName} (${device.remoteId})");
      }
      
      return connectedDevices;
    } catch (e) {
      print("❌ Error getting connected devices: $e");
      return [];
    }
  }
}

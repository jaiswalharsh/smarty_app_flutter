import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/ble_service.dart';

class WifiUtils {
  // Process the WiFi scan data and extract network names
  static List<String> processWifiScanData(String wifiString) {
    print("🔍 Processing WiFi scan data: $wifiString");

    // Parse the WiFi networks
    // Format from ESP: "WiFimodem-9E68:-58,3|WiFi5666sxk:-61,3|..."
    List<String> networks = [];

    // Split by the pipe character if present, otherwise by comma
    List<String> rawNetworks =
        wifiString.contains('|')
            ? wifiString.split('|')
            : wifiString.split(',');

    for (String rawNetwork in rawNetworks) {
      // Extract just the SSID (before the colon if present)
      String ssid =
          rawNetwork.contains(':')
              ? rawNetwork.split(':')[0].trim()
              : rawNetwork.trim();

      // Skip empty SSIDs
      if (ssid.isNotEmpty) {
        networks.add(ssid);
      }
    }

    print("📶 Extracted ${networks.length} WiFi networks: $networks");
    return networks;
  }

  // Show password dialog for WiFi connection
  static Future<String?> showPasswordDialog(
    BuildContext context,
    String network,
  ) async {
    final Completer<String?> completer = Completer<String?>();

    showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        final TextEditingController passwordController =
            TextEditingController();
        return AlertDialog(
          title: Text('Connect to $network'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: passwordController,
                  decoration: InputDecoration(
                    labelText: 'WiFi Password',
                    border: OutlineInputBorder(),
                  ),
                  obscureText: true,
                  autofocus: true,
                  onSubmitted: (value) {
                    Navigator.of(dialogContext).pop(value);
                  },
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              child: Text('Cancel'),
              onPressed: () {
                Navigator.of(dialogContext).pop(null);
              },
            ),
            TextButton(
              child: Text('Connect'),
              onPressed: () {
                Navigator.of(dialogContext).pop(passwordController.text);
              },
            ),
          ],
        );
      },
    ).then((value) {
      completer.complete(value);
    });

    return completer.future;
  }

  // Connect to WiFi by sending credentials to the ESP32
  static Future<bool> connectToWifi(
    BluetoothService service,
    String ssid,
    String password,
    Function(String) onStatusUpdate,
  ) async {
    onStatusUpdate('Connecting to WiFi...');

    try {
      // Find the WiFi credentials characteristic
      BluetoothCharacteristic? wifiCredsCharacteristic =
          BleService.findCharacteristic(service, "ab02");

      if (wifiCredsCharacteristic != null) {
        // Format the credentials string
        String creds = '$ssid,$password';
        print("📡 Sending WiFi credentials for SSID: $ssid");
        List<int> value = utf8.encode(creds);

        // Write the credentials to the characteristic
        await wifiCredsCharacteristic.write(value, withoutResponse: false);

        onStatusUpdate('Successfully connected to WiFi!');
        return true;
      } else {
        print("❌ WiFi credentials characteristic not found");
        onStatusUpdate('WiFi credentials characteristic not found.');
        return false;
      }
    } catch (e) {
      print("❌ Error connecting to WiFi: $e");
      onStatusUpdate('Failed to connect to WiFi: $e');
      return false;
    }
  }

  // Parse status update from the ESP32
  static Map<String, String> parseStatusUpdate(String statusString) {
    Map<String, String> statusValues = {};

    // Handle empty status string
    if (statusString.isEmpty) {
      return statusValues;
    }

    print("🔄 Parsing status update: $statusString");
    List<String> parts = statusString.split(',');

    for (String part in parts) {
      List<String> keyValue = part.split(':');
      if (keyValue.length == 2) {
        String key = keyValue[0].trim();
        String value = keyValue[1].trim();
        statusValues[key] = value;
        print("📊 Parsed status: $key = $value");
      }
    }

    return statusValues;
  }
}

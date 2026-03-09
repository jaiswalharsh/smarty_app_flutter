import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../services/ble_service.dart';

class WifiUtils {
  // Process the WiFi scan data and extract network information
  // New format: 
  // - First notification: "TOTAL:N" where N is the total number of access points
  // - For each AP (1 to N): "i:SSID:RSSI,AUTH" 
  // - Final notification: "END" to indicate completion
  static List<String> processWifiScanData(String data) {
    List<String> networks = [];
    
    try {
      if (data.isEmpty) {
        print("📶 Empty WiFi scan data received");
        return networks;
      }
      
      // Log the raw data for debugging
      // print("📶 Processing WiFi scan data: $data");
      
      // Split the data by newlines or commas for compatibility with old and new formats
      List<String> lines = data.contains('\n') ? data.split('\n') : data.split(',');
      
      // print("📶 Split into ${lines.length} lines");
      
      for (String line in lines) {
        String trimmedLine = line.trim();
        if (trimmedLine.isEmpty) {
          // print("📶 Skipping empty line");
          continue;
        }
        
        // Check if this is the first line with the total count
        if (trimmedLine.startsWith("TOTAL:")) {
          // print("📶 Found TOTAL line: $trimmedLine");
          // This is just the header indicating total networks, skip adding to results
          continue;
        }
        
        // Check if this is the end marker
        if (trimmedLine == "END") {
          // print("📶 Found END marker");
          // This is just the end marker, skip adding to results
          continue;
        }
        
        // print("📶 Processing line: $trimmedLine");
        
        // Try to parse as new format: "i:SSID:RSSI,AUTH"
        if (trimmedLine.contains(":")) {
          List<String> parts = trimmedLine.split(":");
          // print("📶 Split into ${parts.length} parts: $parts");
          
          if (parts.length >= 3) {
            // Extract the SSID
            String ssid = parts[1];
            
            // Skip networks with empty SSIDs
            if (ssid.trim().isEmpty) {
              // print("📶 Skipping network with empty SSID: $trimmedLine");
              continue;
            }
            
            // Just use the SSID without signal strength information
            String networkEntry = ssid;
            
            // print("📶 Adding network: $networkEntry");
            networks.add(networkEntry);
            continue;
          } else {
            // print("📶 Not enough parts in line: $trimmedLine");
          }
        } else {
          // print("📶 Line doesn't contain colon: $trimmedLine");
        }
        
        // If we get here, it's either old format or something else, just add the whole line
        // But skip empty SSIDs
        if (!trimmedLine.startsWith("TOTAL:") && trimmedLine != "END" && trimmedLine.trim().isNotEmpty) {
          // print("📶 Adding network from old format: $trimmedLine");
          networks.add(trimmedLine);
        }
      }
      
      // Remove any duplicate entries
      networks = networks.toSet().toList();
      
      // Sort networks by name
      networks.sort();
      
      print("📶 Processed ${networks.length} networks");
    } catch (e) {
      print("❌ Error processing WiFi scan data: $e");
    }
    
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
        
        // Set a listener for the status characteristic to check for auth failures
        BluetoothCharacteristic? statusCharacteristic =
            BleService.findCharacteristic(service, "ab04");
            
        if (statusCharacteristic != null) {
          // Listen for notifications for 10 seconds to catch auth failures
          bool authFailed = false;
          StreamSubscription<List<int>>? subscription;
          
          subscription = statusCharacteristic.lastValueStream.listen(
            (value) {
              if (value.isEmpty) return;

              String statusString = String.fromCharCodes(value);
              Map<String, String> statusValues = parseStatusUpdate(statusString);

              if (statusValues.containsKey('WIFI') &&
                  statusValues['WIFI'] == "AuthFailed") {
                authFailed = true;
                onStatusUpdate('Authentication failed. Please check your WiFi password.');
                subscription?.cancel();
              }
            },
            onError: (error) {
              print("⚠️ WifiUtils: Status stream error during auth check: $error");
              subscription = null;
            },
          );

          // Wait for a short time to see if auth fails
          await Future.delayed(Duration(seconds: 5));
          subscription?.cancel();
          
          if (authFailed) {
            return false;
          }
        }

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

  // Parse status update from the device
  static Map<String, String> parseStatusUpdate(String statusString) {
    Map<String, String> result = {};

    List<String> parts = statusString.split(',');

    // First part is the WiFi status
    if (parts.isNotEmpty) {
      result['WIFI'] = parts[0];
    }

    // Second part is the battery level
    if (parts.length > 1) {
      result['BAT'] = parts[1];
    }

    return result;
  }

  // Get a user-friendly message based on WiFi status
  static String getWifiStatusMessage(String wifiStatus) {
    switch (wifiStatus) {
      case "Initializing":
        return "WiFi is initializing...";
      case "Init":
        return "WiFi is initializing...";
      case "NotConnected":
        return "WiFi is not connected";
      case "AuthFailed":
        return "WiFi password incorrect";
      case "Reset":
        return "WiFi has been reset";
      case "Reset Failed":
        return "Failed to reset WiFi";
      case "Unknown":
        return "WiFi status unknown";
      default:
        if (wifiStatus.contains("Failed")) {
          return "WiFi connection failed";
        } else {
          return "Connected to $wifiStatus";
        }
    }
  }
}

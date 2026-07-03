import 'dart:async';
import 'package:flutter/material.dart';

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

      // Split the data by newlines or commas for compatibility with old and new formats
      List<String> lines = data.contains('\n') ? data.split('\n') : data.split(',');

      for (String line in lines) {
        String trimmedLine = line.trim();
        if (trimmedLine.isEmpty) {
          continue;
        }

        // Skip header/footer markers
        if (trimmedLine.startsWith("TOTAL:") || trimmedLine == "END") {
          continue;
        }

        // Try to parse as new format: "i:SSID:RSSI,AUTH"
        if (trimmedLine.contains(":")) {
          List<String> parts = trimmedLine.split(":");

          if (parts.length >= 3) {
            // Extract the SSID
            String ssid = parts[1];

            // Skip networks with empty SSIDs
            if (ssid.trim().isEmpty) {
              continue;
            }

            networks.add(ssid);
            continue;
          }
        }

        // Old format or something else — add the whole line (skipping empties)
        if (trimmedLine.isNotEmpty) {
          networks.add(trimmedLine);
        }
      }

      // Remove duplicates and sort
      networks = networks.toSet().toList();
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
    // Owned here (not inside the builder) so it can be disposed after the dialog
    // resolves — the previous version leaked a TextEditingController per dialog (APP-9).
    final TextEditingController passwordController = TextEditingController();

    final result = await showDialog<String?>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
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
    );

    passwordController.dispose();
    return result;
  }

  // Get a user-friendly message based on WiFi status.
  //
  // The status tokens are the exact strings the firmware emits (wifi_config.c) —
  // note "Auth Failed" and "Connection Failed" have a SPACE. The previous code
  // checked "AuthFailed" (no space), so the password-incorrect message never fired
  // and the user only ever saw a generic failure (APP-2).
  static String getWifiStatusMessage(String wifiStatus) {
    switch (wifiStatus.trim()) {
      case "Initializing":
        return "WiFi is initializing...";
      case "Reconnecting":
        return "Reconnecting to WiFi...";
      case "No credentials":
        return "No WiFi network set up yet";
      case "NotConnected":
        return "WiFi is not connected";
      case "Auth Failed":
        return "WiFi password incorrect";
      case "Connection Failed":
        return "WiFi connection failed";
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

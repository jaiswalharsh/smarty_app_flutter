import 'dart:async';
import 'package:flutter/material.dart';

/// One access point from a firmware Wi-Fi scan.
///
/// [auth] is the esp_wifi wifi_auth_mode_t integer the toy reports (0 = open).
/// A value of -1 means "unknown" (old-format fallback line) and is treated as
/// secured so the app never sends an empty password to a network that needs one.
class WifiNetwork {
  final String ssid;
  final int rssi;
  final int auth;
  const WifiNetwork(this.ssid, this.rssi, this.auth);
  bool get isOpen => auth == 0;
}

class WifiUtils {
  // Process the WiFi scan data and extract network information.
  //
  // Firmware format: framed by "TOTAL:N" / "END", one AP per line as
  // "i:SSID:RSSI,AUTH" (AUTH = esp_wifi wifi_auth_mode_t, 0 = open). The SSID
  // itself may contain ':' — so we take the index before the FIRST ':' and the
  // "RSSI,AUTH" tail after the LAST ':', and treat EVERYTHING in between as the
  // SSID. The old parser split on every ':' and took parts[1], silently
  // truncating any SSID that contained a colon.
  static List<WifiNetwork> processWifiScanData(String data) {
    // Dedup by SSID, keeping the strongest (highest) RSSI.
    final Map<String, WifiNetwork> byssid = {};

    try {
      if (data.isEmpty) {
        print("📶 Empty WiFi scan data received");
        return [];
      }

      // Each AP arrives on its own line (the scanner joins notifications with
      // '\n'). Only fall back to comma-splitting for a legacy single-line list
      // of bare SSIDs — never for a lone "i:SSID:RSSI,AUTH" line, whose tail
      // comma must survive.
      final List<String> lines;
      if (data.contains('\n')) {
        lines = data.split('\n');
      } else if (data.contains(':')) {
        lines = [data];
      } else {
        lines = data.split(',');
      }

      for (String line in lines) {
        final String trimmedLine = line.trim();
        if (trimmedLine.isEmpty) continue;
        // Skip header/footer markers
        if (trimmedLine.startsWith("TOTAL:") || trimmedLine == "END") continue;

        WifiNetwork? network;
        final int firstColon = trimmedLine.indexOf(':');
        final int lastColon = trimmedLine.lastIndexOf(':');
        // Need at least two distinct ':' to carry the "i:...:RSSI,AUTH" frame.
        if (lastColon > firstColon) {
          final List<String> tail =
              trimmedLine.substring(lastColon + 1).split(',');
          if (tail.length == 2) {
            final int? rssi = int.tryParse(tail[0].trim());
            final int? auth = int.tryParse(tail[1].trim());
            if (rssi != null && auth != null) {
              network = WifiNetwork(
                trimmedLine.substring(firstColon + 1, lastColon),
                rssi,
                auth,
              );
            }
          }
        }
        // Old format / unparseable tail: whole line is the SSID (unknown signal).
        network ??= WifiNetwork(trimmedLine, 0, -1);

        // Skip hidden APs (empty SSID) — reachable via manual "join hidden".
        if (network.ssid.trim().isEmpty) continue;

        final existing = byssid[network.ssid];
        if (existing == null || network.rssi > existing.rssi) {
          byssid[network.ssid] = network;
        }
      }

      // Strongest first — usually the parent's own network.
      final List<WifiNetwork> networks = byssid.values.toList()
        ..sort((a, b) => b.rssi.compareTo(a.rssi));

      print("📶 Processed ${networks.length} networks");
      return networks;
    } catch (e) {
      print("❌ Error processing WiFi scan data: $e");
      return [];
    }
  }

  // Show password dialog for WiFi connection.
  //
  // The controller is owned by the dialog's State (_PasswordDialog) and disposed
  // in its dispose(), which Flutter runs only after the route has fully left the
  // tree. This keeps the APP-9 leak fixed (a controller was once created inside
  // the builder and never disposed) while avoiding the use-after-dispose crash
  // that disposing right after `await showDialog` caused: the route still
  // rebuilds during its exit transition as the keyboard dismisses, re-subscribing
  // the TextField to what would be a freed controller.
  static Future<String?> showPasswordDialog(
    BuildContext context,
    String network,
  ) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PasswordDialog(network: network),
    );
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

// See showPasswordDialog: the controller lives here so it is disposed only after
// the route unmounts, keeping the APP-9 leak fixed without the use-after-dispose
// crash. Pops the password on submit, null on cancel.
class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.network});

  final String network;

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final TextEditingController passwordController = TextEditingController();
  bool obscure = true;
  String? errorText;

  @override
  void dispose() {
    passwordController.dispose();
    super.dispose();
  }

  // A secured network needs a key. An empty submit used to no-op silently,
  // leaving the parent stuck — reject it with a hint.
  void _submit() {
    if (passwordController.text.isEmpty) {
      setState(() => errorText = 'Please enter the password');
      return;
    }
    Navigator.of(context).pop(passwordController.text);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Connect to ${widget.network}'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: passwordController,
              decoration: InputDecoration(
                labelText: 'WiFi Password',
                border: const OutlineInputBorder(),
                errorText: errorText,
                suffixIcon: IconButton(
                  icon: Icon(
                      obscure ? Icons.visibility_off : Icons.visibility),
                  tooltip: obscure ? 'Show password' : 'Hide password',
                  onPressed: () => setState(() => obscure = !obscure),
                ),
              ),
              obscureText: obscure,
              autofocus: true,
              onChanged: (_) {
                if (errorText != null) {
                  setState(() => errorText = null);
                }
              },
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          child: const Text('Cancel'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Connect'),
        ),
      ],
    );
  }
}

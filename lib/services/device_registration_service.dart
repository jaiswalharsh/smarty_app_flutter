import 'dart:convert';
import 'package:http/http.dart' as http;
import 'ble_manager.dart';
import 'auth_service.dart';

class DeviceRegistrationService {
  static const String _registerDeviceUrl =
      'https://us-central1-smarty-7e350.cloudfunctions.net/registerDevice';

  final AuthService _authService = AuthService();
  final BleManager _bleManager = BleManager();

  /// Read device_id from ESP32 via BLE characteristic 0xAB06
  Future<String?> readDeviceId() async {
    return await _bleManager.readDeviceId();
  }

  /// Register device with Firebase Cloud Function.
  /// Returns device_secret on success, null on failure.
  Future<String?> registerDevice(String deviceId) async {
    final idToken = await _authService.idToken;
    if (idToken == null) {
      print('DeviceRegistration: Not authenticated');
      return null;
    }

    try {
      final response = await http.post(
        Uri.parse(_registerDeviceUrl),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $idToken',
        },
        body: jsonEncode({'device_id': deviceId}),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final secret = data['device_secret'] as String?;
        print('DeviceRegistration: Device registered successfully');
        return secret;
      } else {
        print('DeviceRegistration: Failed with status ${response.statusCode}: ${response.body}');
        return null;
      }
    } catch (e) {
      print('DeviceRegistration: Error: $e');
      return null;
    }
  }

  /// Write device_secret to ESP32 via BLE characteristic 0xAB05
  Future<bool> writeSecretToDevice(String secret) async {
    return await _bleManager.writeDeviceSecret(secret);
  }

  /// Full registration flow: read device_id → register → write secret
  /// Returns true on success.
  Future<bool> performFullRegistration() async {
    // Step 1: Read device_id from ESP32
    final deviceId = await readDeviceId();
    if (deviceId == null || deviceId.isEmpty || deviceId == '{}') {
      print('DeviceRegistration: Failed to read device_id');
      return false;
    }

    // Step 2: Register with Cloud Function
    final secret = await registerDevice(deviceId);
    if (secret == null) {
      print('DeviceRegistration: Cloud Function registration failed');
      return false;
    }

    // Step 3: Write secret to ESP32
    final written = await writeSecretToDevice(secret);
    if (!written) {
      print('DeviceRegistration: Failed to write secret to device');
      return false;
    }

    print('DeviceRegistration: Full registration complete for device $deviceId');
    return true;
  }
}

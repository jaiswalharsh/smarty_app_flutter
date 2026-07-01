import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'ble_manager.dart';
import 'auth_service.dart';

/// Outcome of a device-registration attempt. On success [secret] holds the
/// device key; on failure [error] holds a user-facing message describing the
/// real cause (signed out, expired session, server error, no network, ...).
class RegistrationResult {
  final String? secret;
  final String? error;
  const RegistrationResult.success(this.secret) : error = null;
  const RegistrationResult.failure(this.error) : secret = null;
  bool get ok => secret != null;
}

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
  Future<RegistrationResult> registerDevice(String deviceId) async {
    try {
      // Inside the try: getIdToken() can throw (e.g. an offline token refresh),
      // and that must become a clean failure result, not an unhandled throw.
      final idToken = await _authService.idToken;
      if (idToken == null) {
        print('DeviceRegistration: no ID token (signed out)');
        return const RegistrationResult.failure(
            'You appear to be signed out. Please sign in again and retry.');
      }

      final response = await http
          .post(
            Uri.parse(_registerDeviceUrl),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $idToken',
            },
            body: jsonEncode({'device_id': deviceId}),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final secret = data['device_secret'] as String?;
        if (secret == null || secret.isEmpty) {
          print('DeviceRegistration: 200 but no device_secret in body');
          return const RegistrationResult.failure(
              'The server did not return a device key. Please try again.');
        }
        print('DeviceRegistration: Device registered successfully');
        return RegistrationResult.success(secret);
      } else if (response.statusCode == 401) {
        print('DeviceRegistration: 401 unauthorized: ${response.body}');
        return const RegistrationResult.failure(
            'Your session has expired. Please sign in again and retry.');
      } else {
        print('DeviceRegistration: HTTP ${response.statusCode}: ${response.body}');
        return RegistrationResult.failure(
            'The server rejected the request (error ${response.statusCode}). Please try again.');
      }
    } on TimeoutException {
      print('DeviceRegistration: request timed out');
      return const RegistrationResult.failure(
          'The server took too long to respond. Check your connection and try again.');
    } catch (e) {
      print('DeviceRegistration: error: $e');
      return const RegistrationResult.failure(
          'Couldn\'t reach the registration server. Check your internet connection and try again.');
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
    final result = await registerDevice(deviceId);
    if (!result.ok) {
      print('DeviceRegistration: Cloud Function registration failed: ${result.error}');
      return false;
    }

    // Step 3: Write secret to ESP32
    final written = await writeSecretToDevice(result.secret!);
    if (!written) {
      print('DeviceRegistration: Failed to write secret to device');
      return false;
    }

    print('DeviceRegistration: Full registration complete for device $deviceId');
    return true;
  }
}

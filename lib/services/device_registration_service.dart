import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'ble_manager.dart';
import 'auth_service.dart';

/// Why linking a toy to the parent's account failed. The page decides which
/// actions to offer from this (e.g. no Retry for [alreadyOwned]) instead of
/// matching message text.
enum RegistrationFailure {
  /// The toy is already linked to a different account (HTTP 409).
  alreadyOwned,

  /// No usable sign-in: signed out, or the session is still rejected after a
  /// forced token refresh (HTTP 401).
  signInRequired,

  /// No response from our backend (offline, timeout), even after one retry.
  network,

  /// Our backend answered with an error (5xx) or an unusable response.
  server,

  /// The toy stopped answering over Bluetooth (couldn't read its ID or save
  /// the key on it).
  deviceUnreachable,

  /// Anything else that we didn't anticipate.
  unknown,
}

extension RegistrationFailureMessage on RegistrationFailure {
  /// Parent-facing text: what happened, in everyday words, and what to do.
  String get message {
    switch (this) {
      case RegistrationFailure.alreadyOwned:
        return 'This Smarty is already linked to another account. If it was '
            'given to you, ask the previous owner to remove it first, or '
            'contact office@hey-smarty.com.';
      case RegistrationFailure.signInRequired:
        return 'Please sign in again.';
      case RegistrationFailure.network:
      case RegistrationFailure.server:
        return 'Our service is having trouble. Please try again in a few '
            'minutes.';
      case RegistrationFailure.deviceUnreachable:
        return 'We lost touch with Smarty. Keep it close to your phone and '
            'try again.';
      case RegistrationFailure.unknown:
        return 'Something went wrong. Please try again.';
    }
  }

  /// Whether trying again right away can plausibly help.
  bool get canRetry =>
      this != RegistrationFailure.alreadyOwned &&
      this != RegistrationFailure.signInRequired;
}

/// Outcome of a device-registration attempt. On success [secret] holds the
/// device key; on failure [failure] says why and [message] is the text to
/// show the parent.
class RegistrationResult {
  final String? secret;
  final RegistrationFailure? failure;
  final String? _message;

  const RegistrationResult.success(String this.secret)
      : failure = null,
        _message = null;
  const RegistrationResult.failure(RegistrationFailure this.failure,
      {String? message})
      : secret = null,
        _message = message;

  bool get ok => secret != null;

  String? get message => _message ?? failure?.message;
}

class DeviceRegistrationService {
  static const String _registerDeviceUrl =
      'https://us-central1-smarty-7e350.cloudfunctions.net/registerDevice';
  static const Duration _httpTimeout = Duration(seconds: 10);
  static const String _ourSideMessage =
      'Something went wrong on our side. Please try again in a minute.';

  final AuthService _authService = AuthService();
  final BleManager _bleManager = BleManager();

  /// Read the toy's ID over BLE.
  Future<String?> readDeviceId() async {
    return await _bleManager.readDeviceId();
  }

  /// Link [deviceId] to the signed-in account via the Cloud Function.
  ///
  /// Retries once automatically on a 401 (with a force-refreshed ID token)
  /// and once on a network error/timeout before giving up.
  Future<RegistrationResult> registerDevice(String deviceId) async {
    String? idToken;
    try {
      idToken = await _authService.idToken;
    } on FirebaseAuthException catch (e) {
      debugPrint('DeviceRegistration: getIdToken failed: ${e.code} $e');
      return RegistrationResult.failure(e.code == 'network-request-failed'
          ? RegistrationFailure.network
          : RegistrationFailure.signInRequired);
    } catch (e) {
      debugPrint('DeviceRegistration: getIdToken failed: $e');
      return const RegistrationResult.failure(RegistrationFailure.network);
    }
    if (idToken == null) {
      debugPrint('DeviceRegistration: no ID token (signed out)');
      return const RegistrationResult.failure(
          RegistrationFailure.signInRequired);
    }

    bool tokenRefreshed = false;
    bool networkRetried = false;

    while (true) {
      final http.Response response;
      try {
        response = await http
            .post(
              Uri.parse(_registerDeviceUrl),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $idToken',
              },
              body: jsonEncode({'device_id': deviceId}),
            )
            .timeout(_httpTimeout);
      } on TimeoutException {
        debugPrint('DeviceRegistration: request timed out');
        if (!networkRetried) {
          networkRetried = true;
          continue;
        }
        return const RegistrationResult.failure(RegistrationFailure.network);
      } on SocketException catch (e) {
        debugPrint('DeviceRegistration: network error: $e');
        if (!networkRetried) {
          networkRetried = true;
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        return const RegistrationResult.failure(RegistrationFailure.network);
      } on http.ClientException catch (e) {
        debugPrint('DeviceRegistration: client error: $e');
        if (!networkRetried) {
          networkRetried = true;
          await Future.delayed(const Duration(seconds: 1));
          continue;
        }
        return const RegistrationResult.failure(RegistrationFailure.network);
      } catch (e) {
        debugPrint('DeviceRegistration: unexpected request error: $e');
        return const RegistrationResult.failure(RegistrationFailure.unknown);
      }

      final int status = response.statusCode;
      if (status == 200) {
        String? secret;
        try {
          final data = jsonDecode(response.body);
          if (data is Map) secret = data['device_secret'] as String?;
        } catch (e) {
          debugPrint('DeviceRegistration: bad 200 body: $e');
        }
        if (secret == null || secret.isEmpty) {
          debugPrint('DeviceRegistration: 200 but no device_secret in body');
          return const RegistrationResult.failure(RegistrationFailure.server,
              message: _ourSideMessage);
        }
        debugPrint('DeviceRegistration: Device registered successfully');
        return RegistrationResult.success(secret);
      }

      if (status == 401) {
        debugPrint('DeviceRegistration: 401 unauthorized: ${response.body}');
        if (tokenRefreshed) {
          return const RegistrationResult.failure(
              RegistrationFailure.signInRequired);
        }
        tokenRefreshed = true;
        try {
          idToken =
              await FirebaseAuth.instance.currentUser?.getIdToken(true);
        } catch (e) {
          debugPrint('DeviceRegistration: forced token refresh failed: $e');
          idToken = null;
        }
        if (idToken == null) {
          return const RegistrationResult.failure(
              RegistrationFailure.signInRequired);
        }
        continue;
      }

      if (status == 409) {
        debugPrint('DeviceRegistration: 409 already owned: ${response.body}');
        return const RegistrationResult.failure(
            RegistrationFailure.alreadyOwned);
      }

      debugPrint('DeviceRegistration: HTTP $status: ${response.body}');
      if (status >= 500) {
        return const RegistrationResult.failure(RegistrationFailure.server);
      }
      // Other 4xx (400/405): a bug on our side, not something the parent did.
      return const RegistrationResult.failure(RegistrationFailure.server,
          message: _ourSideMessage);
    }
  }

  /// Write the device key to the toy over BLE.
  Future<bool> writeSecretToDevice(String secret) async {
    return await _bleManager.writeDeviceSecret(secret);
  }
}

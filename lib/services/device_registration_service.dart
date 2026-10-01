import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../app_info.dart' show appDisplayName;
import '../dev_config.dart';
import 'ble_manager.dart';
import 'auth_service.dart';
import 'known_toys_service.dart';

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

  /// The toy answered, but its ID was still empty after re-reading it for a
  /// few seconds ([BleManager.toyIdReadWaits]): it is still starting up.
  toyStarting,

  /// Anything else that we didn't anticipate.
  unknown,
}

/// [RegistrationFailure.toyStarting]: Smarty was just switched on (or
/// restarted) and isn't ready yet — the heading, and what to do.
const String toyStartingHeading = "Smarty isn't ready yet";
const String toyStartingMessage =
    'Smarty is still starting up — tap Try again.';

/// Heading when the toy is still linked to another account (HTTP 409).
const String ownedElsewhereHeading =
    'This Smarty is still linked to another family.';

/// What to do when the toy is still linked to another account: the other
/// family removes it (Home → ⋯ → Remove from my account), or we help — with
/// the toy's code ([bleName], e.g. "Smarty-B11E", when known). There is no
/// way to take it over from this phone: its id can be read by anyone nearby,
/// so a claim without the owner would let anyone take a family's toy. Pure.
String ownedElsewhereMessage(String? bleName) =>
    'Ask them to open the $appDisplayName app → Home → ⋯ → Remove from my '
    "account. If you can't reach them, contact office@hey-smarty.com with the "
    "code on the toy (${normalizeBleName(bleName) ?? 'Smarty-XXXX'}).";

extension RegistrationFailureMessage on RegistrationFailure {
  /// Parent-facing text: what happened, in everyday words, and what to do.
  String get message {
    switch (this) {
      case RegistrationFailure.alreadyOwned:
        return ownedElsewhereMessage(null);
      case RegistrationFailure.signInRequired:
        return 'Please sign in again.';
      case RegistrationFailure.network:
      case RegistrationFailure.server:
        return 'Our service is having trouble. Please try again in a few '
            'minutes.';
      case RegistrationFailure.deviceUnreachable:
        return 'We lost touch with Smarty. Keep it close to your phone and '
            'try again.';
      case RegistrationFailure.toyStarting:
        return toyStartingMessage;
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
  /// The `registerDevice` Cloud Function; the local functions emulator in an
  /// emulator build ([DevConfig.useEmulator]).
  static const String _registerDeviceUrl = DevConfig.useEmulator
      ? 'http://${DevConfig.emulatorHost}:${DevConfig.functionsEmulatorPort}'
          '/${DevConfig.firebaseProjectId}/${DevConfig.functionsRegion}'
          '/registerDevice'
      : 'https://europe-west1-smarty-7e350.cloudfunctions.net/registerDevice';
  static const Duration _httpTimeout = Duration(seconds: 10);
  static const String _ourSideMessage =
      'Something went wrong on our side. Please try again in a minute.';

  final AuthService _authService = AuthService();
  final BleManager _bleManager = BleManager();

  /// Read the toy's ID over BLE — re-read while it is still empty (the toy
  /// is still starting up; see [BleManager.toyIdReadWaits]).
  Future<ToyIdRead> readDeviceId() => _bleManager.readToyId();

  /// What a finished id read ([read]) means for the link: null = go on with
  /// its id; otherwise why it can't — [RegistrationFailure.toyStarting] when
  /// the toy answered but its id was still empty, else
  /// [RegistrationFailure.deviceUnreachable]. Pure.
  static RegistrationFailure? failureForIdRead(ToyIdRead read) {
    if (read.id != null) return null;
    return read.stillStarting
        ? RegistrationFailure.toyStarting
        : RegistrationFailure.deviceUnreachable;
  }

  /// The request body for linking [deviceId]: `device_id`, plus `ble_name`
  /// when [bleName] (the name the toy shows over Bluetooth) is a real toy
  /// name ("Smarty-B11E") — the account then recognises the toy by name on a
  /// freshly installed app or a new phone. Pure.
  static Map<String, String> registerBody(String deviceId, {String? bleName}) {
    final String? name = normalizeBleName(bleName);
    return {'device_id': deviceId, if (name != null) 'ble_name': name};
  }

  /// Link [deviceId] to the signed-in account via the Cloud Function, with
  /// the toy's Bluetooth name [bleName] if known (see [registerBody]).
  ///
  /// Retries once automatically on a 401 (with a force-refreshed ID token)
  /// and once on a network error/timeout before giving up.
  Future<RegistrationResult> registerDevice(String deviceId,
      {String? bleName}) async {
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
              // TODO(tz): also send the phone's IANA time zone
              // ({'device_id', 'timezone'}) so the backend buckets days in
              // the parent's zone (plan §8). Needs `flutter_timezone`
              // (DateTime.timeZoneName only gives "CEST"-style names).
              body: jsonEncode(registerBody(deviceId, bleName: bleName)),
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
        // The account's toys changed: read them again next time.
        KnownToysService.instance.forgetCachedToys();
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

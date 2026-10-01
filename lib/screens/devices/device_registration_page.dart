import 'dart:async';

import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/ble_manager.dart';
import '../../services/device_registration_service.dart';
import '../../services/known_toys_service.dart';
import '../../services/toy_claim.dart';
import '../auth/login_page.dart';

/// How the account link ended — the result [DeviceRegistrationPage] pops.
/// (Popped with no result — the back button — means the same as [later].)
enum LinkResult {
  /// The toy is linked to this account (secret written to the toy).
  linked,

  /// The parent chose "Not now": setup carries on, Home offers
  /// "Finish setup" later.
  later,

  /// The toy is already linked to ANOTHER account (409). Setup must stop;
  /// the caller forgets the toy.
  ownedElsewhere,
}

/// Links the connected toy to the signed-in parent's account.
///
/// Pops a [LinkResult]: [LinkResult.linked] on success, [LinkResult.later]
/// when the parent backs out, [LinkResult.ownedElsewhere] when the toy
/// belongs to another account.
class DeviceRegistrationPage extends StatefulWidget {
  const DeviceRegistrationPage({super.key});

  @override
  State<DeviceRegistrationPage> createState() => _DeviceRegistrationPageState();
}

enum _Phase { working, done, failed }

class _DeviceRegistrationPageState extends State<DeviceRegistrationPage> {
  final DeviceRegistrationService _registrationService =
      DeviceRegistrationService();

  _Phase _phase = _Phase.working;
  RegistrationFailure? _failure;
  String? _errorMessage;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _startRegistration();
  }

  void _fail(RegistrationFailure failure, [String? message]) {
    if (!mounted) return;
    setState(() {
      _phase = _Phase.failed;
      _failure = failure;
      _errorMessage = message ?? failure.message;
    });
  }

  Future<void> _startRegistration() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _phase = _Phase.working;
      _failure = null;
      _errorMessage = null;
    });

    try {
      // Re-read while the id is still empty: a toy that was just switched
      // on (or reset) needs a moment before it has one.
      final ToyIdRead read = await _registrationService.readDeviceId();
      if (!mounted) return;
      final RegistrationFailure? idFailure =
          DeviceRegistrationService.failureForIdRead(read);
      if (idFailure != null) {
        _fail(idFailure);
        return;
      }
      final String deviceId = read.id!;

      // The name the toy shows over Bluetooth ("Smarty-B11E"), so the
      // account can recognise it later before connecting.
      final result = await _registrationService.registerDevice(
        deviceId,
        bleName: BleManager().savedToyName,
      );
      if (!mounted) return;
      if (!result.ok) {
        _fail(result.failure ?? RegistrationFailure.unknown, result.message);
        return;
      }

      final written =
          await _registrationService.writeSecretToDevice(result.secret!);
      if (!mounted) return;
      if (!written) {
        _fail(RegistrationFailure.deviceUnreachable);
        return;
      }
      // Flip the flag here — whoever pushed this page sees it immediately.
      // Older firmware doesn't re-notify status on the secret write (and
      // keeps serving "registered":false); markRegistered also makes
      // BleManager ignore that stale value for the rest of this connection.
      BleManager().markRegistered();
      // The toy's new claim key (what the account's record now holds), kept
      // right away: this phone never needs the cloud to prove the account to
      // the toy it just linked.
      unawaited(KnownToysService.instance
          .rememberClaimKey(deviceId, claimKeyFromSecret(result.secret!)));

      setState(() => _phase = _Phase.done);
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) {
        Navigator.of(context).pop(LinkResult.linked);
      }
    } catch (e) {
      // Safety net: any unexpected throw must surface as an error — never
      // leave the progress screen spinning forever.
      debugPrint('DeviceRegistration: unexpected error: $e');
      _fail(RegistrationFailure.unknown);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
      } else {
        _busy = false;
      }
    }
  }

  Future<void> _signInAgain() async {
    // Same teardown order as Settings → Log out: drop the BLE link first so
    // the next account doesn't inherit a live connection.
    try {
      await BleManager().disconnectAndReset();
    } catch (e) {
      debugPrint('DeviceRegistration: disconnect before sign-out failed: $e');
    }
    await AuthService().signOut();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginPage()),
      (route) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Linking Smarty to your account'),
          automaticallyImplyLeading: !_busy,
          backgroundColor: Theme.of(context).primaryColor,
          foregroundColor: Colors.white,
        ),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: switch (_phase) {
                  _Phase.working => _buildWorking(),
                  _Phase.done => _buildDone(),
                  _Phase.failed => _buildFailed(),
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildWorking() => [
        CircularProgressIndicator(color: Colors.blue.shade600),
        const SizedBox(height: 24),
        const Text(
          'Linking Smarty to your account…',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
        ),
      ];

  List<Widget> _buildDone() => [
        const Icon(Icons.check_circle, color: Colors.green, size: 64),
        const SizedBox(height: 16),
        Text(
          'All set!',
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w600,
            color: Colors.green.shade700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Your Smarty is ready to use.',
          style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
          textAlign: TextAlign.center,
        ),
      ];

  List<Widget> _buildFailed() {
    final failure = _failure ?? RegistrationFailure.unknown;
    final ButtonStyle primaryStyle = ElevatedButton.styleFrom(
      backgroundColor: Colors.blue.shade600,
      foregroundColor: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    );

    final Widget actions;
    if (failure == RegistrationFailure.signInRequired) {
      actions = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(LinkResult.later),
            child: const Text('Not now'),
          ),
          const SizedBox(width: 12),
          ElevatedButton(
            onPressed: _signInAgain,
            style: primaryStyle,
            child: const Text('Sign in'),
          ),
        ],
      );
    } else if (failure == RegistrationFailure.alreadyOwned) {
      // Already linked to someone else: retrying can't help, and setup must
      // not carry on as if the parent had chosen "Not now".
      actions = ElevatedButton(
        onPressed: () => Navigator.of(context).pop(LinkResult.ownedElsewhere),
        style: primaryStyle,
        child: const Text('OK'),
      );
    } else {
      // Retry stays the primary action; "Not now" gives an explicit exit
      // (pops [LinkResult.later]): setup carries on, and Home keeps offering
      // "Finish setup" until the toy is linked.
      actions = Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(LinkResult.later),
            child: const Text('Not now'),
          ),
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: _startRegistration,
            icon: const Icon(Icons.refresh),
            label: const Text('Try again'),
            style: primaryStyle,
          ),
        ],
      );
    }

    final bool owned = failure == RegistrationFailure.alreadyOwned;
    // Not an error: the toy just needs a moment.
    final bool starting = failure == RegistrationFailure.toyStarting;
    return [
      owned
          ? Icon(Icons.lock_outline, color: Colors.orange.shade400, size: 64)
          : starting
              ? Icon(Icons.hourglass_top,
                  color: Colors.orange.shade400, size: 64)
              : const Icon(Icons.error_outline, color: Colors.red, size: 64),
      const SizedBox(height: 16),
      Text(
        owned
            ? ownedElsewhereHeading
            : starting
                ? toyStartingHeading
                : "Couldn't link Smarty",
        style: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: owned || starting
              ? Colors.orange.shade800
              : Colors.red.shade700,
        ),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 8),
      Text(
        owned
            ? ownedElsewhereMessage(BleManager().savedToyName)
            : _errorMessage ?? 'Something went wrong. Please try again.',
        style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 24),
      actions,
    ];
  }
}

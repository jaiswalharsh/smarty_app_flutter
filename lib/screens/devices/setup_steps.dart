// Pure decision helpers for the "Set up Smarty" page, kept free of Flutter
// widgets and BLE so they can be unit-tested.

import '../../services/ble_manager.dart';

/// Hint shown under the live toy list while nothing has been picked yet.
enum ScanHint {
  /// Just started looking — the instructions card is enough.
  none,

  /// ~10 s with nothing found: "Still looking — did you hold both buttons?"
  stillLooking,

  /// ~30 s: the toy's 30-second wait is over; ask for the buttons again.
  stoppedWaiting,
}

/// After this long with no toy, nudge the parent.
const Duration scanStillLookingAfter = Duration(seconds: 10);

/// A new toy waits 30 s for a phone after the buttons are held.
const Duration scanStoppedWaitingAfter = Duration(seconds: 30);

/// Which hint to show [elapsed] after the parent started (or restarted)
/// looking, given whether any toy has shown up yet.
ScanHint scanHintFor(Duration elapsed, {required bool anyFound}) {
  if (anyFound) return ScanHint.none;
  if (elapsed >= scanStoppedWaitingAfter) return ScanHint.stoppedWaiting;
  if (elapsed >= scanStillLookingAfter) return ScanHint.stillLooking;
  return ScanHint.none;
}

/// Where the toy's Wi-Fi stands, from the raw `wifi` status value.
enum WifiStep {
  /// No status yet ("Unknown", empty, or the app's own "NotConnected").
  unknown,

  /// Joined a real network (the value is its name).
  connected,

  /// Needs the parent: no network saved, wrong password, or network gone.
  needsSetup,

  /// The toy is working on it ("Initializing" / "Reconnecting").
  joining,
}

/// Map a status value from the toy (see wifi_config.c) to a [WifiStep].
WifiStep wifiStepFor(String rawStatus) {
  final String s = rawStatus.trim();
  switch (s) {
    case '':
    case 'Unknown':
    case 'NotConnected':
      return WifiStep.unknown;
    case 'Initializing':
    case 'Reconnecting':
      return WifiStep.joining;
    case 'No credentials':
    case 'Auth Failed':
    case 'Connection Failed':
      return WifiStep.needsSetup;
  }
  if (s.contains('Failed')) return WifiStep.needsSetup;
  return WifiStep.connected;
}

/// Last step of every "old connection" (pairingBroken) explanation. Holding
/// the buttons opens the toy's 30-second pairing window — without it a toy
/// that has wiped its bonds neither advertises nor accepts the phone.
const String pairingRepairFinalStep =
    'Then hold the + and – buttons on Smarty together for 3 seconds and tap '
    'Try again.';

/// What the parent does about a pairing the toy no longer knows, without the
/// leading "Your phone remembers an old connection to Smarty." (Home shows
/// that as its heading). iOS: forget Smarty in Settings first. Android: the
/// app already dropped the stale pairing.
String pairingBrokenSteps({required bool isIOS}) => isIOS
    ? 'Open Settings → Bluetooth, tap ⓘ next to Smarty and choose Forget '
        'This Device. $pairingRepairFinalStep'
    : 'We cleared it on this phone. $pairingRepairFinalStep';

/// Parent-facing explanation for a failed connect. Never includes raw error
/// text. [ConnectFailure.bluetoothOff] / [ConnectFailure.needsPermission] are
/// rendered as their own Bluetooth states, but get a sensible line here too.
String connectFailureMessage(ConnectFailure kind, {required bool isIOS}) {
  switch (kind) {
    case ConnectFailure.pairingBroken:
      // Same words as Home's pairing-broken view.
      return 'Your phone remembers an old connection to Smarty. '
          '${pairingBrokenSteps(isIOS: isIOS)}';
    case ConnectFailure.cancelledByUser:
      return 'Tap Pair when your phone asks, so Smarty can connect.';
    case ConnectFailure.outOfRange:
      return "Smarty didn't answer. Move closer and try again.";
    case ConnectFailure.notSmarty:
      return "That doesn't look like a Smarty. Please try again.";
    case ConnectFailure.bluetoothOff:
      return 'Turn on Bluetooth on your phone to reach Smarty';
    case ConnectFailure.needsPermission:
      return 'Allow Bluetooth so the app can talk to Smarty';
    case ConnectFailure.unknown:
      return "We couldn't finish connecting. Keep Smarty close to your phone "
          'and try again.';
  }
}

// Pure decision helpers for the "Set up Smarty" page, kept free of Flutter
// widgets and BLE so they can be unit-tested.

import '../../services/ble_manager.dart';

// ---- Toy timing (firmware: bt_setup.c) ---------------------------------------

/// How long a toy waits for a phone after the + and – buttons are held.
const Duration pairingWindow = Duration(minutes: 2);

/// How long a toy that has never been paired waits for a phone after it is
/// first switched on (no button hold needed).
const Duration firstBootPairingWindow = Duration(minutes: 5);

/// The "Smarty found!" beat before connecting to a lone toy by itself.
const Duration autoSelectDelay = Duration(milliseconds: 600);

// ---- Instructions -------------------------------------------------------------

/// Instructions card, first line: a brand-new toy is ready by itself.
final String setupFirstBootLine =
    'Just unboxed? Turn Smarty on — it\'s ready '
    'to pair for the first ${firstBootPairingWindow.inMinutes} minutes.';

/// Instructions card, second line: every other case (the button hold).
final String setupButtonHoldLine =
    'Otherwise, turn Smarty on and hold the '
    '+ and – buttons together for 3 seconds. Smarty will wait '
    '${pairingWindow.inMinutes} minutes for your phone.';

// ---- Which toys to offer ------------------------------------------------------

/// Whether a toy seen while looking belongs in the list. Only a toy that
/// says it is NOT waiting to pair is left out (it's set up with another
/// phone, or already set up); toys whose firmware says nothing ([advert]
/// null) are listed as always.
bool isSetupCandidate(ToyAdvert? advert) => advert?.pairing != false;

/// Whether to connect by ourselves (after [autoSelectDelay]) instead of
/// waiting for a tap: only when exactly one toy is listed AND it says it is
/// waiting to pair. Never for firmware that doesn't say (no advert data, or
/// a version-0 advert) — such a toy could be a neighbour's Smarty bonded to
/// their phone.
bool shouldAutoSelect(List<ToyAdvert?> candidates) {
  if (candidates.length != 1) return false;
  final advert = candidates.single;
  return advert != null && !advert.isLegacy && advert.pairing == true;
}

// ---- Hints --------------------------------------------------------------------

/// Hint shown under the live toy list while nothing has been picked yet.
enum ScanHint {
  /// Just started looking — the instructions card is enough.
  none,

  /// ~10 s with nothing found: "Still looking — did you hold both buttons?"
  stillLooking,

  /// ~10 s and the only toys around say they aren't waiting to pair.
  notReadyToPair,

  /// [pairingWindow] has passed: the toy's wait is over; ask for the buttons
  /// again.
  stoppedWaiting,
}

/// After this long with no toy, nudge the parent.
const Duration scanStillLookingAfter = Duration(seconds: 10);

/// After this long with no toy, the toy's wait ([pairingWindow]) is over.
const Duration scanStoppedWaitingAfter = pairingWindow;

/// Which hint to show [elapsed] after the parent started (or restarted)
/// looking, given whether any toy is listed yet and whether a toy was seen
/// that isn't waiting to pair ([seenNotPairing] — it is not listed).
ScanHint scanHintFor(
  Duration elapsed, {
  required bool anyFound,
  bool seenNotPairing = false,
}) {
  if (anyFound) return ScanHint.none;
  if (elapsed < scanStillLookingAfter) return ScanHint.none;
  // A toy we can see beats a guess: tell the parent exactly what to do.
  if (seenNotPairing) return ScanHint.notReadyToPair;
  if (elapsed >= scanStoppedWaitingAfter) return ScanHint.stoppedWaiting;
  return ScanHint.stillLooking;
}

/// Parent-facing text for [hint], or null for [ScanHint.none].
String? scanHintText(ScanHint hint) => switch (hint) {
  ScanHint.none => null,
  ScanHint.stillLooking => 'Still looking — did you hold both buttons?',
  ScanHint.notReadyToPair =>
    "We can see a Smarty, but it isn't ready to pair. Hold the + and – "
        'buttons on it for 3 seconds.',
  ScanHint.stoppedWaiting =>
    'Smarty stopped waiting. Hold the + and – buttons again.',
};

// ---- Wi-Fi step ---------------------------------------------------------------
//
// Owner's rule: Smarty joins its saved Wi-Fi by itself first. Only if that
// doesn't work do we say Smarty is having trouble and offer a different
// network. A toy with no Wi-Fi saved gets the "Last step" prompt; a toy we
// couldn't hear from is never silently assumed to need setup.

/// How long the Wi-Fi step waits for the toy (its first status, or its saved
/// Wi-Fi coming up) before giving an answer.
const Duration wifiCheckWait = Duration(seconds: 20);

/// While checking, ask the toy for its status this often.
const Duration wifiRecheckEvery = Duration(seconds: 3);

/// What the Wi-Fi step shows. See [decideWifiStep].
enum WifiDecision {
  /// On Wi-Fi — setup can finish.
  connected,

  /// "Checking Smarty's Wi-Fi…" with a spinner: no status yet, or the toy is
  /// still joining its saved Wi-Fi.
  checking,

  /// No Wi-Fi saved on the toy: "Last step: connect Smarty to your home
  /// Wi-Fi…" [Connect Wi-Fi] [Later].
  needsSetup,

  /// The saved Wi-Fi refused the password: [Try again] [Use a different
  /// Wi-Fi] [Later].
  authFailed,

  /// The saved Wi-Fi can't be reached (or joining it didn't work within
  /// [wifiCheckWait]): [Try again] [Use a different Wi-Fi] [Later].
  unreachable,

  /// [wifiCheckWait] passed and the toy never said anything: [Check again]
  /// [Set up Wi-Fi] [Later].
  couldNotCheck,
}

/// Raw status values that mean "no answer yet" (the app's own placeholders).
bool _isNoStatus(String s) =>
    s.isEmpty || s == 'Unknown' || s == 'NotConnected';

/// The Wi-Fi step's decision table (pure).
///
/// - [status]: the toy's raw `wifi` value (wifi_config.c), or null if none
///   has arrived since connecting.
/// - [advertWifiUp]: the Wi-Fi bit the toy advertised just before we
///   connected (null = not reported).
/// - [waited]: time since this check (or its "Try again") started.
/// - [retrying]: the parent tapped Try again — a failure the toy already
///   reported doesn't end the wait early, so its own retries get
///   [wifiCheckWait] to work.
///
/// | status                      | before [wifiCheckWait]      | after        |
/// |-----------------------------|-----------------------------|--------------|
/// | a network name              | connected                   | connected    |
/// | none, advert says on Wi-Fi  | connected                   | connected    |
/// | none                        | checking                    | couldNotCheck|
/// | Initializing / Reconnecting | checking                    | unreachable  |
/// | No credentials              | needsSetup                  | needsSetup   |
/// | Auth Failed                 | authFailed (retry: checking)| authFailed   |
/// | Connection Failed / *Failed | unreachable (retry: checking)| unreachable |
WifiDecision decideWifiStep({
  String? status,
  bool? advertWifiUp,
  required Duration waited,
  bool retrying = false,
}) {
  final String s = (status ?? '').trim();
  final bool timedOut = waited >= wifiCheckWait;

  if (_isNoStatus(s)) {
    // The toy said it was online just before we connected; trust that until
    // a status says otherwise.
    if (advertWifiUp == true) return WifiDecision.connected;
    return timedOut ? WifiDecision.couldNotCheck : WifiDecision.checking;
  }
  switch (s) {
    case 'Initializing':
    case 'Reconnecting':
      return timedOut ? WifiDecision.unreachable : WifiDecision.checking;
    case 'No credentials':
      return WifiDecision.needsSetup;
    case 'Auth Failed':
      return retrying && !timedOut
          ? WifiDecision.checking
          : WifiDecision.authFailed;
  }
  if (s == 'Connection Failed' || s.contains('Failed')) {
    return retrying && !timedOut
        ? WifiDecision.checking
        : WifiDecision.unreachable;
  }
  return WifiDecision.connected;
}

/// Label for the Wi-Fi row while [WifiDecision.checking].
const String wifiCheckingLabel = "Checking Smarty's Wi-Fi…";

/// The name to use for the toy's saved network in messages.
String _wifiNameFor(String? ssid) {
  final String name = (ssid ?? '').trim();
  return name.isEmpty ? 'your Wi-Fi' : "'$name'";
}

/// Saved Wi-Fi refused the password. Shared with Home.
String wifiAuthFailedLine(String? ssid) =>
    "Smarty can't connect to ${_wifiNameFor(ssid)} — the password may have "
    'changed.';

/// Saved Wi-Fi can't be reached. Shared with Home.
String wifiUnreachableLine(String? ssid) =>
    "Smarty can't reach ${_wifiNameFor(ssid)} — is the router on?";

/// Parent-facing message for a Wi-Fi decision that needs one, else null.
/// [ssid] is the toy's last known network name (null = unknown).
String? wifiDecisionMessage(WifiDecision d, {String? ssid}) => switch (d) {
  WifiDecision.connected || WifiDecision.checking => null,
  WifiDecision.needsSetup =>
    'Last step: connect Smarty to your home Wi-Fi. It only takes a minute.',
  WifiDecision.authFailed => wifiAuthFailedLine(ssid),
  WifiDecision.unreachable => wifiUnreachableLine(ssid),
  WifiDecision.couldNotCheck => "We couldn't check Smarty's Wi-Fi.",
};

/// Last step of every "old connection" (pairingBroken) explanation. The toy
/// keeps its pairings when the buttons are held (firmware §3.11), so
/// pairingBroken only follows a phone-side forget — the toy still knows this
/// phone and re-pairs on Try again — or a factory reset (10 s hold). A reset
/// toy with no pairings left stops advertising once its window closes; the
/// 3-second hold opens the toy's [pairingWindow] again.
const String pairingRepairFinalStep =
    "Then tap Try again. If Smarty doesn't show up, hold the + and – buttons "
    'for 3 seconds.';

/// What the parent does about a pairing the toy no longer knows, one step per
/// entry, without the leading "Your phone remembers an old connection to
/// Smarty." (Home shows that as its heading). Android: the app already
/// dropped the stale pairing, so one step. iOS: forget Smarty in Settings
/// first. The "Open Settings" button can only open this app's own page in
/// Settings — iOS has no allowed way to jump straight to Settings → Bluetooth
/// — so the steps walk back from there to Bluetooth. ("‹" rather than
/// "‹ Settings": on newer iOS the back button first says "Apps".)
List<String> pairingBrokenStepList({required bool isIOS}) =>
    isIOS
        ? const [
          'Tap Open Settings.',
          'Tap ‹ at the top left until you see the main Settings page, then '
              'tap Bluetooth.',
          'Tap ⓘ next to Smarty and choose Forget This Device.',
          'Come back to this app. $pairingRepairFinalStep',
        ]
        : const ['We cleared it on this phone. $pairingRepairFinalStep'];

/// [pairingBrokenStepList] as one string: numbered lines ("1. …") when there
/// is more than one step.
String pairingBrokenSteps({required bool isIOS}) {
  final steps = pairingBrokenStepList(isIOS: isIOS);
  if (steps.length == 1) return steps.single;
  return [
    for (var i = 0; i < steps.length; i++) '${i + 1}. ${steps[i]}',
  ].join('\n');
}

/// Leading line of every pairing-broken explanation (Home's heading).
const String pairingBrokenHeading =
    'Your phone remembers an old connection to Smarty.';

/// iOS hint under "Bluetooth is off" (Home and the setup page). The Open
/// Settings button there can only open this app's own page in Settings, so
/// say how to get from there to Bluetooth.
const String bluetoothOffHintIOS =
    'Swipe down from the top-right corner and tap the Bluetooth icon. Or tap '
    'Open Settings, then ‹ at the top left until you see the main Settings '
    'page, then tap Bluetooth.';

/// Parent-facing explanation for a failed connect. Never includes raw error
/// text. [ConnectFailure.bluetoothOff] / [ConnectFailure.needsPermission] are
/// rendered as their own Bluetooth states, but get a sensible line here too.
String connectFailureMessage(ConnectFailure kind, {required bool isIOS}) {
  switch (kind) {
    case ConnectFailure.pairingBroken:
      // Same words as Home's pairing-broken view.
      // A numbered list starts on its own line.
      return '$pairingBrokenHeading${isIOS ? '\n' : ' '}'
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

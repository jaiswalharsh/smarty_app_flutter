// Pure decision helpers for the "Set up Smarty" page, kept free of Flutter
// widgets and BLE so they can be unit-tested.

import 'package:flutter/foundation.dart' show immutable;

import '../../services/ble_manager.dart';
import '../../services/known_toys_service.dart' show normalizeBleName;

// ---- Toy timing (firmware: bt_setup.c) ---------------------------------------

/// How long a toy that isn't linked to an account waits for a phone after
/// its + and – buttons are held (a linked toy's buttons can't open pairing:
/// a phone of its account proves itself instead — see BleManager's claim).
/// A toy that has never been paired waits for as long as it is on.
const Duration pairingWindow = BleManager.toyPairingWindow;

/// The "Smarty found!" beat before connecting to a toy by ourselves.
const Duration autoSelectDelay = Duration(milliseconds: 600);

// ---- What the page is for -------------------------------------------------

/// Why the setup page was opened (Home picks it).
enum SetupMode {
  /// "Set up Smarty" / "Try again" / "Finish setup": the one toy of this
  /// account in the list, else a lone toy that is waiting to pair, is
  /// connected by itself.
  setUp,

  /// "Reconnect your Smarty" → Connect: bring back a toy this account set up
  /// before (a fresh install, or a new phone). That toy is connected by
  /// itself as soon as it shows up.
  reconnect,

  /// "Set up a different Smarty": the account's own toys are still listed
  /// ("Your Smarty") but never connected by themselves.
  newToy,
}

// ---- Instructions -------------------------------------------------------------

/// Instructions card, first line: a brand-new toy is ready by itself.
const String setupFirstBootLine =
    "Just unboxed? Turn Smarty on — it's ready to pair.";

/// Instructions card, second line: every other case (the button hold).
final String setupButtonHoldLine =
    'Otherwise hold the + and – buttons together for 3 seconds. Smarty will '
    'wait ${pairingWindow.inMinutes} minutes for your phone.';

/// Instructions card when reconnecting ([SetupMode.reconnect]), first line.
const String reconnectFirstLine =
    'Turn Smarty on and keep it close to your phone.';

/// Instructions card, last line, when reconnecting — and when setting up
/// with a toy already on the account: a phone signed in to the toy's
/// account proves that to the toy, which then lets it pair. Nothing to do
/// on the phone that has Smarty now, and no buttons to hold.
const String newPhoneLine =
    'Using a new phone? Just sign in with the same account — Smarty will let '
    'it pair.';

// ---- Resetting ------------------------------------------------------------------

/// The factory reset gesture (lower case, to go inside a sentence). Two
/// steps so it can't happen by accident: three beeps after 10 seconds, five
/// quick beeps after the second hold. It erases everything on the toy —
/// phone pairings, Wi-Fi, the child's profile and the account link.
const String factoryResetGesture =
    'hold + and – for 10 seconds, let go, then hold them again for 3 seconds';

/// Under [notConfirmedMessage]: the way out when this account can't prove
/// the toy is its own (e.g. it was set up with an account nobody can sign
/// in to any more).
const String resetAndSetUpAgainLine =
    'Reset Smarty: $factoryResetGesture. Then set it up again.';

// ---- Which toys to offer ------------------------------------------------------

/// Whether a toy that isn't this account's belongs in the main list. Only a
/// toy that says it is NOT waiting to pair is left out (it goes under
/// "Other Smarty toys nearby" — see [toyListingFor]); toys whose firmware
/// says nothing ([advert] null) are listed as always.
bool isSetupCandidate(ToyAdvert? advert) => advert?.pairing != false;

/// Where a toy seen while looking goes on the page.
enum ToyListing {
  /// This account's toy (its name matches a toy linked to the account, or it
  /// is the toy saved on this phone): "Your Smarty" + its code, in the main
  /// list whatever it says about pairing — it may already know this phone.
  yours,

  /// A toy to set up: "Smarty" + its code, in the main list.
  candidate,

  /// Says it isn't waiting to pair and isn't this account's: greyed, under
  /// "Other Smarty toys nearby" (tapping still tries — it may know this
  /// phone from another account).
  other,

  /// Says it is linked to an account, and isn't this account's: greyed,
  /// under "Other Smarty toys nearby" as "Set up by another family".
  /// Tapping explains ([otherFamilyMessage]) and never connects — a linked
  /// toy only takes phones of its own account.
  otherFamily,
}

/// [ToyListing] for a toy with [advert] ([yours]: it is this account's).
/// A toy that says it is linked ([ToyAdvert.registered]) and isn't this
/// account's belongs to another family, whatever it says about pairing;
/// firmware that doesn't say (null) is listed as before.
ToyListing toyListingFor(ToyAdvert? advert, {required bool yours}) {
  if (yours) return ToyListing.yours;
  if (advert?.registered == true) return ToyListing.otherFamily;
  return isSetupCandidate(advert) ? ToyListing.candidate : ToyListing.other;
}

/// Subtitle of a toy under "Other Smarty toys nearby" that isn't linked to
/// an account ([ToyListing.other]): its buttons still open pairing.
const String otherToySubtitle =
    'Set up with another phone — hold + and – on it to pair';

/// Subtitle of a toy linked to another account ([ToyListing.otherFamily]).
const String otherFamilySubtitle = 'Set up by another family';

/// Heading of the explanation when a [ToyListing.otherFamily] toy is tapped.
const String otherFamilyHeading = 'This Smarty belongs to another family';

/// The explanation when a [ToyListing.otherFamily] toy is tapped, with the
/// toy's code ([bleName], e.g. "Smarty-B11E", when known). Pure.
String otherFamilyMessage(String? bleName) =>
    "It's linked to their account, so it can't be set up here. First they "
    'need to remove it from their account (Smarty app → Home → ⋯ → Remove '
    "from my account) — resetting the toy alone isn't enough. If you can't "
    'reach them, contact '
    'office@hey-smarty.com with the code on the toy '
    '(${normalizeBleName(bleName) ?? 'Smarty-XXXX'}).';

/// Heading over the toys that aren't waiting to pair.
const String otherToysHeading = 'Other Smarty toys nearby';

/// Whether the toys under "Other Smarty toys nearby" (their [listings])
/// already tell the parent how to pair — a toy that isn't linked says to
/// hold its buttons ([otherToySubtitle]) — so no hint repeats it (see
/// [scanHintFor]'s `othersNearby`). Another family's toy
/// ([ToyListing.otherFamily]) says nothing about the parent's own. Pure.
bool othersShowHowToPair(Iterable<ToyListing> listings) =>
    listings.contains(ToyListing.other);

/// Whether to connect to a lone toy by ourselves on its advert alone: only
/// when exactly one is offered AND it says it is waiting to pair. Never for
/// firmware that doesn't say (no advert data, or a version-0 advert) — such
/// a toy could be a neighbour's Smarty bonded to their phone.
bool shouldAutoSelect(List<ToyAdvert?> candidates) {
  if (candidates.length != 1) return false;
  final advert = candidates.single;
  return advert != null && !advert.isLegacy && advert.pairing == true;
}

/// One toy in the main list, for [autoSelectIndex]: its advert, whether it
/// is this account's ([yours]), and whether it is the toy being reconnected
/// ([target]).
typedef ListedToy = ({ToyAdvert? advert, bool yours, bool target});

/// Which toy in the main list ([listed], in order) to connect by ourselves
/// after [autoSelectDelay], or null to wait for a tap. Pure.
///
/// - [SetupMode.reconnect]: the toy being reconnected, when exactly one
///   listed toy is it — whatever else is around.
/// - [SetupMode.setUp]: the account's toy when exactly one listed toy is
///   (the name matched the account, and the toy's own id is checked once
///   connected — so a neighbour's toy around doesn't make it ambiguous);
///   otherwise [shouldAutoSelect] over the whole list.
/// - [SetupMode.newToy]: the account's own toys are left out; then
///   [shouldAutoSelect] over the rest.
int? autoSelectIndex(List<ListedToy> listed, {required SetupMode mode}) {
  switch (mode) {
    case SetupMode.reconnect:
      final targets = [
        for (var i = 0; i < listed.length; i++)
          if (listed[i].target) i,
      ];
      return targets.length == 1 ? targets.single : null;
    case SetupMode.setUp:
      final mine = [
        for (var i = 0; i < listed.length; i++)
          if (listed[i].yours) i,
      ];
      if (mine.length == 1) return mine.single;
      return shouldAutoSelect([for (final t in listed) t.advert]) ? 0 : null;
    case SetupMode.newToy:
      final others = [
        for (var i = 0; i < listed.length; i++)
          if (!listed[i].yours) i,
      ];
      return shouldAutoSelect([for (final i in others) listed[i].advert])
          ? others.single
          : null;
  }
}

// ---- Hints --------------------------------------------------------------------

/// Hint (text only — never a button) shown while the look is running and
/// nothing has been listed yet.
enum ScanHint {
  /// Just started looking — the instructions card is enough.
  none,

  /// ~10 s with nothing found: "Still looking — did you hold both buttons?"
  stillLooking,

  /// [pairingWindow] has passed: the toy's wait is over; ask for the buttons
  /// again.
  stoppedWaiting,

  /// ~10 s without the account's own toy (reconnecting, or setting up with
  /// a toy on the account): it only needs to be on and close — and free: it
  /// talks to one phone at a time.
  stillLookingForYours,
}

/// After this long with no toy, nudge the parent.
const Duration scanStillLookingAfter = Duration(seconds: 10);

/// After this long with no toy, the toy's wait ([pairingWindow]) is over.
const Duration scanStoppedWaitingAfter = pairingWindow;

/// While reconnecting ([SetupMode.reconnect]), after this long without the
/// toy the page also offers "Set up a different Smarty" and "I don't have
/// this Smarty any more".
const Duration reconnectWayOutAfter = Duration(seconds: 30);

/// Whether the page is after the account's own toy — a linked toy, which a
/// phone of the account pairs with by just connecting (no buttons): when
/// reconnecting it, or setting up with a toy already on the account
/// ([accountHasToys]; e.g. Try again after an old connection). Not for "Set
/// up a different Smarty". Pure.
bool lookingForYoursIn(SetupMode mode, {required bool accountHasToys}) =>
    switch (mode) {
      SetupMode.reconnect => true,
      SetupMode.setUp => accountHasToys,
      SetupMode.newToy => false,
    };

/// Which hint to show [elapsed] after the parent started (or restarted)
/// looking. [anyListed]: a toy is in the main list (its tile says what to
/// do). [othersNearby]: toys that aren't waiting to pair are shown under
/// "Other Smarty toys nearby" — their subtitle already says to hold the
/// buttons, so no hint repeats it. [lookingForYours]: the page is after the
/// account's own toy ([SetupMode.reconnect], or [SetupMode.setUp] with a toy
/// on the account) — a linked toy: no button hold.
ScanHint scanHintFor(
  Duration elapsed, {
  required bool anyListed,
  bool othersNearby = false,
  bool lookingForYours = false,
}) {
  if (anyListed || othersNearby) return ScanHint.none;
  if (elapsed < scanStillLookingAfter) return ScanHint.none;
  if (lookingForYours) return ScanHint.stillLookingForYours;
  if (elapsed >= scanStoppedWaitingAfter) return ScanHint.stoppedWaiting;
  return ScanHint.stillLooking;
}

/// Parent-facing text for [hint], or null for [ScanHint.none].
String? scanHintText(ScanHint hint) => switch (hint) {
  ScanHint.none => null,
  ScanHint.stillLooking => 'Still looking — did you hold both buttons?',
  ScanHint.stoppedWaiting =>
    'Smarty stopped waiting. Hold the + and – buttons again.',
  ScanHint.stillLookingForYours =>
    'Still looking — make sure Smarty is on and close to your phone. '
        '$otherPhoneConnectedLine',
};

/// Part of [ScanHint.stillLookingForYours]: the toy talks to one phone at a
/// time, and doesn't show up while it does.
const String otherPhoneConnectedLine =
    'If Smarty is connected to another phone right now, close the Smarty app '
    'on that phone, then try again.';

/// What leads the "looking" part of the page: [spinner] (still looking /
/// connecting), [found] (a check mark), or neither (the look has stopped).
enum LookIcon { spinner, found, none }

/// The "looking" part of the setup page for one state: a header (with its
/// [icon]) and optional [subtitle] above the toy list, then a [hint] line
/// (orange when [hintIsWarning]) and the "Look again" button
/// ([showLookAgain]) below it. See [lookSectionView].
@immutable
class LookSectionView {
  const LookSectionView({
    required this.header,
    required this.icon,
    this.subtitle,
    this.hint,
    this.hintIsWarning = false,
    this.showLookAgain = false,
  });

  final String header;
  final LookIcon icon;
  final String? subtitle;
  final String? hint;
  final bool hintIsWarning;
  final bool showLookAgain;

  /// Every line of text it shows, header first (for tests).
  List<String> get texts => [
    header,
    if (subtitle != null) subtitle!,
    if (hint != null) hint!,
    if (showLookAgain) 'Look again',
  ];

  @override
  String toString() => 'LookSectionView($texts, $icon)';
}

/// The "looking" part of the setup page (pure). One rule: while the look is
/// running there is NO "Look again" button — hints are text only. The button
/// appears only once the look has actually stopped ([scanStopped]: it
/// failed and isn't retrying by itself). Connect failures, a lost link and
/// the Bluetooth states are separate views with their own buttons.
///
/// | state                      | header                   | hint              | button     |
/// |----------------------------|--------------------------|-------------------|------------|
/// | connecting                 | Connecting to Smarty… ⟳  | —                 | —          |
/// | looking, nothing, < 10 s   | Looking for Smarty… ⟳    | —                 | —          |
/// | looking, nothing, 10–120 s | Looking for Smarty… ⟳    | Still looking — … | —          |
/// | looking, nothing, ≥ 120 s  | Looking for Smarty… ⟳    | Smarty stopped …  | —          |
/// | looking, only others       | Looking for Smarty… ⟳    | — (tiles say it)  | —          |
/// | looking, one listed        | Smarty found! ✓          | —                 | —          |
/// | looking, several listed    | Smarty toys nearby       | —                 | —          |
/// | stopped, nothing listed    | Stopped looking for Smarty | Something got in the way on this phone. | Look again |
/// | stopped, toys listed       | (as above for the toys)  | Stopped looking for more toys. | Look again |
///
/// When reconnecting ([reconnect]) "Smarty" in the looking/connecting
/// headers reads "your Smarty", and several listed toys say "Tap your
/// Smarty." instead of "Tap the one you are setting up.".
LookSectionView lookSectionView({
  required bool connecting,
  required int listed,
  required bool scanStopped,
  ScanHint hint = ScanHint.none,
  bool reconnect = false,
}) {
  final String smarty = reconnect ? 'your Smarty' : 'Smarty';
  if (connecting) {
    return LookSectionView(
      header: 'Connecting to $smarty…',
      icon: LookIcon.spinner,
    );
  }
  if (listed == 0) {
    if (scanStopped) {
      return const LookSectionView(
        header: 'Stopped looking for Smarty',
        icon: LookIcon.none,
        hint: 'Something got in the way on this phone.',
        hintIsWarning: true,
        showLookAgain: true,
      );
    }
    return LookSectionView(
      header: 'Looking for $smarty…',
      icon: LookIcon.spinner,
      hint: scanHintText(hint),
      hintIsWarning: hint == ScanHint.stoppedWaiting,
    );
  }
  final String? stoppedHint =
      scanStopped ? 'Stopped looking for more toys.' : null;
  if (listed == 1) {
    return LookSectionView(
      header: 'Smarty found!',
      icon: LookIcon.found,
      hint: stoppedHint,
      hintIsWarning: scanStopped,
      showLookAgain: scanStopped,
    );
  }
  return LookSectionView(
    header: 'Smarty toys nearby',
    icon: LookIcon.none,
    subtitle:
        reconnect ? 'Tap your Smarty.' : 'Tap the one you are setting up.',
    hint: stoppedHint,
    hintIsWarning: scanStopped,
    showLookAgain: scanStopped,
  );
}

/// The note under the toy list. A toy that already knows this phone
/// connects without asking, so when every toy offered is the account's own
/// ([onlyYours]) it says "if".
String pairPromptNote({required bool onlyYours}) => onlyYours
    ? 'If your phone asks to pair with Smarty, tap Pair.'
    : 'Your phone will ask to pair with Smarty — tap Pair.';

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
/// keeps its pairings when its pairing window opens (firmware §3.11), so
/// pairingBroken only follows a phone-side forget — the toy still knows this
/// phone and re-pairs on Try again — or a factory reset / the toy erasing
/// itself after being removed from its account; a toy with no pairings left
/// waits to pair for as long as it is on. No button hold here: a toy linked
/// to the account ignores it — if the toy refuses on Try again, the setup
/// page says what to do ([connectAdviceFor]).
const String pairingRepairFinalStep = 'Then tap Try again.';

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

// ---- Bluetooth off / not allowed (Home's card and the setup page) -------------

/// The name iOS Settings lists this app under (CFBundleDisplayName in
/// ios/Runner/Info.plist): the page every "Open Settings" button lands on.
const String iosSettingsAppName = 'Smarty App';

/// What to do when Bluetooth is off, on every platform.
const String bluetoothOffLine =
    'Turn on Bluetooth on your phone to reach Smarty.';

/// iOS: the quickest way to turn Bluetooth on — Control Center, from any
/// screen — so it comes first, above the button.
const String bluetoothOffQuickStepIOS =
    'Quickest: swipe down from the top-right corner and tap the Bluetooth '
    'icon.';

/// iOS: the line right under the Open Settings button, saying where it really
/// lands. iOS allows no link to Settings → Bluetooth: an app can only open
/// its own page in Settings (app_settings does that for every type, the
/// Bluetooth one included), so walk back from there. ("‹" rather than
/// "‹ Settings": on newer iOS the back button first says "Apps".) The one way
/// straight to the Bluetooth page is iOS's own "Turn On Bluetooth" alert as
/// the app starts (see BleService.configureBeforeFirstUse).
const String bluetoothOffSettingsNoteIOS =
    'This opens Settings → $iosSettingsAppName. Tap ‹ at the top left until '
    'you see the main Settings page, then tap Bluetooth.';

/// The "Bluetooth is off" message on one platform (pure; see
/// [bluetoothOffViewFor]): [line], then [quickStep] when there is a faster
/// way than the button, the button ([buttonLabel]), and [buttonNote] right
/// under it when its label alone can't say where it goes.
@immutable
class BluetoothOffView {
  const BluetoothOffView({
    required this.line,
    required this.buttonLabel,
    required this.turnsOn,
    this.quickStep,
    this.buttonNote,
  });

  final String line;
  final String? quickStep;
  final String buttonLabel;

  /// The button turns Bluetooth on by itself (Android's system dialog);
  /// otherwise it opens Settings.
  final bool turnsOn;
  final String? buttonNote;

  /// Every line of text it shows, in order (for tests).
  List<String> get texts => [
    line,
    if (quickStep != null) quickStep!,
    buttonLabel,
    if (buttonNote != null) buttonNote!,
  ];

  @override
  String toString() => 'BluetoothOffView($texts)';
}

/// "Bluetooth is off" for the platform (pure). Android: one line and "Turn
/// on", which asks the system to turn Bluetooth on. iOS has no API for that
/// and no link to Settings → Bluetooth, so Control Center leads, and "Open
/// Settings" says right under it that it opens this app's page.
BluetoothOffView bluetoothOffViewFor({required bool isIOS}) => isIOS
    ? const BluetoothOffView(
        line: bluetoothOffLine,
        quickStep: bluetoothOffQuickStepIOS,
        buttonLabel: 'Open Settings',
        turnsOn: false,
        buttonNote: bluetoothOffSettingsNoteIOS,
      )
    : const BluetoothOffView(
        line: bluetoothOffLine,
        buttonLabel: 'Turn on',
        turnsOn: true,
      );

/// What to do when the app isn't allowed to use Bluetooth.
const String bluetoothPermissionLine =
    'Allow Bluetooth so the app can talk to Smarty';

/// The hint under "Bluetooth permission needed", above its Open Settings
/// button. That button opens this app's own page in Settings — the right
/// place this time: on iOS the Bluetooth switch for the app is on that page,
/// so name the page and the switch.
String bluetoothPermissionHint({required bool isIOS}) => isIOS
    ? 'In Settings → $iosSettingsAppName, turn on Bluetooth, then come back.'
    : 'In Settings, turn on Bluetooth for this app, then come back.';

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
      return bluetoothOffLine;
    case ConnectFailure.needsPermission:
      return bluetoothPermissionLine;
    case ConnectFailure.notYourAccount:
      return notConfirmedMessage;
    case ConnectFailure.unknown:
      return "We couldn't finish connecting. Keep Smarty close to your phone "
          'and try again.';
  }
}

// ---- After a failed connect -----------------------------------------------------

/// What the setup page tells the parent after a failed connect. See
/// [connectAdviceFor].
enum ConnectAdvice {
  /// This phone holds a pairing the toy has dropped: [pairingBrokenHeading]
  /// and the [pairingBrokenStepList] (iOS: forget Smarty in Settings).
  forgetOldPairing,

  /// A toy linked to an account turned this phone away: it turned down this
  /// phone's account proof ([ConnectFailure.notYourAccount]), or refused to
  /// pair after no proof could be given. [notConfirmedMessage], with
  /// [resetAndSetUpAgainLine] under it. (Its buttons can't open pairing.)
  notConfirmed,

  /// A toy that isn't linked (or doesn't say) refused to pair — it was set
  /// up with another phone and isn't waiting to pair:
  /// [setUpWithAnotherPhoneMessage].
  holdButtons,

  /// The link just didn't come up, with a toy that isn't linked (or doesn't
  /// say) and said it isn't waiting to pair: [maybeAnotherPhoneMessage].
  maybeHoldButtons,

  /// The plain line for the failure ([connectFailureMessage]).
  plain,
}

/// [ConnectAdvice] for a failed connect (pure).
///
/// - [kind]: the failure.
/// - [staleBond]: the phone's Bluetooth said outright that the toy dropped
///   this phone's pairing ([ConnectException.staleBond]).
/// - [yours]: the toy is this account's (a known toy — on a freshly set up
///   phone there is no old pairing to forget).
/// - [advertPairing]: what the toy said about waiting to pair just before
///   (null = not reported).
/// - [registered]: what the toy said about being linked to an account just
///   before ([ToyAdvert.registered]; null = not reported).
///
/// The toy turning down this phone's account proof
/// ([ConnectFailure.notYourAccount]) means the account isn't the toy's:
/// [ConnectAdvice.notConfirmed]. A refused pairing
/// ([ConnectFailure.pairingBroken]) means "forget the old pairing" only
/// when the phone said so, or when the toy said it IS waiting to pair (it
/// would have taken a new pairing, so the old one on this phone is what got
/// in the way). Otherwise a linked toy didn't take this phone as its
/// account's: [ConnectAdvice.notConfirmed] (its buttons can't open
/// pairing). For the account's own toy that isn't linked, or a toy that
/// said it isn't waiting to pair, it was set up with another phone: hold
/// the buttons. Anything else keeps the old-pairing steps. A link that just
/// didn't come up with a toy that isn't linked and isn't waiting to pair
/// may be the same: [ConnectAdvice.maybeHoldButtons].
ConnectAdvice connectAdviceFor(
  ConnectFailure kind, {
  bool staleBond = false,
  bool yours = false,
  bool? advertPairing,
  bool? registered,
}) {
  final bool linked = registered == true;
  switch (kind) {
    case ConnectFailure.notYourAccount:
      return ConnectAdvice.notConfirmed;
    case ConnectFailure.pairingBroken:
      if (staleBond || advertPairing == true) {
        return ConnectAdvice.forgetOldPairing;
      }
      if (linked) return ConnectAdvice.notConfirmed;
      if (yours || advertPairing == false) return ConnectAdvice.holdButtons;
      return ConnectAdvice.forgetOldPairing;
    case ConnectFailure.unknown:
      if (linked || advertPairing != false) return ConnectAdvice.plain;
      return ConnectAdvice.maybeHoldButtons;
    default:
      return ConnectAdvice.plain;
  }
}

/// [ConnectAdvice.notConfirmed] (and [ConnectFailure.notYourAccount]):
/// this phone couldn't prove the toy is its account's. Shown with
/// [resetAndSetUpAgainLine] under it on the setup page.
const String notConfirmedMessage =
    "Couldn't confirm this is your Smarty. Check you're signed in with the "
    'account it was set up with, then tap Try again.';

/// [ConnectAdvice.holdButtons]: a toy that isn't linked, set up with another
/// phone.
const String setUpWithAnotherPhoneMessage =
    'This Smarty was set up with another phone. Hold the + and – buttons on '
    'it for 3 seconds, then tap Try again.';

/// [ConnectAdvice.maybeHoldButtons].
const String maybeAnotherPhoneMessage =
    "We couldn't finish connecting. If this Smarty was set up with another "
    'phone, hold the + and – buttons on it for 3 seconds, then tap Try again.';

/// Reconnecting found a toy with the right name, but it said it is a
/// different toy from the one on this account.
const String notYourToyMessage =
    "That Smarty isn't the one on your account. Tap Try again to look for "
    'yours.';

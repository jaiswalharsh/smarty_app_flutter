import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'dev_config.dart';
import 'screens/user_context_page.dart';
import 'services/ble_manager.dart';
import 'services/ble_service.dart';
import 'services/known_toys_service.dart';
import 'screens/conversations/live_chat_banner.dart';
import 'screens/devices/setup_steps.dart';
import 'screens/devices/smarty_connection_page.dart';
import 'screens/wifi/wifi_config_page.dart';
import 'widgets/forget_toy.dart';
import 'widgets/numbered_steps.dart';
import 'widgets/remove_toy.dart';
import 'widgets/smarty_card.dart';

/// One-line, parent-facing status for the toy on Home's Smarty card ([short]:
/// the compact form). Plain words only — no "device", "scan", "BLE".
/// [statusStalled] = a connected toy never answered the status read.
/// [phase] defaults to [BleManager.phase].
String toyStatusLine(
  BleManager ble, {
  bool short = false,
  bool statusStalled = false,
  ToyPhase? phase,
}) {
  final bool seenRecently = ble.savedToySeenRecently;
  return toyStatusLineFor(
    phase: phase ?? ble.phase.value,
    wifi: ble.connectedWifi,
    registered: ble.registered,
    lastKnownWifiName: ble.lastKnownWifiName,
    short: short,
    statusStalled: statusStalled,
    seenRecently: seenRecently,
    advertWifiUp: seenRecently ? ble.lastSeenAdvert?.wifiUp : null,
  );
}

/// [toyStatusLine] from plain values (pure, for tests). [wifi] is the raw
/// status value the toy reported; [linkingEnabled] defaults to the build's
/// [DevConfig.linkingEnabled].
///
/// [seenRecently]: the toy was just seen advertising, so it is on — in
/// [ToyPhase.notNearby] that means "connecting", not "asleep".
/// [advertWifiUp]: the Wi-Fi flag from that recent advert (null = not
/// reported); lets a connected toy show "not on Wi-Fi" before its first
/// status arrives.
String toyStatusLineFor({
  required ToyPhase phase,
  required String wifi,
  required bool? registered,
  String? lastKnownWifiName,
  bool short = false,
  bool statusStalled = false,
  bool linkingEnabled = DevConfig.linkingEnabled,
  bool seenRecently = false,
  bool? advertWifiUp,
}) {
  switch (phase) {
    case ToyPhase.noToy:
      return short ? 'Not set up yet' : "Let's set up your Smarty";
    case ToyPhase.bluetoothOff:
      return short
          ? 'Bluetooth is off on this phone'
          : 'Turn on Bluetooth on your phone to reach Smarty';
    case ToyPhase.needsPermission:
      return short
          ? 'Bluetooth permission needed'
          : 'Allow Bluetooth so the app can talk to Smarty';
    case ToyPhase.probing:
      return 'Looking for Smarty…';
    case ToyPhase.notNearby:
      if (seenRecently) {
        return short ? 'On — connecting…' : 'Smarty is on — connecting…';
      }
      return short
          ? 'Asleep or out of reach'
          : "Smarty is asleep or out of reach. Turn it on — it'll connect by itself.";
    case ToyPhase.connecting:
      return 'Connecting to Smarty…';
    case ToyPhase.pairingBroken:
      return short
          ? 'Needs reconnecting — see Home'
          : 'Your phone remembers an old connection to Smarty.';
    case ToyPhase.connected:
      break;
  }

  final String status = wifi.trim();
  final bool waiting =
      status.isEmpty || status == 'Unknown' || status == 'NotConnected';
  if (waiting) {
    if (statusStalled) return "Couldn't check on Smarty";
    // The toy's advert already said it isn't on Wi-Fi — but not why (no
    // Wi-Fi saved, or its saved Wi-Fi is down), so no "yet" here.
    if (advertWifiUp == false) {
      return short ? 'Not on Wi-Fi' : "Smarty isn't on Wi-Fi right now";
    }
    return 'Checking on Smarty…';
  }
  if (linkingEnabled && registered == false) {
    return 'Almost done — finish setup';
  }
  switch (status) {
    // Same words as the setup page (setup_steps.dart).
    case 'Auth Failed':
      if (short) return "Can't join Wi-Fi";
      return wifiAuthFailedLine(lastKnownWifiName);
    case 'Connection Failed':
      return short
          ? "Can't reach Wi-Fi"
          : '${wifiUnreachableLine(lastKnownWifiName)} It keeps trying.';
    case 'Initializing':
    case 'Reconnecting':
      return 'Smarty is joining Wi-Fi…';
    case 'No credentials':
      // The only state that means "Wi-Fi was never set up on this toy".
      return short ? 'Not on Wi-Fi yet' : "Smarty isn't on Wi-Fi yet";
  }
  if (!BleManager.isWifiConnectedStatus(wifi)) {
    return short ? 'Wi-Fi trouble' : 'Smarty is having trouble with Wi-Fi';
  }
  return 'Ready to play';
}

/// The line under "Reconnect your Smarty" (Home, no toy on this phone but
/// one on the account): names the toy the way it shows over Bluetooth
/// ([bleName], e.g. "Smarty-B11E"), or just "a Smarty" when unknown. Pure.
String reconnectOfferLine(String? bleName) {
  final String? name = normalizeBleName(bleName);
  return 'You set up ${name ?? 'a Smarty'} on this account before.';
}

/// The line under "Reconnect your Smarty" for the account's [toys]: the one
/// toy by name ([reconnectOfferLine]), or how many there are. Pure.
String reconnectOfferLineFor(List<KnownToy> toys) => toys.length == 1
    ? reconnectOfferLine(toys.single.bleName)
    : 'You set up ${toys.length} Smarty toys on this account before.';

/// Whether Home's Smarty card shows its small inline spinner. Pure (tests).
///
/// Probing / connecting always spin — except while a pull-to-refresh is
/// running ([pullRefreshing]): the pull's own spinner is already on screen,
/// so the card keeps only its text (one spinner at a time). Connected: only
/// while the first status is still on its way ([waitingForStatus]) and not
/// given up on ([statusStalled]), and not when the toy's advert already said
/// it isn't on Wi-Fi ([advertSaysNoWifi]).
bool homeToyCardBusy({
  required ToyPhase phase,
  bool waitingForStatus = false,
  bool statusStalled = false,
  bool advertSaysNoWifi = false,
  bool pullRefreshing = false,
}) {
  if (pullRefreshing) return false;
  switch (phase) {
    case ToyPhase.probing:
    case ToyPhase.connecting:
      return true;
    case ToyPhase.connected:
      return waitingForStatus && !statusStalled && !advertSaysNoWifi;
    case ToyPhase.noToy:
    case ToyPhase.bluetoothOff:
    case ToyPhase.needsPermission:
    case ToyPhase.notNearby:
    case ToyPhase.pairingBroken:
      return false;
  }
}

class HomeTab extends StatefulWidget {
  const HomeTab({
    super.key,
    @visibleForTesting this.toyPhase,
    @visibleForTesting this.knownToys,
    @visibleForTesting this.savedToyCloudId,
  });

  /// Where the app stands with Smarty; [BleManager.phase] unless a test
  /// supplies its own.
  final ValueListenable<ToyPhase>? toyPhase;

  /// The account's toys (for "Reconnect your Smarty");
  /// [KnownToysService.instance] unless a test supplies its own.
  final KnownToys? knownToys;

  /// The cloud id of the toy saved on this phone, for "⋯ → Remove from my
  /// account"; worked out from [BleManager] and the account's toys unless a
  /// test supplies its own.
  final Future<String?> Function()? savedToyCloudId;

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with SingleTickerProviderStateMixin {
  final BleManager _bleManager = BleManager();
  late final ValueListenable<ToyPhase> _phase =
      widget.toyPhase ?? _bleManager.phase;
  late AnimationController _animationController;
  bool _showSuccessState = false;
  StreamSubscription? _wifiStatusSubscription;
  // Watchdog for a status read that never lands: if a connected toy stays on
  // "Unknown" past the timeout, offer a manual refresh instead of spinning
  // "Checking on Smarty…" forever.
  Timer? _wifiStallTimer;
  bool _wifiStatusStalled = false;
  static const Duration _wifiStallTimeout = Duration(seconds: 4);
  // Repaints "Smarty is on — connecting…" back to "asleep or out of reach"
  // once the probe's sighting is no longer recent.
  Timer? _sightingTimer;
  // A pull-to-refresh is running: its own spinner is showing, so the card
  // hides its own (one spinner at a time).
  bool _pullRefreshing = false;
  // Looking / connecting for longer than [_busyHintAfter]: the busy view then
  // offers "Check again" instead of spinning with no way out.
  Timer? _busyTimer;
  bool _busyLong = false;
  static const Duration _busyHintAfter = Duration(seconds: 12);
  // Upper bounds for a manual refresh, so the pull spinner always ends. The
  // work itself carries on in the background (BleManager keeps re-reading a
  // transitional status by itself).
  static const Duration _statusReadBound = Duration(seconds: 4);
  static const Duration _watchBound = Duration(seconds: 6);

  // ---- No toy on this phone: is one on the account? ------------------------
  // A freshly installed app (or a new phone) has no saved toy, so
  // watchSavedToy settles on noToy. Each time Home lands on noToy it asks
  // the account for its toys (read once per account, then from memory — see
  // KnownToysService) and, if there are any, offers "Reconnect your Smarty"
  // instead of a plain setup. Not after the parent forgot their Smarty on
  // purpose (_forgetToy): that holds the offer back until the app is next
  // launched or another account signs in.
  late final KnownToys _knownToys =
      widget.knownToys ?? KnownToysService.instance;
  // The account's toys; null while the look-up runs.
  List<KnownToy>? _accountToys;
  int _accountToysGen = 0;
  ToyPhase? _lastPhase;

  @override
  void initState() {
    super.initState();

    // Repaint the card whenever the toy reports status.
    _wifiStatusSubscription = _bleManager.wifiStatusStream.listen((_) {
      if (!mounted) return;
      // A status event just proved the link is alive — stand down the stall watch.
      _wifiStallTimer?.cancel();
      setState(() {
        _wifiStatusStalled = false;
      });
    });

    _phase.addListener(_onPhaseChanged);
    _bleManager.registeredListenable.addListener(_onRegisteredChanged);
    _onPhaseChanged();

    // No per-frame setState listener: the AnimatedBuilders in the success view
    // already rebuild exactly the animated parts.
    _animationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 800),
    );
  }

  @override
  void dispose() {
    _phase.removeListener(_onPhaseChanged);
    _bleManager.registeredListenable.removeListener(_onRegisteredChanged);
    _wifiStatusSubscription?.cancel();
    _wifiStallTimer?.cancel();
    _sightingTimer?.cancel();
    _busyTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _onPhaseChanged() {
    final ToyPhase phase = _phase.value;
    // Only on arriving at noToy (sign-in, Forget, a toy owned elsewhere…);
    // the phase's own rebuild shows the result.
    if (phase == ToyPhase.noToy && _lastPhase != ToyPhase.noToy) {
      _lookUpAccountToys();
    }
    _lastPhase = phase;
    if (phase == ToyPhase.connected) {
      _armWifiStallTimer();
    } else {
      _wifiStallTimer?.cancel();
      _wifiStatusStalled = false;
    }
    _armSightingTimer();
    _armBusyTimer(phase);
  }

  // Probing and connecting share one clock: a look that finds the toy and
  // goes straight on to connecting is still one wait for the parent.
  void _armBusyTimer(ToyPhase phase) {
    final bool busy = phase == ToyPhase.probing || phase == ToyPhase.connecting;
    if (!busy) {
      _busyTimer?.cancel();
      _busyTimer = null;
      _busyLong = false; // the ValueListenableBuilder rebuild picks this up
      return;
    }
    if (_busyTimer != null || _busyLong) return;
    _busyTimer = Timer(_busyHintAfter, () {
      _busyTimer = null;
      if (!mounted) return;
      final ToyPhase now = _phase.value;
      if (now != ToyPhase.probing && now != ToyPhase.connecting) return;
      setState(() => _busyLong = true);
    });
  }

  // Ask the account for its toys (see _knownToys). Sets the field directly:
  // callers rebuild (a phase change, or their own setState).
  void _lookUpAccountToys() {
    final int gen = ++_accountToysGen;
    if (!_knownToys.offerReconnect) {
      _accountToys = const [];
      return;
    }
    _accountToys = null;
    _knownToys.knownToysForAccount().then(
      (toys) {
        if (!mounted || gen != _accountToysGen) return;
        setState(() => _accountToys = toys);
      },
      onError: (Object e) {
        debugPrint('HomeTab: toys on the account: $e');
        if (!mounted || gen != _accountToysGen) return;
        setState(() => _accountToys = const []);
      },
    );
  }

  // While not nearby but just seen, rebuild when the sighting goes stale.
  void _armSightingTimer() {
    _sightingTimer?.cancel();
    _sightingTimer = null;
    final seenAt = _bleManager.lastSeenAt;
    if (_phase.value != ToyPhase.notNearby || seenAt == null) {
      return;
    }
    final left =
        BleManager.recentSightingWindow - DateTime.now().difference(seenAt);
    if (left <= Duration.zero) return;
    _sightingTimer = Timer(left, () {
      if (mounted) setState(() {});
    });
  }

  void _onRegisteredChanged() {
    if (mounted) setState(() {});
  }

  // Theme-aware text colours so headings/body copy stay readable in dark mode.
  Color get _headingColor => Theme.of(context).colorScheme.onSurface;
  Color get _secondaryTextColor =>
      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7);

  // Owns the "you're done!" celebration: flip the flag AND kick off the
  // animation here (not in build) so triggering it stays a deliberate action
  // rather than a build side-effect. The success view only renders while the
  // toy is connected (see _buildForPhase).
  void _activateSuccessCelebration() {
    if (!mounted) return;
    setState(() {
      _showSuccessState = true;
    });
    _animationController.forward(from: 0);
  }

  // Manual status refresh (pull-to-refresh, "Check again", the Wi-Fi row's
  // refresh): a fresh read of the status when connected, otherwise a fresh
  // look for the toy. Always completes within a few seconds — a
  // RefreshIndicator spins until it does — while the read / look itself
  // carries on in the background and updates the screen when it lands.
  Future<void> _refreshStatus() async {
    if (!_bleManager.isConnected) {
      await _bleManager
          .watchSavedToy()
          .timeout(_watchBound, onTimeout: () {})
          .catchError((Object e) {
            debugPrint('HomeTab: check failed: $e');
          });
      if (mounted) _armWifiStallTimer();
      return;
    }
    await _bleManager
        .readStatusUpdate()
        .timeout(_statusReadBound, onTimeout: () {})
        .catchError((Object e) {
          debugPrint('HomeTab: status read failed: $e');
        });
    if (!mounted) return;
    setState(() {
      _wifiStatusStalled = false;
    });
    // Empty read (still "Unknown")? Re-arm the watchdog. Also cancels any prior timer.
    _armWifiStallTimer();
  }

  // Pull-to-refresh: the same refresh, with the card's own spinner hidden
  // while the pull's spinner shows.
  Future<void> _onPullToRefresh() async {
    if (mounted) setState(() => _pullRefreshing = true);
    try {
      await _refreshStatus();
    } finally {
      if (mounted) setState(() => _pullRefreshing = false);
    }
  }

  bool get _waitingForStatus {
    final wifi = _bleManager.connectedWifi.trim();
    return wifi.isEmpty || wifi == 'Unknown' || wifi == 'NotConnected';
  }

  // (Re)start the stall watchdog. Only arms while connected and still waiting
  // on the first status; a landed status (via wifiStatusStream) cancels it.
  // Never call from build() — this schedules a timer.
  void _armWifiStallTimer() {
    _wifiStallTimer?.cancel();
    if (_waitingForStatus && _bleManager.isConnected) {
      _wifiStallTimer = Timer(_wifiStallTimeout, () {
        if (!mounted || !_waitingForStatus) return;
        setState(() {
          _wifiStatusStalled = true;
        });
      });
    }
  }

  // Opens the pair/setup flow. Shared by "Set up Smarty", "Connect"
  // (reconnect [reconnectTo]), "Finish setup" and "Set up a different
  // Smarty" ([newToy]) so the success-celebration and re-check handling
  // lives in exactly one place.
  void _openConnectionPage({KnownToy? reconnectTo, bool newToy = false}) {
    Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder:
            (context) => SmartyConnectionPage(
              reconnectTo: reconnectTo,
              newToy: newToy,
              knownToys: _knownToys,
            ),
      ),
    ).then((result) {
      if (!mounted) return;
      // `true` means setup finished (linked and on Wi-Fi) — celebrate.
      // Leaving early ("Later", back) pops with no result, so no confetti.
      if (result == true) {
        _activateSuccessCelebration();
      }
      setState(() {
        // Still no toy here: the account's toys may have changed meanwhile.
        if (_phase.value == ToyPhase.noToy) _lookUpAccountToys();
      });
      unawaited(_bleManager.watchSavedToy());
    });
  }

  Future<void> _openWifiSetup() async {
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => WifiConfigPage()),
    );
    await _refreshStatus();
  }

  void _openAboutChild() {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const UserContextPage()),
    );
  }

  // "⋯" → "Forget this Smarty": asks first; Home then shows "Set up Smarty"
  // (the phase moves to noToy) — not "Reconnect your Smarty": forgetting is
  // what the parent wanted, so the offer is held back (before the phase
  // moves, so the look-up it starts already knows).
  Future<void> _forgetToy() async {
    await confirmAndForgetToy(
      context,
      forget: () async {
        _knownToys.holdBackReconnectOffer();
        await _bleManager.forgetToy();
      },
    );
    if (mounted) setState(() {});
  }

  // "I don't have this Smarty any more" on the Reconnect card: asks first,
  // takes the toy off the account, then shows what's left.
  Future<void> _removeKnownToy(KnownToy toy) async {
    final bool removed = await confirmAndRemoveToy(
      context,
      bleName: toy.bleName,
      remove:
          (keep) =>
              _knownToys.removeFromAccount(toy.deviceId, keepHistory: keep),
    );
    if (!removed || !mounted) return;
    setState(() {
      if (_phase.value == ToyPhase.noToy) _lookUpAccountToys();
    });
  }

  // "⋯" → "Remove from my account" for the toy saved on this phone: asks
  // first, takes it off the account and forgets it on this phone too (Home
  // then offers the account's other toys, or a plain setup).
  Future<void> _removeSavedToy() async {
    final String? name = normalizeBleName(_bleManager.savedToyName);
    await confirmAndRemoveToy(
      context,
      bleName: name,
      remove: (keep) async {
        final String? id =
            await (widget.savedToyCloudId ?? () => _savedToyCloudId(name))();
        if (id == null) {
          throw const RemoveToyException(RemoveToyProblem.notOnAccount);
        }
        await _knownToys.removeFromAccount(id, keepHistory: keep);
        // removeFromAccount forgets the phone's toy when it can tell it's
        // this one; here it surely is.
        if (_bleManager.savedToyId != null) await _bleManager.forgetToy();
      },
    );
    if (mounted) setState(() {});
  }

  // The saved toy's cloud id: read over Bluetooth this session (or now, if
  // connected), else the account's toy with its name ([name]); null when
  // none of that works.
  Future<String?> _savedToyCloudId(String? name) async {
    final String? known = _bleManager.savedToyDeviceId;
    if (known != null) return known;
    if (_bleManager.isConnected) {
      final String? read = await _bleManager
          .readDeviceId()
          .timeout(const Duration(seconds: 4), onTimeout: () => null)
          .catchError((Object e) {
            debugPrint('HomeTab: reading the toy id failed: $e');
            return null;
          });
      final String? id = read?.trim();
      if (id != null && id.isNotEmpty && id != '{}') return id;
    }
    return knownToyIdNamed(await _knownToys.knownToysForAccount(), name);
  }

  // Bluetooth-off fix: Android can show the system "turn on" dialog; iOS has
  // no API for that, so we can only open this app's page in Settings.
  void _turnOnBluetooth() {
    unawaited(_bleManager.requestBluetoothOn());
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        // No outer padding: the pull-to-refresh views pad inside their
        // scroll area, so a pull works right up to the screen's edges.
        body: SafeArea(
          child: ValueListenableBuilder<ToyPhase>(
            valueListenable: _phase,
            builder: (context, phase, _) => _buildForPhase(phase),
          ),
        ),
      ),
    );
  }

  Widget _buildForPhase(ToyPhase phase) {
    switch (phase) {
      case ToyPhase.noToy:
        return Padding(padding: _pagePadding, child: _buildNoToyView());
      case ToyPhase.connected:
        return _showSuccessState
            ? Padding(padding: _pagePadding, child: _buildSuccessView())
            : _buildConnectedView();
      case ToyPhase.probing:
      case ToyPhase.connecting:
        return _buildBusyView(phase);
      case ToyPhase.bluetoothOff:
        return _buildBluetoothOffView();
      case ToyPhase.needsPermission:
        return _buildNeedsPermissionView();
      case ToyPhase.notNearby:
        return _buildNotNearbyView();
      case ToyPhase.pairingBroken:
        return _buildPairingBrokenView();
    }
  }

  // ---- Shared building blocks ----------------------------------------------

  static const EdgeInsets _pagePadding = EdgeInsets.all(20);

  // Every pull-to-refresh view goes through here, so a pull works from
  // anywhere on the screen — including the empty space below short content.
  Widget _pullToRefresh({required Widget child}) {
    return PullToRefreshArea(
      onRefresh: _onPullToRefresh,
      padding: _pagePadding,
      child: child,
    );
  }

  // Every state with a saved toy is this one Smarty card: the header (name,
  // code, [status], a small spinner when [busy], "⋯" → Forget this Smarty),
  // the Wi-Fi and About your child rows, and [footer] (what to do next).
  // [below] sits under the card (the live-chat banner). Pull-to-refresh
  // re-runs the check from anywhere on the screen.
  Widget _buildCardView({
    required ToyPhase phase,
    required String status,
    bool busy = false,
    List<Widget> footer = const [],
    List<Widget> below = const [],
  }) {
    final String? rawName = _bleManager.savedToyName;
    return _pullToRefresh(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SmartyCard(
            name: BleManager.toyDisplayName(rawName),
            code: BleManager.toyCode(rawName),
            status: status,
            busy: busy,
            onForget: () => unawaited(_forgetToy()),
            onRemove:
                DevConfig.linkingEnabled
                    ? () => unawaited(_removeSavedToy())
                    : null,
            rows: [
              _buildWifiRow(phase),
              SmartyCardRow(
                icon: Icons.chat_bubble,
                label: 'About your child',
                detail: 'What Smarty should know about your child',
                onTap: _openAboutChild,
              ),
            ],
            footer: footer,
          ),
          ...below,
        ],
      ),
    );
  }

  // The card's only Wi-Fi line. Smarty's Wi-Fi is set over Bluetooth, so the
  // row opens the Wi-Fi page only while Smarty is connected.
  Widget _buildWifiRow(ToyPhase phase) {
    final bool connected = phase == ToyPhase.connected;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final WifiRowInfo info = wifiRowInfo(
      connected: connected,
      wifi: _bleManager.connectedWifi,
      statusStalled: _wifiStatusStalled,
    );
    final Color problem =
        dark ? Colors.orange.shade300 : Colors.orange.shade700;
    return SmartyCardRow(
      icon: info.icon,
      iconColor: info.isProblem ? problem : null,
      label: 'Wi-Fi',
      detail: info.detail,
      onTap: connected ? () => unawaited(_openWifiSetup()) : null,
      trailing: switch (info.action) {
        WifiRowAction.setUp => TextButton(
          onPressed: () => unawaited(_openWifiSetup()),
          child: Text(
            'Set up',
            style: TextStyle(color: problem, fontWeight: FontWeight.w600),
          ),
        ),
        WifiRowAction.checkAgain => IconButton(
          icon: Icon(
            Icons.refresh,
            color: dark ? Colors.white70 : Colors.blue.shade700,
          ),
          tooltip: 'Check again',
          onPressed: _recheckWifi,
        ),
        WifiRowAction.none => null,
      },
    );
  }

  // The Wi-Fi row's refresh (the status never came, or Smarty is still
  // joining): back to "Checking…" and the card's spinner while we retry.
  void _recheckWifi() {
    setState(() => _wifiStatusStalled = false);
    unawaited(_refreshStatus());
  }

  Widget _buildPrimaryButton({
    required String label,
    required IconData icon,
    required VoidCallback onPressed,
  }) {
    return AnimatedScaleButton(
      onPressed: onPressed,
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.blue.shade600,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: Colors.blue.shade200.withValues(alpha: 0.4),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 20),
            SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                color: Colors.white,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // A small grey link for the rarely wanted way out ("I don't have this
  // Smarty any more").
  Widget _buildQuietAction(String label, VoidCallback onPressed) {
    return TextButton(
      onPressed: onPressed,
      child: Text(
        label,
        style: TextStyle(fontSize: 14, color: _secondaryTextColor),
      ),
    );
  }

  Widget _buildTextAction(String label, VoidCallback onPressed) {
    return TextButton(
      onPressed: onPressed,
      child: Text(
        label,
        style: TextStyle(
          fontSize: 14,
          color: Colors.blue.shade600,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  // A saved toy that needs something done: the card, with the state in its
  // header ([status]) and, in its footer, the state's icon, what to do
  // ([body], or [bodySteps] as a numbered list), a [hint], [actions], and an
  // [actionNote] right under them (where a button goes, when its label can't
  // say).
  Widget _buildMessageView({
    required ToyPhase phase,
    required String status,
    required IconData icon,
    required Color iconColor,
    String? body,
    List<String>? bodySteps,
    String? hint,
    required List<Widget> actions,
    String? actionNote,
  }) {
    final TextStyle bodyStyle = TextStyle(
      fontSize: 16,
      color: _secondaryTextColor,
    );
    return _buildCardView(
      phase: phase,
      status: status,
      footer: [
        Icon(icon, size: 40, color: iconColor),
        SizedBox(height: 12),
        if (bodySteps != null)
          NumberedSteps(steps: bodySteps, style: bodyStyle)
        else if (body != null)
          Text(body, textAlign: TextAlign.center, style: bodyStyle),
        if (hint != null) ...[
          SizedBox(height: 8),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _secondaryTextColor),
          ),
        ],
        SizedBox(height: 16),
        for (final a in actions) Center(child: a),
        if (actionNote != null) ...[
          SizedBox(height: 8),
          Text(
            actionNote,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _secondaryTextColor),
          ),
        ],
      ],
    );
  }

  // ---- Per-phase views -------------------------------------------------------

  // No toy on this phone: "Reconnect your Smarty" when the account has one
  // (and the offer isn't held back), else the plain setup. A small spinner
  // while the account is asked (≤ 5 s, usually instant).
  Widget _buildNoToyView() {
    final List<KnownToy>? toys = _accountToys;
    if (toys == null) {
      return Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: Colors.blue.shade600,
          ),
        ),
      );
    }
    if (toys.isNotEmpty && _knownToys.offerReconnect) {
      return _buildReconnectView(toys);
    }
    return _buildNeverPairedView();
  }

  // Every toy on the account: one → its name in the line and a big Connect;
  // more → a row each ("Smarty-B11E" + Connect). Each has "I don't have this
  // Smarty any more". Scrolls when the list is long.
  Widget _buildReconnectView(List<KnownToy> toys) {
    final bool single = toys.length == 1;
    return LayoutBuilder(
      builder:
          (context, constraints) => SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Image.asset('assets/images/icon.png', width: 80, height: 80),
                    SizedBox(height: 20),
                    Text(
                      'Reconnect your Smarty',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: _headingColor,
                      ),
                    ),
                    SizedBox(height: 12),
                    Text(
                      reconnectOfferLineFor(toys),
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 16, color: _secondaryTextColor),
                    ),
                    SizedBox(height: 24),
                    if (single) ...[
                      _buildPrimaryButton(
                        label: 'Connect',
                        icon: Icons.bluetooth_searching,
                        onPressed:
                            () => _openConnectionPage(reconnectTo: toys.single),
                      ),
                      SizedBox(height: 4),
                      _buildQuietAction(
                        noLongerHaveToyLabel,
                        () => unawaited(_removeKnownToy(toys.single)),
                      ),
                    ] else
                      for (final toy in toys) _buildKnownToyRow(toy),
                    SizedBox(height: 8),
                    _buildTextAction(
                      'Set up a different Smarty',
                      () => _openConnectionPage(newToy: true),
                    ),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  // One of several toys on the Reconnect card.
  Widget _buildKnownToyRow(KnownToy toy) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 0),
      decoration: BoxDecoration(
        color: SmartyCard.background(dark),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Image.asset('assets/images/icon.png', width: 32, height: 32),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  toy.bleName ?? 'Smarty',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    color: _headingColor,
                  ),
                ),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.blue.shade600,
                  foregroundColor: Colors.white,
                ),
                onPressed: () => _openConnectionPage(reconnectTo: toy),
                child: const Text('Connect'),
              ),
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: _buildQuietAction(
              noLongerHaveToyLabel,
              () => unawaited(_removeKnownToy(toy)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNeverPairedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset('assets/images/icon.png', width: 80, height: 80),
          SizedBox(height: 20),
          Text(
            "Let's set up your Smarty",
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: _headingColor,
            ),
          ),
          SizedBox(height: 12),
          Text(
            'It only takes a minute — then the fun can start!',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 16, color: _secondaryTextColor),
          ),
          SizedBox(height: 24),
          _buildPrimaryButton(
            label: 'Set up Smarty',
            icon: Icons.add_circle_outline,
            onPressed: _openConnectionPage,
          ),
        ],
      ),
    );
  }

  // Probing / connecting: the card with an inline spinner — nothing
  // full-screen, nothing blocking. If it drags on, offer a visible way out
  // (pull-to-refresh alone is easy to miss).
  Widget _buildBusyView(ToyPhase phase) {
    return _buildCardView(
      phase: phase,
      status: toyStatusLine(_bleManager, phase: phase),
      busy: homeToyCardBusy(phase: phase, pullRefreshing: _pullRefreshing),
      footer: [
        if (_busyLong) ...[
          Text(
            'This is taking longer than usual. Make sure Smarty is on and close to your phone.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _secondaryTextColor),
          ),
          SizedBox(height: 8),
          Center(
            child: _buildTextAction(
              'Check again',
              () => unawaited(_refreshStatus()),
            ),
          ),
        ],
      ],
    );
  }

  // Same copy as the setup page (bluetoothOffViewFor). iOS: Control Center
  // first; "Open Settings" can only open this app's page, and says so under it.
  Widget _buildBluetoothOffView() {
    final BluetoothOffView view = bluetoothOffViewFor(isIOS: Platform.isIOS);
    return _buildMessageView(
      phase: ToyPhase.bluetoothOff,
      status: 'Bluetooth is off on this phone',
      icon: Icons.bluetooth_disabled,
      iconColor: Colors.blue.shade400,
      body: view.line,
      hint: view.quickStep,
      actions: [
        _buildPrimaryButton(
          label: view.buttonLabel,
          icon: view.turnsOn ? Icons.bluetooth : Icons.settings,
          onPressed: _turnOnBluetooth,
        ),
      ],
      actionNote: view.buttonNote,
    );
  }

  Widget _buildNeedsPermissionView() {
    return _buildMessageView(
      phase: ToyPhase.needsPermission,
      status: 'Bluetooth permission needed',
      icon: Icons.bluetooth_searching,
      iconColor: Colors.blue.shade400,
      body: bluetoothPermissionLine,
      hint: bluetoothPermissionHint(isIOS: Platform.isIOS),
      actions: [
        _buildPrimaryButton(
          label: 'Open Settings',
          icon: Icons.settings,
          onPressed: () => unawaited(BleService.openAppPermissionSettings()),
        ),
      ],
    );
  }

  // Deliberately does NOT say the toy is off: a short look that sees nothing
  // can't tell off from out of reach (or busy with another phone). A
  // background connect is already waiting, so no action is required. If the
  // look DID just see the toy (the connect hasn't happened yet, or failed and
  // will be retried), say it's on and connecting instead.
  Widget _buildNotNearbyView() {
    final bool seen = _bleManager.savedToySeenRecently;
    return _buildMessageView(
      phase: ToyPhase.notNearby,
      status:
          seen
              ? 'Smarty is on — connecting…'
              : 'Smarty is asleep or out of reach',
      icon: seen ? Icons.bluetooth_searching : Icons.bedtime_outlined,
      iconColor: seen ? Colors.blue.shade400 : Colors.indigo.shade300,
      body:
          seen
              ? "Keep it close to your phone. It'll connect by itself."
              : "Turn it on — it'll connect by itself.",
      actions: [
        _buildPrimaryButton(
          label: 'Check again',
          icon: Icons.refresh,
          onPressed: () => unawaited(_bleManager.watchSavedToy()),
        ),
        SizedBox(height: 12),
        _buildTextAction(
          'Set up a different Smarty',
          () => _openConnectionPage(newToy: true),
        ),
      ],
    );
  }

  Widget _buildPairingBrokenView() {
    final bool isIOS = Platform.isIOS;
    return _buildMessageView(
      phase: ToyPhase.pairingBroken,
      status: pairingBrokenHeading,
      icon: Icons.link_off,
      iconColor: Colors.orange.shade400,
      bodySteps: pairingBrokenStepList(isIOS: isIOS),
      actions: [
        // Opens setup, not just another quick look: the setup page keeps
        // looking for as long as it's open, proves this phone is on the
        // toy's account (so a linked toy lets it pair again), and says what
        // to do if the toy still refuses.
        _buildPrimaryButton(
          label: 'Try again',
          icon: Icons.refresh,
          onPressed: _openConnectionPage,
        ),
        if (isIOS) ...[
          SizedBox(height: 12),
          _buildTextAction(
            'Open Settings',
            () => unawaited(BleService.openBluetoothSettings()),
          ),
        ],
      ],
    );
  }

  Widget _buildConnectedView() {
    final bool needsLinkStep =
        DevConfig.linkingEnabled &&
        !_waitingForStatus &&
        _bleManager.registered == false;

    return _buildCardView(
      phase: ToyPhase.connected,
      status: toyStatusLine(
        _bleManager,
        statusStalled: _wifiStatusStalled,
        phase: ToyPhase.connected,
      ),
      // No spinner once the advert has already told us "not on Wi-Fi", nor
      // during a pull (its own spinner shows).
      busy: homeToyCardBusy(
        phase: ToyPhase.connected,
        waitingForStatus: _waitingForStatus,
        statusStalled: _wifiStatusStalled,
        advertSaysNoWifi:
            _bleManager.savedToySeenRecently &&
            _bleManager.lastSeenAdvert?.wifiUp == false,
        pullRefreshing: _pullRefreshing,
      ),
      footer: [
        if (needsLinkStep)
          Center(
            child: _buildPrimaryButton(
              label: 'Finish setup',
              icon: Icons.check_circle_outline,
              onPressed: _openConnectionPage,
            ),
          ),
      ],
      // "Smarty is talking with your child — tap to watch", only while live.
      below: const [LiveChatBanner()],
      // NOTE: battery status intentionally omitted — the device has no
      // battery sensing yet (firmware returns a fixed placeholder), so showing
      // a precise "%" would mislead parents (APP-7 / FW-21). Add it to the
      // card once real battery telemetry exists.
    );
  }

  Widget _buildSuccessView() {
    return SetupSuccessView(
      animation: _animationController,
      onContinue: () {
        setState(() {
          _showSuccessState = false;
          _animationController.reset();
        });
      },
    );
  }
}

/// Pull-to-refresh that works from anywhere on the screen, not just on the
/// content: the scroll area always fills the available height (so a drag in
/// the empty space below short content still pulls) and can always scroll
/// (so a pull works even when nothing overflows). [padding] sits inside the
/// scroll area, so the pull reaches right up to the edges. [child] is at
/// least the padded screen height tall, so a Column inside can still center
/// or spread its content.
class PullToRefreshArea extends StatelessWidget {
  const PullToRefreshArea({
    super.key,
    required this.onRefresh,
    required this.child,
    this.padding = EdgeInsets.zero,
  });

  final RefreshCallback onRefresh;
  final EdgeInsets padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder:
          (context, constraints) => RefreshIndicator(
            onRefresh: onRefresh,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: padding,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  minHeight: max(0, constraints.maxHeight - padding.vertical),
                ),
                child: child,
              ),
            ),
          ),
    );
  }
}

/// Home's "you're done!" celebration after setup: a check mark, "Connected!",
/// a Continue button, and a confetti burst driven by [animation] (0 → 1;
/// hidden at exactly 0 and 1).
class SetupSuccessView extends StatelessWidget {
  final Animation<double> animation;
  final VoidCallback onContinue;

  const SetupSuccessView({
    super.key,
    required this.animation,
    required this.onContinue,
  });

  @override
  Widget build(BuildContext context) {
    // Confetti sits in a Stack over the content (Positioned.fill gives it the
    // bounded size a CustomPaint needs — Size.infinite inside the Column threw
    // an unbounded-height assertion) and ignores taps so "Continue" works.
    return Stack(
      children: [
        Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedBuilder(
                animation: animation,
                builder: (context, child) {
                  return Transform.scale(
                    scale: 0.8 + (animation.value * 0.2),
                    child: Container(
                      width: 100,
                      height: 100,
                      decoration: BoxDecoration(
                        color: Colors.green.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.check,
                        size: 60,
                        color: Colors.green.shade600,
                      ),
                    ),
                  );
                },
              ),
              SizedBox(height: 20),
              Text(
                'Connected!',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              SizedBox(height: 12),
              Text(
                'Your Smarty is ready.',
                style: TextStyle(
                  fontSize: 16,
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
              SizedBox(height: 24),
              AnimatedScaleButton(
                onPressed: onContinue,
                child: Container(
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade600,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.blue.shade200.withValues(alpha: 0.4),
                        blurRadius: 8,
                        offset: Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Text(
                    'Continue',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: animation,
              builder: (context, child) {
                final double value = animation.value;
                // Hidden before the burst starts and once it has finished.
                return value > 0 && value < 1.0
                    ? CustomPaint(painter: ConfettiPainter(progress: value))
                    : SizedBox.shrink();
              },
            ),
          ),
        ),
      ],
    );
  }
}

class ConfettiPainter extends CustomPainter {
  final double progress;

  // Particles are generated ONCE from a fixed seed, so every frame paints the
  // same particles at their new positions (an unseeded Random per paint made
  // them jump around randomly each frame).
  static final List<_ConfettiParticle> _particles = _generateParticles();

  static List<_ConfettiParticle> _generateParticles() {
    final random = Random(42);
    final colors = [
      Colors.blue.shade400,
      Colors.green.shade400,
      Colors.yellow.shade400,
      Colors.red.shade400,
    ];
    return List.generate(50, (_) {
      return _ConfettiParticle(
        x: random.nextDouble(),
        fall: random.nextDouble(),
        color: colors[random.nextInt(colors.length)],
        size: 4 + random.nextDouble() * 4,
      );
    });
  }

  ConfettiPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;

    for (final p in _particles) {
      final x = p.x * size.width;
      final y =
          size.height * (0.3 + 0.7 * progress) -
          p.fall * size.height * progress;
      paint.color = p.color;
      canvas.drawCircle(Offset(x, y), p.size / 2, paint);
    }
  }

  @override
  bool shouldRepaint(ConfettiPainter oldDelegate) =>
      oldDelegate.progress != progress;
}

class _ConfettiParticle {
  final double x; // 0..1 fraction of width
  final double fall; // 0..1 fraction of height travelled upward over the burst
  final Color color;
  final double size;

  const _ConfettiParticle({
    required this.x,
    required this.fall,
    required this.color,
    required this.size,
  });
}

class AnimatedScaleButton extends StatefulWidget {
  final VoidCallback onPressed;
  final Widget child;

  const AnimatedScaleButton({
    required this.onPressed,
    required this.child,
    super.key,
  });

  @override
  State<AnimatedScaleButton> createState() => _AnimatedScaleButtonState();
}

class _AnimatedScaleButtonState extends State<AnimatedScaleButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 100),
    );
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: 0.95,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onPressed();
      },
      onTapCancel: () => _controller.reverse(),
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: widget.child,
          );
        },
      ),
    );
  }
}

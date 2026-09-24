import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';
import 'package:flutter/material.dart';
import 'dev_config.dart';
import 'services/ble_manager.dart';
import 'services/ble_service.dart';
import 'screens/devices/setup_steps.dart';
import 'screens/devices/smarty_connection_page.dart';
import 'screens/wifi/wifi_config_page.dart';

/// One-line, parent-facing status for the toy, shared by Home (full) and
/// Settings ([short]). Plain words only — no "device", "scan", "BLE".
/// [statusStalled] = a connected toy never answered the status read.
String toyStatusLine(
  BleManager ble, {
  bool short = false,
  bool statusStalled = false,
}) {
  return toyStatusLineFor(
    phase: ble.phase.value,
    wifi: ble.connectedWifi,
    registered: ble.registered,
    lastKnownWifiName: ble.lastKnownWifiName,
    short: short,
    statusStalled: statusStalled,
  );
}

/// [toyStatusLine] from plain values (pure, for tests). [wifi] is the raw
/// status value the toy reported; [linkingEnabled] defaults to the build's
/// [DevConfig.linkingEnabled].
String toyStatusLineFor({
  required ToyPhase phase,
  required String wifi,
  required bool? registered,
  String? lastKnownWifiName,
  bool short = false,
  bool statusStalled = false,
  bool linkingEnabled = DevConfig.linkingEnabled,
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
    return statusStalled ? "Couldn't check on Smarty" : 'Checking on Smarty…';
  }
  if (linkingEnabled && registered == false) {
    return 'Almost done — finish setup';
  }
  switch (status) {
    case 'Auth Failed':
      final ssid = lastKnownWifiName;
      if (short) return "Can't join Wi-Fi";
      return ssid != null
          ? "Smarty can't join '$ssid' — was the password changed?"
          : "Smarty can't join your Wi-Fi — was the password changed?";
    case 'Connection Failed':
      return short
          ? "Can't reach Wi-Fi"
          : "Smarty can't reach your Wi-Fi — is the router on? It keeps trying.";
    case 'Initializing':
    case 'Reconnecting':
      return 'Smarty is joining Wi-Fi…';
  }
  if (!BleManager.isWifiConnectedStatus(wifi)) {
    return short ? 'Not on Wi-Fi yet' : "Smarty isn't on Wi-Fi yet";
  }
  return 'Ready to play';
}

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with SingleTickerProviderStateMixin {
  final BleManager _bleManager = BleManager();
  late AnimationController _animationController;
  bool _showSuccessState = false;
  StreamSubscription? _wifiStatusSubscription;
  // Watchdog for a status read that never lands: if a connected toy stays on
  // "Unknown" past the timeout, offer a manual refresh instead of spinning
  // "Checking on Smarty…" forever.
  Timer? _wifiStallTimer;
  bool _wifiStatusStalled = false;
  static const Duration _wifiStallTimeout = Duration(seconds: 4);

  @override
  void initState() {
    super.initState();

    // Repaint the connected card whenever the toy reports status.
    _wifiStatusSubscription = _bleManager.wifiStatusStream.listen((_) {
      if (!mounted) return;
      // A status event just proved the link is alive — stand down the stall watch.
      _wifiStallTimer?.cancel();
      setState(() {
        _wifiStatusStalled = false;
      });
    });

    _bleManager.phase.addListener(_onPhaseChanged);
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
    _bleManager.phase.removeListener(_onPhaseChanged);
    _bleManager.registeredListenable.removeListener(_onRegisteredChanged);
    _wifiStatusSubscription?.cancel();
    _wifiStallTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _onPhaseChanged() {
    if (_bleManager.phase.value == ToyPhase.connected) {
      _armWifiStallTimer();
    } else {
      _wifiStallTimer?.cancel();
      _wifiStatusStalled = false;
    }
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

  // Manual status refresh (pull-to-refresh, or the "couldn't check" retry): a
  // fresh read of the status, then re-arm the stall watch if we're still
  // waiting on a first value.
  Future<void> _refreshStatus() async {
    if (!_bleManager.isConnected) {
      await _bleManager.watchSavedToy();
      return;
    }
    await _bleManager.readStatusUpdate();
    if (!mounted) return;
    setState(() {
      _wifiStatusStalled = false;
    });
    // Empty read (still "Unknown")? Re-arm the watchdog. Also cancels any prior timer.
    _armWifiStallTimer();
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

  // Opens the pair/setup flow. Shared by "Set up Smarty", "Finish setup" and
  // "Set up a different Smarty" so the success-celebration and re-check
  // handling lives in exactly one place.
  void _openConnectionPage() {
    Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => SmartyConnectionPage()),
    ).then((result) {
      if (!mounted) return;
      // `true` means setup finished (linked and on Wi-Fi) — celebrate.
      // Leaving early ("Later", back) pops with no result, so no confetti.
      if (result == true) {
        _activateSuccessCelebration();
      }
      setState(() {});
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

  // Bluetooth-off fix: Android can show the system "turn on" dialog; iOS has
  // no API for that, so we can only open Settings.
  void _turnOnBluetooth() {
    unawaited(_bleManager.requestBluetoothOn());
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: ValueListenableBuilder<ToyPhase>(
              valueListenable: _bleManager.phase,
              builder: (context, phase, _) => _buildForPhase(phase),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildForPhase(ToyPhase phase) {
    switch (phase) {
      case ToyPhase.noToy:
        return _buildNeverPairedView();
      case ToyPhase.connected:
        return _showSuccessState ? _buildSuccessView() : _buildConnectedView();
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

  // The toy's own card: name ("Smarty"), the 4-char code as small secondary
  // text, and a one-line status. [busy] shows a small inline spinner.
  Widget _buildToyCard({required String subtitle, bool busy = false}) {
    final String? rawName = _bleManager.savedToyName;
    final String title = BleManager.toyDisplayName(rawName);
    final String? code = BleManager.toyCode(rawName);

    return Container(
      padding: EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Container(
            padding: EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.blue.shade100,
              shape: BoxShape.circle,
            ),
            child: Image.asset(
              'assets/images/icon.png',
              width: 24,
              height: 24,
            ),
          ),
          SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: Colors.blue.shade900,
                      ),
                    ),
                    if (code != null) ...[
                      SizedBox(width: 8),
                      Text(
                        code,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.blue.shade400,
                        ),
                      ),
                    ],
                  ],
                ),
                SizedBox(height: 4),
                Row(
                  children: [
                    if (busy) ...[
                      SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.blue.shade700,
                        ),
                      ),
                      SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.blue.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
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

  // Centered "something needs doing" layout: icon, heading, body, actions.
  // Pull-to-refresh re-runs the check, and the toy card stays on top so the
  // parent always sees which Smarty this is about.
  Widget _buildMessageView({
    required IconData icon,
    required Color iconColor,
    required String heading,
    required String body,
    String? hint,
    required List<Widget> actions,
    bool showToyCard = true,
    String? toyCardSubtitle,
  }) {
    return RefreshIndicator(
      onRefresh: _bleManager.watchSavedToy,
      child: LayoutBuilder(
        builder: (context, constraints) => SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (showToyCard)
                  _buildToyCard(subtitle: toyCardSubtitle ?? heading),
                SizedBox(height: 40),
                Icon(icon, size: 56, color: iconColor),
                SizedBox(height: 16),
                Text(
                  heading,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    color: _headingColor,
                  ),
                ),
                SizedBox(height: 12),
                Text(
                  body,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 16,
                    color: _secondaryTextColor,
                  ),
                ),
                if (hint != null) ...[
                  SizedBox(height: 8),
                  Text(
                    hint,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: _secondaryTextColor,
                    ),
                  ),
                ],
                SizedBox(height: 24),
                for (final a in actions) Center(child: a),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ---- Per-phase views -------------------------------------------------------

  Widget _buildNeverPairedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset(
            'assets/images/icon.png',
            width: 80,
            height: 80,
          ),
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
            style: TextStyle(
              fontSize: 16,
              color: _secondaryTextColor,
            ),
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

  // Probing / connecting: just the toy card with an inline spinner — nothing
  // full-screen, nothing blocking.
  Widget _buildBusyView(ToyPhase phase) {
    return RefreshIndicator(
      onRefresh: _bleManager.watchSavedToy,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          _buildToyCard(
            subtitle: toyStatusLine(_bleManager),
            busy: true,
          ),
        ],
      ),
    );
  }

  Widget _buildBluetoothOffView() {
    final bool isIOS = Platform.isIOS;
    return _buildMessageView(
      icon: Icons.bluetooth_disabled,
      iconColor: Colors.blue.shade400,
      heading: 'Bluetooth is off',
      body: 'Turn on Bluetooth on your phone to reach Smarty',
      hint: isIOS
          ? 'Swipe down from the top-right corner and tap the Bluetooth icon.'
          : null,
      toyCardSubtitle: 'Bluetooth is off on this phone',
      actions: [
        _buildPrimaryButton(
          label: isIOS ? 'Open Settings' : 'Turn on',
          icon: isIOS ? Icons.settings : Icons.bluetooth,
          onPressed: _turnOnBluetooth,
        ),
      ],
    );
  }

  Widget _buildNeedsPermissionView() {
    return _buildMessageView(
      icon: Icons.bluetooth_searching,
      iconColor: Colors.blue.shade400,
      heading: 'Allow Bluetooth',
      body: 'Allow Bluetooth so the app can talk to Smarty',
      hint: 'In Settings, turn on Bluetooth for this app, then come back.',
      toyCardSubtitle: 'Bluetooth permission needed',
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
  // background connect is already waiting, so no action is required.
  Widget _buildNotNearbyView() {
    return _buildMessageView(
      icon: Icons.bedtime_outlined,
      iconColor: Colors.indigo.shade300,
      heading: 'Smarty is asleep or out of reach',
      body: "Turn it on — it'll connect by itself.",
      toyCardSubtitle: 'Asleep or out of reach',
      actions: [
        _buildPrimaryButton(
          label: 'Check again',
          icon: Icons.refresh,
          onPressed: () => unawaited(_bleManager.watchSavedToy()),
        ),
        SizedBox(height: 12),
        _buildTextAction('Set up a different Smarty', _openConnectionPage),
      ],
    );
  }

  Widget _buildPairingBrokenView() {
    final bool isIOS = Platform.isIOS;
    return _buildMessageView(
      icon: Icons.link_off,
      iconColor: Colors.orange.shade400,
      heading: 'Your phone remembers an old connection to Smarty.',
      body: pairingBrokenSteps(isIOS: isIOS),
      toyCardSubtitle: 'Needs reconnecting',
      actions: [
        // Opens setup, not just another quick look: after the button hold
        // the toy only waits 30 seconds, and the setup page keeps looking
        // (with the same instructions) for as long as it's open.
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
    final bool needsLinkStep = DevConfig.linkingEnabled &&
        !_waitingForStatus &&
        _bleManager.registered == false;

    return RefreshIndicator(
      onRefresh: _refreshStatus,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildToyCard(
              subtitle: toyStatusLine(
                _bleManager,
                statusStalled: _wifiStatusStalled,
              ),
              busy: _waitingForStatus && !_wifiStatusStalled,
            ),
            if (needsLinkStep) ...[
              SizedBox(height: 16),
              Center(
                child: _buildPrimaryButton(
                  label: 'Finish setup',
                  icon: Icons.check_circle_outline,
                  onPressed: _openConnectionPage,
                ),
              ),
            ],
            SizedBox(height: 20),
            _buildWifiStatusCard(),
            // NOTE: battery status card intentionally omitted — the device has no
            // battery sensing yet (firmware returns a fixed placeholder), so showing
            // a precise "%" would mislead parents (APP-7 / FW-21). Restore this card
            // once real battery telemetry exists.
          ],
        ),
      ),
    );
  }

  // States: couldn't-check (stalled, offers retry), still-loading, joining,
  // connected, and not-on-Wi-Fi (offers a setup shortcut).
  Widget _buildWifiStatusCard() {
    final String wifi = _bleManager.connectedWifi.trim();

    if (_wifiStatusStalled) {
      return _buildStatusCard(
        icon: Icons.wifi_find,
        color: Colors.orange,
        title: "Couldn't check Wi-Fi",
        isLoading: false,
        trailing: IconButton(
          icon: Icon(Icons.refresh, color: Colors.orange.shade700),
          tooltip: 'Refresh',
          onPressed: () {
            setState(() {
              _wifiStatusStalled = false; // show the spinner again while we retry
            });
            _refreshStatus();
          },
        ),
      );
    }

    if (_waitingForStatus) {
      return _buildStatusCard(
        icon: null,
        color: Colors.orange,
        title: 'Checking Wi-Fi…',
        isLoading: true,
      );
    }

    if (wifi == 'Initializing' || wifi == 'Reconnecting') {
      return _buildStatusCard(
        icon: null,
        color: Colors.blue,
        title: 'Joining Wi-Fi…',
        isLoading: true,
      );
    }

    if (_bleManager.isWifiConnected) {
      return _buildStatusCard(
        icon: Icons.wifi,
        color: Colors.green,
        title: 'Wi-Fi: $wifi',
        isLoading: false,
      );
    }

    return _buildStatusCard(
      icon: Icons.wifi_off,
      color: Colors.orange,
      title: wifi == 'Auth Failed'
          ? 'Wi-Fi password may have changed'
          : 'Wi-Fi: Not connected',
      isLoading: false,
      trailing: TextButton(
        onPressed: _openWifiSetup,
        child: Text(
          'Set up',
          style: TextStyle(
            color: Colors.orange.shade700,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard({
    IconData? icon,
    required Color color,
    required String title,
    required bool isLoading,
    Widget? trailing,
  }) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).brightness == Brightness.dark
                ? Colors.black26
                : Colors.grey.shade200,
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          isLoading
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                )
              : Icon(icon, color: color, size: 20),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: _headingColor,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
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
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7),
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
                    ? CustomPaint(
                        painter: ConfettiPainter(progress: value),
                      )
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
      final y = size.height * (0.3 + 0.7 * progress) - p.fall * size.height * progress;
      paint.color = p.color;
      canvas.drawCircle(Offset(x, y), p.size / 2, paint);
    }
  }

  @override
  bool shouldRepaint(ConfettiPainter oldDelegate) => oldDelegate.progress != progress;
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

  const AnimatedScaleButton({required this.onPressed, required this.child, super.key});

  @override
  State<AnimatedScaleButton> createState() => _AnimatedScaleButtonState();
}

class _AnimatedScaleButtonState extends State<AnimatedScaleButton> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 100),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
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
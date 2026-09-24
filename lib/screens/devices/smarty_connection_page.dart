import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';

import '../../dev_config.dart';
import '../../services/ble_manager.dart';
import '../../services/ble_service.dart';
import '../../services/device_registration_service.dart';
import '../wifi/wifi_network_page.dart';
import 'device_registration_page.dart';
import 'setup_steps.dart';

/// "Set up Smarty": adds a new toy (or re-pairs one). Reconnecting a toy that
/// is already set up is Home's job (BleManager.watchSavedToy), not this page's.
///
/// Flow: instructions → live look for toys → the parent taps their toy →
/// connect (the phone asks to pair) → link to the account → Wi-Fi → done.
/// Never connects to a toy the parent didn't tap (see [_onScanResults]).
///
/// Pops `true` when the toy ends up linked and on Wi-Fi (Home celebrates);
/// pops with no result when the parent leaves early ("Later", back button).
class SmartyConnectionPage extends StatefulWidget {
  const SmartyConnectionPage({super.key});

  @override
  SmartyConnectionPageState createState() => SmartyConnectionPageState();
}

enum _Stage {
  /// Looking for toys; results render as tappable tiles as they arrive.
  scanning,

  /// connectAndInitialize in flight (the phone's pairing prompt shows here).
  connecting,

  /// Connect failed; see [SmartyConnectionPageState._failure].
  failed,

  /// The link dropped after connecting.
  lost,

  /// Checking / doing the account link.
  linking,

  /// Waiting (briefly) for the toy's first Wi-Fi status.
  checkingWifi,

  /// The toy is joining Wi-Fi by itself.
  wifiJoining,

  /// The toy needs the parent to set up Wi-Fi.
  wifiNeeded,

  /// All set — popping back to Home.
  done,

  /// The account link said this toy belongs to another account; the toy has
  /// been forgotten and setup ends here.
  ownedElsewhere,
}

const Set<_Stage> _afterConnectStages = {
  _Stage.linking,
  _Stage.checkingWifi,
  _Stage.wifiJoining,
  _Stage.wifiNeeded,
};

class SmartyConnectionPageState extends State<SmartyConnectionPage> {
  final BleManager _ble = BleManager();

  /// Upper bound for the toy's first Wi-Fi status after connecting.
  static const Duration _firstStatusWait = Duration(seconds: 5);

  /// How long "Smarty is joining Wi-Fi…" may last before we offer setup.
  static const Duration _joiningWait = Duration(seconds: 15);

  /// Restart the look if the scan stopped under us (checked this often).
  static const Duration _scanWatchdog = Duration(seconds: 10);

  /// Toys drop off the list after going quiet this long (e.g. the 30-second
  /// wait ended).
  static const Duration _removeIfGone = Duration(seconds: 8);

  _Stage _stage = _Stage.scanning;

  // ---- Looking ---------------------------------------------------------------
  final List<ScanResult> _found = [];
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  BluetoothAdapterState _adapter = FlutterBluePlus.adapterStateNow;
  DateTime _lookingSince = DateTime.now();
  DateTime _lastScanStart = DateTime.fromMillisecondsSinceEpoch(0);
  ScanHint _hint = ScanHint.none;
  bool _scanError = false;
  // bluetoothOff / needsPermission learned from a failed scan or connect.
  ToyPhase? _blockerFromError;
  Timer? _tick;

  // ---- Connecting ------------------------------------------------------------
  // Guards against double taps (tiles are also disabled while this is set).
  bool _connecting = false;
  BluetoothDevice? _target;
  String? _targetName;
  ConnectFailure? _failure;
  // The toy this page connected (or found connected) — used to resume after
  // a drop if BleManager's background reconnect brings it back.
  BluetoothDevice? _ourToy;

  // ---- After connect ---------------------------------------------------------
  // Bumped whenever the flow is abandoned (link lost / restarted); async
  // steps started under an older value stop quietly.
  int _flowGen = 0;
  bool _linkSkipped = false;
  bool _linkDone = false;
  bool _wifiPageOpen = false;
  StreamSubscription<String>? _wifiSub;
  Timer? _joiningTimer;

  @override
  void initState() {
    super.initState();
    _ble.phase.addListener(_onPhaseChanged);
    _adapterSub = FlutterBluePlus.adapterState.listen(
      _onAdapterChanged,
      onError: (Object e) => debugPrint('SmartyConnectionPage: adapter stream: $e'),
    );
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());

    final connected = _ble.connectedDevice;
    if (_ble.phase.value == ToyPhase.connected && connected != null) {
      // Opened from "Finish setup": the toy is already here — go straight to
      // the account link instead of looking for it (it isn't advertising).
      _ourToy = connected;
      _stage = _Stage.linking;
      WidgetsBinding.instance.addPostFrameCallback((_) => _runAfterConnect());
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startScan());
    }
  }

  @override
  void dispose() {
    _ble.phase.removeListener(_onPhaseChanged);
    _adapterSub?.cancel();
    _tick?.cancel();
    _wifiSub?.cancel();
    _joiningTimer?.cancel();
    _flowGen++;
    unawaited(_stopScan());
    super.dispose();
  }

  // Close THIS page — not whatever happens to be on top (a plain pop() from an
  // async flow could close a sub-page instead).
  void _closeThisPage([bool? result]) {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    if (!route.isCurrent) {
      navigator.popUntil((r) => r == route);
    }
    navigator.pop(result);
  }

  // ===========================================================================
  // Bluetooth adapter / phase
  // ===========================================================================

  /// Bluetooth problem to show instead of the look, if any. The adapter wins;
  /// [BleManager.phase] only reports these while a toy is saved, so it's the
  /// fallback.
  ToyPhase? get _blocker {
    switch (_adapter) {
      case BluetoothAdapterState.off:
      case BluetoothAdapterState.turningOff:
      case BluetoothAdapterState.unavailable:
        return ToyPhase.bluetoothOff;
      case BluetoothAdapterState.unauthorized:
        return ToyPhase.needsPermission;
      default:
        break;
    }
    if (_blockerFromError != null) return _blockerFromError;
    final p = _ble.phase.value;
    if ((p == ToyPhase.bluetoothOff || p == ToyPhase.needsPermission) &&
        _adapter != BluetoothAdapterState.on) {
      return p;
    }
    return null;
  }

  void _onAdapterChanged(BluetoothAdapterState state) {
    if (!mounted) return;
    final bool wasOn = _adapter == BluetoothAdapterState.on;
    setState(() {
      _adapter = state;
      if (state == BluetoothAdapterState.on) _blockerFromError = null;
    });
    if (state == BluetoothAdapterState.on) {
      if (!wasOn && _stage == _Stage.scanning) {
        _lookingSince = DateTime.now();
        _startScan();
      }
    } else if (state != BluetoothAdapterState.unknown &&
        state != BluetoothAdapterState.turningOn) {
      unawaited(_stopScan());
    }
  }

  void _onPhaseChanged() {
    if (!mounted) return;
    // Setup is over (the toy was forgotten on purpose) — nothing to follow.
    if (_stage == _Stage.ownedElsewhere) return;
    final phase = _ble.phase.value;
    if (_afterConnectStages.contains(_stage) && phase != ToyPhase.connected) {
      _onLinkLost();
      return;
    }
    if (_stage == _Stage.lost ||
        _stage == _Stage.scanning ||
        _stage == _Stage.failed) {
      _maybeResume();
    }
    // Bluetooth-off / permission may have changed.
    setState(() {});
  }

  void _onLinkLost() {
    debugPrint('SmartyConnectionPage: link lost mid-setup');
    _flowGen++;
    _wifiSub?.cancel();
    _wifiSub = null;
    _joiningTimer?.cancel();
    setState(() => _stage = _Stage.lost);
  }

  /// The toy BleManager has connected, if setup should carry on with it:
  /// the toy we set up or tried to connect, or — while we're still looking
  /// (or after a failed attempt) with no toy picked yet — whatever toy
  /// BleManager connected by itself (e.g. its background reconnect). A
  /// connected toy stops advertising, so the look would never find it.
  BluetoothDevice? _resumableToy() {
    if (_connecting || _ble.phase.value != ToyPhase.connected) return null;
    final device = _ble.connectedDevice;
    if (device == null) return null;
    final id = device.remoteId;
    if (_ourToy?.remoteId == id || _target?.remoteId == id) return device;
    if (_ourToy == null &&
        _target == null &&
        (_stage == _Stage.scanning || _stage == _Stage.failed)) {
      return device;
    }
    return null;
  }

  /// BleManager (re)connects the toy by itself — after a drop, or its
  /// background connect after a failed attempt. If it's up and we're on
  /// screen, carry on from where setup stopped.
  void _maybeResume() {
    if (!mounted) return;
    if (_stage != _Stage.lost &&
        _stage != _Stage.scanning &&
        _stage != _Stage.failed) {
      return;
    }
    final device = _resumableToy();
    if (device == null) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    _ourToy = device;
    unawaited(_stopScan());
    _runAfterConnect();
  }

  // ===========================================================================
  // Looking for toys
  // ===========================================================================

  /// "Look again" / "Try again": fresh list, fresh hint timer, fresh scan.
  void _lookAgain() {
    final device = _resumableToy();
    if (device != null) {
      // Still (or again) connected to the toy we set up — no need to look.
      _ourToy = device;
      _runAfterConnect();
      return;
    }
    setState(() {
      _stage = _Stage.scanning;
      _found.clear();
      _failure = null;
      _scanError = false;
      _blockerFromError = null;
      _target = null;
      _targetName = null;
      _hint = ScanHint.none;
      _lookingSince = DateTime.now();
    });
    _startScan(restart: true);
  }

  Future<void> _startScan({bool restart = false}) async {
    if (!mounted || _stage != _Stage.scanning) return;
    // Not on yet (or unknown on a cold start): the adapter listener starts us.
    if (_adapter != BluetoothAdapterState.on) return;
    if (!restart && _scanSub != null && FlutterBluePlus.isScanningNow) return;

    await _scanSub?.cancel();
    _scanSub = null;
    if (!mounted || _stage != _Stage.scanning) return;

    _lastScanStart = DateTime.now();
    // Subscribe before starting so no early advert is missed.
    final sub = FlutterBluePlus.onScanResults.listen(
      _onScanResults,
      onError: (Object e) => debugPrint('SmartyConnectionPage: scan stream: $e'),
    );
    _scanSub = sub;
    // FBP has one scan: take it over from Home's launch/resume probe so that
    // probe neither eats our results nor stops our scan when it times out.
    _ble.cancelProbe();
    try {
      // No timeout: keep looking while the page is open. continuousUpdates +
      // removeIfGone let a toy whose 30-second wait ended drop off the list.
      await FlutterBluePlus.startScan(
        withServices: [BleManager.smartyServiceGuid],
        continuousUpdates: true,
        removeIfGone: _removeIfGone,
      );
      if (mounted && _scanError) setState(() => _scanError = false);
    } catch (e) {
      debugPrint('SmartyConnectionPage: startScan failed: $e');
      if (_scanSub == sub) {
        await sub.cancel();
        _scanSub = null;
      }
      if (!mounted) return;
      final kind = BleManager.classifyConnectError(e);
      setState(() {
        if (kind == ConnectFailure.needsPermission) {
          _blockerFromError = ToyPhase.needsPermission;
        } else if (kind == ConnectFailure.bluetoothOff) {
          _blockerFromError = ToyPhase.bluetoothOff;
        } else {
          _scanError = true;
        }
      });
    }
  }

  Future<void> _stopScan() async {
    final sub = _scanSub;
    _scanSub = null;
    if (sub == null) return;
    await sub.cancel();
    try {
      await FlutterBluePlus.stopScan();
    } catch (e) {
      debugPrint('SmartyConnectionPage: stopScan failed: $e');
    }
  }

  static String _nameOf(ScanResult r) {
    final adv = r.advertisementData.advName;
    return adv.isNotEmpty ? adv : r.device.platformName;
  }

  // Results only ever become tiles; nothing connects until the parent taps
  // one. No auto-select, not even for a lone toy: a toy bonded to ANOTHER
  // phone advertises exactly like one waiting in pairing mode (the advert
  // carries no pairing-mode marker, and the firmware accepts pairing from any
  // phone), so connecting by ourselves could pair the neighbour's Smarty.
  // Auto-select needs a pairing-mode flag in the firmware's advert first.
  void _onScanResults(List<ScanResult> results) {
    if (!mounted) return;
    if (_stage != _Stage.scanning) return;

    String keyOf(ScanResult r) => '${r.device.remoteId.str}|${_nameOf(r)}';
    bool changed = results.length != _found.length;
    for (int i = 0; !changed && i < results.length; i++) {
      changed = keyOf(results[i]) != keyOf(_found[i]);
    }
    if (!changed) {
      // Same toys, fresher adverts — no rebuild needed.
      _found
        ..clear()
        ..addAll(results);
      return;
    }

    setState(() {
      _found
        ..clear()
        ..addAll(results);
      if (_found.isNotEmpty) _hint = ScanHint.none;
    });
  }

  void _onTick() {
    if (!mounted || _stage != _Stage.scanning) return;
    final now = DateTime.now();
    final hint =
        scanHintFor(now.difference(_lookingSince), anyFound: _found.isNotEmpty);
    if (hint != _hint) setState(() => _hint = hint);

    // Watchdog: another screen's scan (or the OS) may have stopped ours.
    if (_blocker == null &&
        _adapter == BluetoothAdapterState.on &&
        !FlutterBluePlus.isScanningNow &&
        now.difference(_lastScanStart) >= _scanWatchdog) {
      _startScan(restart: true);
    }
  }

  // ===========================================================================
  // Connecting
  // ===========================================================================

  Future<void> _connect(BluetoothDevice device, String name) async {
    if (_connecting) return;
    _connecting = true;
    setState(() {
      _stage = _Stage.connecting;
      _target = device;
      _targetName = name;
      _failure = null;
    });
    await _stopScan();

    try {
      await _ble.connectAndInitialize(device);
    } on ConnectException catch (e) {
      _connecting = false;
      debugPrint('SmartyConnectionPage: connect failed (${e.kind.name}): ${e.cause}');
      if (!mounted) return;
      if (e.kind == ConnectFailure.bluetoothOff ||
          e.kind == ConnectFailure.needsPermission) {
        // Shown as the Bluetooth state; the look restarts once it's fixed.
        setState(() {
          _blockerFromError = e.kind == ConnectFailure.bluetoothOff
              ? ToyPhase.bluetoothOff
              : ToyPhase.needsPermission;
          _stage = _Stage.scanning;
          _found.clear();
          _lookingSince = DateTime.now();
        });
        return;
      }
      setState(() {
        _stage = _Stage.failed;
        _failure = e.kind;
      });
      return;
    } catch (e) {
      _connecting = false;
      debugPrint('SmartyConnectionPage: connect failed (unexpected): $e');
      if (!mounted) return;
      setState(() {
        _stage = _Stage.failed;
        _failure = ConnectFailure.unknown;
      });
      return;
    }

    _connecting = false;
    _ourToy = device;
    if (!mounted) return;
    _runAfterConnect();
  }

  // ===========================================================================
  // After connect: link → Wi-Fi → done
  // ===========================================================================

  Future<void> _runAfterConnect() async {
    if (!mounted) return;
    final int gen = ++_flowGen;
    _wifiSub?.cancel();
    _wifiSub = null;
    _joiningTimer?.cancel();
    setState(() => _stage = _Stage.linking);

    if (!await _linkStep(gen)) return;
    await _wifiStep(gen);
  }

  bool _stale(int gen) => !mounted || gen != _flowGen;

  /// Returns false if the flow was abandoned meanwhile.
  Future<bool> _linkStep(int gen) async {
    if (_linkDone || _linkSkipped) return true;
    if (!DevConfig.linkingEnabled) {
      // Dev build without the account link: treat the toy as linked so setup
      // finishes and Home celebrates. The step row is hidden in _buildProgress.
      _linkDone = true;
      return true;
    }

    // The toy's own report, or — for firmware that can't report it —
    // BleManager's local record keyed by the toy's id. null = can't tell:
    // show the link step rather than silently skipping it.
    final bool? registered = await _ble.refreshRegistered();
    if (_stale(gen) || !mounted) return false;
    if (registered == true) {
      setState(() => _linkDone = true);
      return true;
    }

    final LinkResult? result = await Navigator.push<LinkResult>(
      context,
      MaterialPageRoute(builder: (_) => const DeviceRegistrationPage()),
    );
    if (result == LinkResult.ownedElsewhere) {
      // Someone else's Smarty: stop here, whatever happened to the link.
      await _abortOwnedElsewhere();
      return false;
    }
    // Record the outcome even if the link dropped meanwhile — the account
    // side is done either way, so a resumed flow must not ask again.
    if (result == LinkResult.linked) {
      _ble.markRegistered();
      _linkDone = true;
    } else {
      // "Not now" / back: carry on with Wi-Fi; Home keeps offering
      // "Finish setup".
      _linkSkipped = true;
    }
    if (_stale(gen)) {
      // The link dropped while the account page was on top (so _maybeResume
      // bailed then). If BleManager has reconnected since, carry on now.
      _maybeResume();
      return false;
    }
    setState(() {});
    if (_ble.phase.value != ToyPhase.connected) {
      _onLinkLost();
      return false;
    }
    return true;
  }

  /// The account link found this toy linked to another account: forget it
  /// (drops the link, clears it as this account's toy — Home then offers
  /// setup) and end setup with an explanation.
  Future<void> _abortOwnedElsewhere() async {
    _flowGen++;
    _wifiSub?.cancel();
    _wifiSub = null;
    _joiningTimer?.cancel();
    // Stage first: forgetToy() moves the phase, which must not read as
    // "lost touch".
    if (mounted) {
      setState(() => _stage = _Stage.ownedElsewhere);
    } else {
      _stage = _Stage.ownedElsewhere;
    }
    await _ble.forgetToy();
    _ourToy = null;
    _target = null;
  }

  Future<void> _wifiStep(int gen) async {
    setState(() => _stage = _Stage.checkingWifi);

    WifiStep step = wifiStepFor(_ble.connectedWifi);
    if (step == WifiStep.unknown) {
      // Wait for the toy's first status (bounded), not a fixed poll.
      step = await _waitForFirstWifiStatus();
      if (_stale(gen)) return;
    }

    // Keep following the toy's status while we're on the Wi-Fi step: it may
    // finish joining by itself, or report a failure.
    _wifiSub?.cancel();
    _wifiSub = _ble.wifiStatusStream.listen((status) {
      if (_stale(gen) || _ble.phase.value != ToyPhase.connected) return;
      if (_stage == _Stage.done || _wifiPageOpen) return;
      _applyWifiStep(wifiStepFor(status), gen);
    });
    _applyWifiStep(step, gen);
  }

  Future<WifiStep> _waitForFirstWifiStatus() async {
    final done = Completer<WifiStep>();
    final sub = _ble.wifiStatusStream.listen((status) {
      final s = wifiStepFor(status);
      if (s != WifiStep.unknown && !done.isCompleted) done.complete(s);
    });
    // The read initialize() fired may have come back empty; ask again.
    unawaited(_ble.readStatusUpdate());
    try {
      return await done.future.timeout(
        _firstStatusWait,
        onTimeout: () => wifiStepFor(_ble.connectedWifi),
      );
    } finally {
      await sub.cancel();
    }
  }

  void _applyWifiStep(WifiStep step, int gen) {
    if (_stale(gen)) return;
    switch (step) {
      case WifiStep.connected:
        _finish(gen);
        return;
      case WifiStep.joining:
        if (_stage == _Stage.wifiJoining) return;
        setState(() => _stage = _Stage.wifiJoining);
        _joiningTimer?.cancel();
        _joiningTimer = Timer(_joiningWait, () {
          if (_stale(gen) || _stage != _Stage.wifiJoining) return;
          // Still joining after a while: re-evaluate, and offer setup if the
          // toy hasn't made it.
          final now = wifiStepFor(_ble.connectedWifi);
          if (now == WifiStep.connected) {
            _finish(gen);
          } else {
            setState(() => _stage = _Stage.wifiNeeded);
          }
        });
        return;
      case WifiStep.needsSetup:
      case WifiStep.unknown:
        _joiningTimer?.cancel();
        if (_stage != _Stage.wifiNeeded) {
          setState(() => _stage = _Stage.wifiNeeded);
        }
        return;
    }
  }

  Future<void> _openWifiSetup() async {
    if (_wifiPageOpen) return;
    final int gen = _flowGen;
    _wifiPageOpen = true;
    final bool? joined;
    try {
      // WifiNetworkPage pops `true` once the toy has actually joined.
      joined = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => const WifiNetworkPage()),
      );
    } finally {
      _wifiPageOpen = false;
    }
    if (_stale(gen)) {
      _maybeResume();
      return;
    }
    if (joined == true) {
      _finish(gen);
      return;
    }
    _applyWifiStep(wifiStepFor(_ble.connectedWifi), gen);
  }

  void _finish(int gen) {
    if (_stale(gen) || _stage == _Stage.done) return;
    _wifiSub?.cancel();
    _wifiSub = null;
    _joiningTimer?.cancel();
    setState(() => _stage = _Stage.done);
    // `true` tells Home to celebrate — only when Smarty can actually talk
    // (linked). An unlinked toy lands on Home's "Finish setup" instead.
    _closeThisPage(_linkSkipped ? null : true);
  }

  // ===========================================================================
  // UI
  // ===========================================================================

  Color get _headingColor => Theme.of(context).colorScheme.onSurface;
  Color get _secondaryTextColor =>
      Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Set up Smarty',
          style: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        elevation: 2,
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _buildBody(),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildBody() {
    switch (_stage) {
      case _Stage.ownedElsewhere:
        return [
          _buildMessage(
            icon: Icons.lock_outline,
            iconColor: Colors.orange.shade400,
            heading: 'This Smarty belongs to another account',
            text: RegistrationFailure.alreadyOwned.message,
            actions: [
              _primaryButton('OK', Icons.check, () => _closeThisPage()),
            ],
          ),
        ];
      case _Stage.scanning:
      case _Stage.connecting:
      case _Stage.failed:
        final blocker = _blocker;
        return [
          if (_stage != _Stage.connecting) ...[
            _buildInstructionsCard(),
            const SizedBox(height: 24),
          ],
          if (blocker != null && _stage != _Stage.connecting) ...[
            _buildBlocker(blocker),
            // Granting permission in Settings doesn't always change the
            // adapter state, so offer a manual restart once it's on.
            if (_adapter == BluetoothAdapterState.on)
              Center(
                child: TextButton.icon(
                  onPressed: _lookAgain,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Look again'),
                ),
              ),
          ]
          else if (_stage == _Stage.failed)
            _buildFailure()
          else
            ..._buildLookSection(),
        ];
      case _Stage.lost:
        final blocker = _blocker;
        return [
          if (blocker != null)
            _buildBlocker(blocker)
          else
            _buildMessage(
              icon: Icons.bluetooth_searching,
              iconColor: Colors.orange.shade400,
              text: 'Lost touch with Smarty — keep it close to your phone',
              actions: [
                _primaryButton('Try again', Icons.refresh, _lookAgain),
              ],
            ),
        ];
      case _Stage.linking:
      case _Stage.checkingWifi:
      case _Stage.wifiJoining:
      case _Stage.wifiNeeded:
      case _Stage.done:
        return [
          _buildProgress(),
          if (_stage == _Stage.wifiNeeded) ...[
            const SizedBox(height: 24),
            _buildWifiPrompt(),
          ],
          if (_stage == _Stage.done) ...[
            const SizedBox(height: 32),
            Icon(Icons.check_circle, color: Colors.green.shade600, size: 64),
            const SizedBox(height: 12),
            Text(
              'All set!',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w600,
                color: Colors.green.shade700,
              ),
            ),
          ],
        ];
    }
  }

  Widget _buildInstructionsCard() {
    final bool emphasise = _stage == _Stage.scanning &&
        _hint == ScanHint.stoppedWaiting &&
        _blocker == null;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: emphasise ? Colors.orange.shade50 : Colors.blue.shade50,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: emphasise ? Colors.orange.shade300 : Colors.transparent,
          width: 2,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: emphasise ? Colors.orange.shade100 : Colors.blue.shade100,
              shape: BoxShape.circle,
            ),
            child: Image.asset('assets/images/icon.png', width: 24, height: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Get Smarty ready',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: emphasise
                        ? Colors.orange.shade900
                        : Colors.blue.shade900,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Turn Smarty on, then hold the + and – buttons together for '
                  '3 seconds. Smarty will wait 30 seconds for your phone.',
                  style: TextStyle(
                    fontSize: 16,
                    height: 1.35,
                    color: emphasise
                        ? Colors.orange.shade800
                        : Colors.blue.shade800,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _inlineSpinner() => SizedBox(
        width: 16,
        height: 16,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: Colors.blue.shade600,
        ),
      );

  Widget _sectionHeader(String text, {Widget? leading}) {
    return Row(
      children: [
        if (leading != null) ...[leading, const SizedBox(width: 10)],
        Expanded(
          child: Text(
            text,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: _headingColor,
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildLookSection() {
    final List<Widget> out = [];
    final bool connecting = _stage == _Stage.connecting;

    // Every toy seen so far is a tile (kept, dimmed, while connecting); the
    // one being connected is always shown.
    final List<(BluetoothDevice, String?)> tiles = [
      for (final r in _found) (r.device, _nameOf(r)),
    ];
    final target = _target;
    if (connecting &&
        target != null &&
        !tiles.any((t) => t.$1.remoteId == target.remoteId)) {
      tiles.insert(0, (target, _targetName));
    }

    if (connecting) {
      out.add(_sectionHeader('Connecting to Smarty…', leading: _inlineSpinner()));
    } else if (tiles.isEmpty) {
      out.add(_sectionHeader('Looking for Smarty…', leading: _inlineSpinner()));
    } else if (tiles.length == 1) {
      out.add(_sectionHeader(
        'Smarty found!',
        leading: Icon(Icons.check_circle, color: Colors.green.shade600, size: 20),
      ));
    } else {
      out
        ..add(_sectionHeader('Smarty toys nearby'))
        ..add(const SizedBox(height: 4))
        ..add(Text(
          'Tap the one you are setting up.',
          style: TextStyle(fontSize: 15, color: _secondaryTextColor),
        ));
    }

    if (tiles.isNotEmpty) {
      out.add(const SizedBox(height: 16));
      for (final t in tiles) {
        // A lone toy gets a clear "Tap to connect" — the parent still taps.
        out.add(_toyTile(t.$1, t.$2,
            highlight: !connecting && tiles.length == 1));
      }
      out
        ..add(const SizedBox(height: 16))
        ..add(Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 20, color: Colors.blue.shade600),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                'Your phone will ask to pair with Smarty — tap Pair.',
                style: TextStyle(fontSize: 15, color: _headingColor),
              ),
            ),
          ],
        ));
    }

    if (_stage == _Stage.scanning) {
      final String? hintText = _scanError
          ? 'Something got in the way while looking for Smarty. Tap Look again.'
          : switch (_hint) {
              ScanHint.none => null,
              ScanHint.stillLooking =>
                'Still looking — did you hold both buttons?',
              ScanHint.stoppedWaiting =>
                'Smarty stopped waiting. Hold the + and – buttons again.',
            };
      if (hintText != null) {
        out
          ..add(const SizedBox(height: 20))
          ..add(Text(
            hintText,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 15,
              color: _hint == ScanHint.stoppedWaiting || _scanError
                  ? Colors.orange.shade800
                  : _secondaryTextColor,
            ),
          ))
          ..add(const SizedBox(height: 8))
          ..add(Center(
            child: TextButton.icon(
              onPressed: _lookAgain,
              icon: const Icon(Icons.refresh),
              label: const Text('Look again'),
            ),
          ));
      }
    }
    return out;
  }

  Widget _toyTile(BluetoothDevice device, String? rawName,
      {bool highlight = false}) {
    final bool isTarget =
        _target != null && _target!.remoteId == device.remoteId;
    final bool busy = _connecting || _stage != _Stage.scanning;
    final String? code = BleManager.toyCode(rawName);
    // "Your Smarty" only for this account's own toy with a working pairing.
    // While its pairing is broken the parent is re-pairing it, and anything
    // else is just "Smarty" + its code (it could be a neighbour's).
    final bool isYours = device.remoteId.str == _ble.savedToyId &&
        _ble.phase.value != ToyPhase.pairingBroken;
    final String title =
        isYours ? 'Your Smarty' : BleManager.toyDisplayName(rawName);
    final Color accent = Colors.blue.shade600;
    return Card(
      elevation: highlight ? 3 : 1,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: highlight
            ? BorderSide(color: accent, width: 2)
            : BorderSide.none,
      ),
      child: ListTile(
        enabled: !busy || isTarget,
        leading: Image.asset('assets/images/icon.png', width: 28, height: 28),
        title: Text(
          title,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: code != null ? Text(code) : null,
        trailing: isTarget && _stage == _Stage.connecting
            ? _inlineSpinner()
            : highlight
                ? Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: accent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: const Text(
                      'Tap to connect',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  )
                : Icon(Icons.chevron_right,
                    color: busy ? Colors.grey : accent),
        onTap: busy ? null : () => _connect(device, rawName ?? ''),
      ),
    );
  }

  Widget _buildFailure() {
    final kind = _failure ?? ConnectFailure.unknown;
    final bool isIOS = Platform.isIOS;
    return _buildMessage(
      icon: kind == ConnectFailure.pairingBroken
          ? Icons.link_off
          : Icons.error_outline,
      iconColor: Colors.orange.shade400,
      text: connectFailureMessage(kind, isIOS: isIOS),
      actions: [
        _primaryButton('Try again', Icons.refresh, _lookAgain),
        if (kind == ConnectFailure.pairingBroken && isIOS) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => unawaited(BleService.openBluetoothSettings()),
            child: const Text('Open Settings'),
          ),
        ],
      ],
    );
  }

  // Same copy as Home's Bluetooth views.
  Widget _buildBlocker(ToyPhase blocker) {
    final bool isIOS = Platform.isIOS;
    if (blocker == ToyPhase.needsPermission) {
      return _buildMessage(
        icon: Icons.bluetooth_searching,
        iconColor: Colors.blue.shade400,
        heading: 'Allow Bluetooth',
        text: 'Allow Bluetooth so the app can talk to Smarty',
        hint: 'In Settings, turn on Bluetooth for this app, then come back.',
        actions: [
          _primaryButton(
            'Open Settings',
            Icons.settings,
            () => unawaited(BleService.openAppPermissionSettings()),
          ),
        ],
      );
    }
    return _buildMessage(
      icon: Icons.bluetooth_disabled,
      iconColor: Colors.blue.shade400,
      heading: 'Bluetooth is off',
      text: 'Turn on Bluetooth on your phone to reach Smarty',
      hint: isIOS
          ? 'Swipe down from the top-right corner and tap the Bluetooth icon.'
          : null,
      actions: [
        _primaryButton(
          isIOS ? 'Open Settings' : 'Turn on',
          isIOS ? Icons.settings : Icons.bluetooth,
          () => unawaited(_ble.requestBluetoothOn()),
        ),
      ],
    );
  }

  Widget _buildMessage({
    required IconData icon,
    required Color iconColor,
    String? heading,
    required String text,
    String? hint,
    required List<Widget> actions,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(icon, size: 48, color: iconColor),
        const SizedBox(height: 12),
        if (heading != null) ...[
          Text(
            heading,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              color: _headingColor,
            ),
          ),
          const SizedBox(height: 8),
        ],
        Text(
          text,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 16,
            color: heading != null ? _secondaryTextColor : _headingColor,
          ),
        ),
        if (hint != null) ...[
          const SizedBox(height: 8),
          Text(
            hint,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _secondaryTextColor),
          ),
        ],
        const SizedBox(height: 20),
        for (final a in actions) Center(child: a),
      ],
    );
  }

  Widget _primaryButton(String label, IconData icon, VoidCallback? onPressed) {
    return ElevatedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label, style: const TextStyle(fontSize: 16)),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.blue.shade600,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  // ---- Post-connect progress ------------------------------------------------

  Widget _buildProgress() {
    final bool linking = _stage == _Stage.linking;
    final bool wifiActive = _stage == _Stage.checkingWifi ||
        _stage == _Stage.wifiJoining;

    final _StepState linkState = linking
        ? _StepState.active
        : _linkSkipped
            ? _StepState.skipped
            : _StepState.done;
    final String linkLabel = switch (linkState) {
      _StepState.active => 'Linking to your account…',
      _StepState.skipped => 'Not linked yet — finish from Home',
      _ => 'Linked to your account',
    };

    final _StepState wifiState = linking
        ? _StepState.pending
        : _stage == _Stage.done
            ? _StepState.done
            : _stage == _Stage.wifiNeeded
                ? _StepState.attention
                : _StepState.active;
    final String wifiLabel = _stage == _Stage.wifiJoining
        ? 'Smarty is joining Wi-Fi…'
        : wifiActive
            ? 'Checking Wi-Fi…'
            : _stage == _Stage.done
                ? 'On Wi-Fi'
                : 'Wi-Fi';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _stepRow(_StepState.done, 'Found Smarty'),
          if (DevConfig.linkingEnabled) _stepRow(linkState, linkLabel),
          _stepRow(wifiState, wifiLabel, last: true),
        ],
      ),
    );
  }

  Widget _stepRow(_StepState state, String label, {bool last = false}) {
    final Widget icon = switch (state) {
      _StepState.done =>
        Icon(Icons.check_circle, size: 20, color: Colors.green.shade600),
      _StepState.active => SizedBox(
          width: 20,
          height: 20,
          child: Padding(
            padding: const EdgeInsets.all(2),
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.blue.shade600,
            ),
          ),
        ),
      _StepState.attention =>
        Icon(Icons.error_outline, size: 20, color: Colors.orange.shade600),
      _StepState.skipped =>
        Icon(Icons.remove_circle_outline, size: 20, color: Colors.grey.shade500),
      _StepState.pending => Icon(Icons.radio_button_unchecked,
          size: 20, color: Colors.blue.shade200),
    };
    final bool dim = state == _StepState.pending || state == _StepState.skipped;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 12),
      child: Row(
        children: [
          icon,
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight:
                    state == _StepState.active ? FontWeight.w600 : FontWeight.w500,
                color: dim ? Colors.blueGrey.shade400 : Colors.blue.shade900,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWifiPrompt() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.wifi, size: 48, color: Colors.blue.shade400),
        const SizedBox(height: 12),
        Text(
          'Last step: connect Smarty to your home Wi-Fi. It only takes a minute.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, color: _headingColor),
        ),
        const SizedBox(height: 20),
        Center(
          child: _primaryButton(
            'Connect Wi-Fi',
            Icons.wifi,
            _wifiPageOpen ? null : _openWifiSetup,
          ),
        ),
        const SizedBox(height: 8),
        Center(
          child: TextButton(
            onPressed: () => _closeThisPage(),
            child: const Text('Later'),
          ),
        ),
      ],
    );
  }
}

enum _StepState { pending, active, done, attention, skipped }

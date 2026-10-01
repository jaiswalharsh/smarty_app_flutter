import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:provider/provider.dart';

import '../../dev_config.dart';
import '../../providers/user_context_provider.dart';
import '../../services/ble_manager.dart';
import '../../services/ble_service.dart';
import '../../services/device_registration_service.dart';
import '../../services/known_toys_service.dart';
import '../wifi/wifi_network_page.dart';
import 'device_registration_page.dart';
import 'setup_steps.dart';
import '../../widgets/numbered_steps.dart';
import '../../widgets/remove_toy.dart';

/// "Set up Smarty": adds a new toy (or re-pairs one) — and, with
/// [reconnectTo], "Reconnect Smarty": brings back a toy this account set up
/// before, on a freshly installed app or a new phone. Reconnecting the toy
/// SAVED on this phone is Home's job (BleManager.watchSavedToy), not this
/// page's.
///
/// Flow: instructions → live look for toys → the parent taps their toy →
/// connect (the phone asks to pair, unless the toy already knows it) → link
/// to the account → Wi-Fi → done. Toys linked to the account ([KnownToys],
/// matched by name) are listed as "Your Smarty" whatever they say about
/// pairing; toys that aren't waiting to pair and aren't the account's go
/// under "Other Smarty toys nearby" — as "Set up by another family", never
/// connected, when they say they are linked to an account (see
/// [toyListingFor]). What is connected by itself is [autoSelectIndex]'s
/// call; everything else waits for a tap. After linking a toy, the child's
/// profile this phone keeps for the account is sent to it again
/// ([UserContextProvider.resendAfterLink]) — a reset toy comes back empty.
///
/// While reconnecting, after [reconnectWayOutAfter] without the toy, the page
/// also offers "Set up a different Smarty" (the page carries on as
/// [SetupMode.newToy]) and "I don't have this Smarty any more" (takes it off
/// the account — see [confirmAndRemoveToy] — then back to Home).
///
/// Pops `true` when the toy ends up linked and on Wi-Fi (Home celebrates);
/// pops with no result when the parent leaves early ("Later", back button,
/// or the toy was removed from the account).
class SmartyConnectionPage extends StatefulWidget {
  const SmartyConnectionPage({
    super.key,
    this.reconnectTo,
    this.newToy = false,
    this.knownToys,
    @visibleForTesting this.connectToy,
    @visibleForTesting this.clock,
  });

  /// Reconnect this toy of the account ([SetupMode.reconnect]).
  final KnownToy? reconnectTo;

  /// "Set up a different Smarty" ([SetupMode.newToy]): the account's own
  /// toys are never connected by themselves.
  final bool newToy;

  /// The account's toys; [KnownToysService.instance] unless given.
  final KnownToys? knownToys;

  /// Connects and sets up a toy; [BleManager.connectAndInitialize] unless a
  /// test supplies its own.
  final Future<void> Function(BluetoothDevice device)? connectToy;

  /// The time now; [DateTime.now] unless a test supplies its own (when a toy
  /// was last heard from decides what tapping its tile does — [tileTapFor]).
  final DateTime Function()? clock;

  /// What the page was opened for (see [SmartyConnectionPageState.mode]
  /// for what it is doing now).
  SetupMode get mode => reconnectTo != null
      ? SetupMode.reconnect
      : newToy
          ? SetupMode.newToy
          : SetupMode.setUp;

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

  /// [wifiCheckingLabel]: waiting for the toy's status, or for it to start
  /// / join its saved Wi-Fi (see [decideWifiStep] for how long).
  checkingWifi,

  /// The Wi-Fi step needs the parent; which prompt is in
  /// [SmartyConnectionPageState._wifiDecision].
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
  _Stage.wifiNeeded,
};

class SmartyConnectionPageState extends State<SmartyConnectionPage> {
  final BleManager _ble = BleManager();

  /// Restart the look if the scan stopped under us (checked this often).
  static const Duration _scanWatchdog = Duration(seconds: 10);

  _Stage _stage = _Stage.scanning;

  // "Set up a different Smarty" from a reconnect: the page carries on as
  // [SetupMode.newToy].
  SetupMode? _modeOverride;

  /// What the page is doing now: [SmartyConnectionPage.mode], until the
  /// parent picks "Set up a different Smarty" while reconnecting.
  SetupMode get mode => _modeOverride ?? widget.mode;

  // The toy being reconnected (none once the page moved on to a new toy).
  KnownToy? get _reconnectTarget =>
      mode == SetupMode.reconnect ? widget.reconnectTo : null;

  // While reconnecting: [reconnectWayOutAfter] has passed since the look
  // (re)started — "Set up a different Smarty" / "I don't have this Smarty any
  // more" show while the toy still isn't there. A Timer, not the clock, so
  // tests can move time.
  Timer? _wayOutTimer;
  bool _wayOutDue = false;

  // ---- The account's toys ----------------------------------------------------
  late final KnownToys _knownSource =
      widget.knownToys ?? KnownToysService.instance;
  // Toys linked to this account (the one being reconnected at least).
  late List<KnownToy> _known = [
    if (widget.reconnectTo != null) widget.reconnectTo!,
  ];
  // BLE ids that carry a known toy's name but turned out to be another toy
  // (see _notYourToy): listed by what they advertise from then on.
  final Set<String> _notYoursIds = {};

  // ---- Looking ---------------------------------------------------------------
  // The latest scan results, as FBP gave them (re-sorted when the account's
  // toys arrive).
  List<ScanResult> _lastResults = const [];
  // The main list: the account's toys first, then toys to set up (see
  // toyListingFor).
  final List<ScanResult> _found = [];
  // Toys that aren't waiting to pair and aren't the account's ("Other Smarty
  // toys nearby").
  final List<ScanResult> _others = [];
  // What each toy seen in this look advertises (null = old firmware), and
  // where it is listed, by BLE id.
  final Map<String, ToyAdvert?> _advertById = {};
  final Map<String, ToyListing> _listingById = {};
  // When each toy in this look was last heard from, by BLE id: the time of
  // its latest advert as FBP gave it (a new one = heard again), and when it
  // arrived here ([_now]).
  final Map<String, DateTime> _advertTimeById = {};
  final Map<String, DateTime> _heardAtById = {};
  // A tapped tile whose toy had gone quiet (see tileTapFor): connected once
  // the toy is heard from again, or dropped after [staleTapWait].
  ({BluetoothDevice device, String name, DateTime tappedAt})? _checkingTap;
  Timer? _checkingTapTimer;
  // Toys dropped that way, with the advert time they had: left out of the
  // list until they are heard from again.
  final Map<String, DateTime> _droppedAt = {};
  // Pending "connect to this toy by itself" (see _maybeScheduleAutoSelect)
  // and the toy it is for.
  Timer? _autoSelectTimer;
  DeviceIdentifier? _autoSelectId;
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
  // How the toy being connected was listed, what it said about pairing, and
  // the account's toy it matched (if any) — kept for the failure message and
  // the "is it really the account's toy" check.
  ToyListing? _targetListing;
  bool? _targetAdvertPairing;
  bool? _targetRegistered;
  KnownToy? _targetKnown;
  ConnectFailure? _failure;
  // The failure's phone-side "old pairing" evidence (ConnectException).
  bool _failureStaleBond = false;
  // The toy that connected said it isn't the account's toy it looked like.
  bool _failureNotYours = false;
  // The toy this page connected (or found connected) — used to resume after
  // a drop if BleManager's background reconnect brings it back.
  BluetoothDevice? _ourToy;

  // The toy that turned out to be another account's ("Smarty-B11E"), for
  // the message.
  String? _ownedElsewhereName;
  // Another family's toy was tapped and its explanation is on its way.
  bool _explainingOtherFamily = false;

  // ---- After connect ---------------------------------------------------------
  // Bumped whenever the flow is abandoned (link lost / restarted); async
  // steps started under an older value stop quietly.
  int _flowGen = 0;
  bool _linkSkipped = false;
  bool _linkDone = false;
  bool _wifiPageOpen = false;
  StreamSubscription<String>? _wifiSub;
  // Wi-Fi check (see decideWifiStep): when it started, whether it is a Try
  // again, the periodic status re-read, and the [wifiStartingWait] and
  // [wifiCheckWait] deadlines.
  DateTime _wifiCheckStart = DateTime.now();
  bool _wifiRetrying = false;
  // This check has given an answer (its timers are stopped).
  bool _wifiAnswered = false;
  Timer? _wifiRecheckTimer;
  Timer? _wifiStartingTimer;
  Timer? _wifiDeadlineTimer;
  WifiDecision _wifiDecision = WifiDecision.checking;
  // Open the network list by itself if this check ends in
  // [WifiDecision.pickNetwork]: the first check after the link (once per
  // page), and Try again — not after the parent came back from the list.
  bool _openListOnPick = false;
  bool _listOpenedByItself = false;

  @override
  void initState() {
    super.initState();
    _ble.phase.addListener(_onPhaseChanged);
    _adapterSub = FlutterBluePlus.adapterState.listen(
      _onAdapterChanged,
      onError: (Object e) => debugPrint('SmartyConnectionPage: adapter stream: $e'),
    );
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    _armWayOut();
    unawaited(_knownSource.knownToysForAccount().then(_onKnownToys));

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
    _wayOutTimer?.cancel();
    _autoSelectTimer?.cancel();
    _checkingTapTimer?.cancel();
    _wifiSub?.cancel();
    _cancelWifiTimers();
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
        _armWayOut();
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
      if (phase == ToyPhase.pairingBroken) {
        // The toy turned this phone away after connecting (it never paired):
        // say why, as for a refused pairing — not "lost touch".
        _onTurnedAway();
      } else {
        _onLinkLost();
      }
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
    _cancelWifiTimers();
    setState(() => _stage = _Stage.lost);
  }

  void _onTurnedAway() {
    debugPrint('SmartyConnectionPage: the toy turned this phone away');
    _flowGen++;
    _wifiSub?.cancel();
    _wifiSub = null;
    _cancelWifiTimers();
    _ourToy = null;
    setState(() {
      _stage = _Stage.failed;
      _clearFailure();
      _failure = ConnectFailure.pairingBroken;
    });
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
    _cancelAutoSelect();
    setState(() {
      _stage = _Stage.scanning;
      _clearLook();
      _clearFailure();
      _scanError = false;
      _blockerFromError = null;
      _target = null;
      _targetName = null;
      _hint = ScanHint.none;
      _lookingSince = DateTime.now();
    });
    _armWayOut();
    _startScan(restart: true);
    // The account's toys again, in case the first read came back empty
    // (offline, slow): its own toy must never pass for another family's.
    unawaited(_knownSource.knownToysForAccount().then(_onKnownToys));
  }

  // (Re)start the [reconnectWayOutAfter] wait (reconnect mode only).
  void _armWayOut() {
    _wayOutTimer?.cancel();
    _wayOutTimer = null;
    _wayOutDue = false;
    if (mode != SetupMode.reconnect) return;
    _wayOutTimer = Timer(reconnectWayOutAfter, () {
      _wayOutTimer = null;
      if (mounted) setState(() => _wayOutDue = true);
    });
  }

  // Whether the look section offers the ways out (see [_armWayOut]): still
  // looking, and the toy being reconnected isn't among the toys listed.
  bool get _showWayOut =>
      _wayOutDue &&
      mode == SetupMode.reconnect &&
      _stage == _Stage.scanning &&
      !_found.any(_isReconnectTarget);

  /// "Set up a different Smarty" while reconnecting: carry on as a plain
  /// "Set up a different Smarty" page (the account's toys are still listed
  /// but never connected by themselves), with a fresh look.
  void _switchToNewToy() {
    _cancelAutoSelect();
    setState(() => _modeOverride = SetupMode.newToy);
    _lookAgain();
  }

  /// "I don't have this Smarty any more" while reconnecting: take it off the
  /// account (asks first), then back to Home.
  Future<void> _removeReconnectTarget() async {
    final KnownToy? toy = _reconnectTarget;
    if (toy == null) return;
    final bool removed = await confirmAndRemoveToy(
      context,
      bleName: toy.bleName,
      remove:
          (keep) =>
              _knownSource.removeFromAccount(toy.deviceId, keepHistory: keep),
    );
    if (removed) _closeThisPage();
  }

  void _clearLook() {
    _lastResults = const [];
    _found.clear();
    _others.clear();
    _advertById.clear();
    _listingById.clear();
    _advertTimeById.clear();
    _heardAtById.clear();
    _droppedAt.clear();
    _cancelCheckingTap();
  }

  DateTime _now() => (widget.clock ?? DateTime.now)();

  void _clearFailure() {
    _failure = null;
    _failureStaleBond = false;
    _failureNotYours = false;
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
      // removeIfGone let a toy that went quiet (turned off, its pairing wait
      // ended, or restarting under a new address) drop off the list within
      // [toyGoneAfter], and keep each toy's advert (pairing flag) fresh.
      await FlutterBluePlus.startScan(
        withServices: [BleManager.smartyServiceGuid],
        continuousUpdates: true,
        removeIfGone: toyGoneAfter,
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

  // ---- The account's toys ----------------------------------------------------

  void _onKnownToys(List<KnownToy> toys) {
    if (!mounted || toys.isEmpty) return;
    final Map<String, KnownToy> byId = {
      for (final t in _known) t.deviceId: t,
      for (final t in toys) t.deviceId: t,
    };
    setState(() => _known = byId.values.toList());
    debugPrint('SmartyConnectionPage: toys on this account: $_known');
    _applyResults(); // re-label what's already listed
  }

  /// The account's toy [name] (at BLE id [id]) is, or null.
  KnownToy? _knownFor(String id, String? name) {
    if (_notYoursIds.contains(id)) return null;
    for (final t in _known) {
      if (t.matchesName(name)) return t;
    }
    return null;
  }

  /// Whether the toy at [id] called [name] is this account's: a toy linked
  /// to the account, or the toy saved on this phone (while its pairing
  /// works — a broken one is being re-paired).
  bool _isYours(String id, String? name) {
    if (_knownFor(id, name) != null) return true;
    return id == _ble.savedToyId &&
        !_notYoursIds.contains(id) &&
        _ble.phase.value != ToyPhase.pairingBroken;
  }

  bool _isReconnectTarget(ScanResult r) {
    final KnownToy? target = _reconnectTarget;
    return target != null &&
        !_notYoursIds.contains(r.device.remoteId.str) &&
        target.matchesName(_nameOf(r));
  }

  // ---- Scan results ----------------------------------------------------------

  // Every toy seen becomes a tile: the account's own toys ("Your Smarty")
  // and toys to set up in the main list, toys that say they aren't waiting
  // to pair under "Other Smarty toys nearby" (see toyListingFor). The parent
  // taps one — or, when autoSelectIndex picks one, we connect to it by
  // ourselves after a short "Smarty found!" beat. Never to a lone toy on its
  // advert alone when its firmware doesn't say it is waiting to pair: a toy
  // bonded to ANOTHER phone advertises exactly like one in pairing mode there,
  // so connecting by ourselves could pair the neighbour's Smarty.
  void _onScanResults(List<ScanResult> results) {
    if (!mounted) return;
    if (_stage != _Stage.scanning) return;
    _lastResults = results;
    _applyResults();
  }

  @visibleForTesting
  void debugApplyScanResults(List<ScanResult> results) =>
      _onScanResults(results);

  void _applyResults() {
    if (!mounted || _stage != _Stage.scanning) return;
    final List<ScanResult> yours = [];
    final List<ScanResult> candidates = [];
    final List<ScanResult> others = [];
    final DateTime now = _now();
    for (final r in _lastResults) {
      final String id = r.device.remoteId.str;
      if (_advertTimeById[id] != r.timeStamp) {
        // A new advert: heard from just now.
        _advertTimeById[id] = r.timeStamp;
        _heardAtById[id] = now;
      }
      if (_droppedAt.containsKey(id)) {
        // Dropped after a tap found it gone: only back once heard again.
        if (_droppedAt[id] == r.timeStamp) continue;
        _droppedAt.remove(id);
      }
      final ToyAdvert? advert = ToyAdvert.fromScanResult(r);
      _advertById[id] = advert;
      final ToyListing listing =
          toyListingFor(advert, yours: _isYours(id, _nameOf(r)));
      _listingById[id] = listing;
      switch (listing) {
        case ToyListing.yours:
          yours.add(r);
        case ToyListing.candidate:
          candidates.add(r);
        case ToyListing.other:
        case ToyListing.otherFamily:
          others.add(r);
      }
    }
    final List<ScanResult> listed = [...yours, ...candidates];

    String keyOf(ScanResult r) {
      final String id = r.device.remoteId.str;
      return '$id|${_nameOf(r)}|${_listingById[id]?.name}';
    }

    bool same(List<ScanResult> a, List<ScanResult> b) {
      if (a.length != b.length) return false;
      for (int i = 0; i < a.length; i++) {
        if (keyOf(a[i]) != keyOf(b[i])) return false;
      }
      return true;
    }

    if (same(listed, _found) && same(others, _others)) {
      // Same toys, fresher adverts — no rebuild needed.
      _found
        ..clear()
        ..addAll(listed);
      _others
        ..clear()
        ..addAll(others);
    } else {
      setState(() {
        _found
          ..clear()
          ..addAll(listed);
        _others
          ..clear()
          ..addAll(others);
        _hint = _currentHint();
      });
    }
    _maybeConnectCheckedTap();
    _maybeScheduleAutoSelect();
  }

  ScanHint _currentHint() => scanHintFor(
        DateTime.now().difference(_lookingSince),
        anyListed: _found.isNotEmpty,
        othersNearby: othersShowHowToPair([
          for (final r in _others)
            _listingById[r.device.remoteId.str] ?? ToyListing.other,
        ]),
        lookingForYours: _lookingForYours,
      );

  // The page is after the account's own (linked) toy: reconnecting it, or
  // setting up again with a toy on the account (see [lookingForYoursIn]).
  bool get _lookingForYours =>
      lookingForYoursIn(mode, accountHasToys: _known.isNotEmpty);

  List<ListedToy> get _listedToys => [
        for (final r in _found)
          (
            advert: _advertById[r.device.remoteId.str],
            yours: _listingById[r.device.remoteId.str] == ToyListing.yours,
            target: _isReconnectTarget(r),
          ),
      ];

  // The toy (index into _found) to connect by ourselves now, if any.
  int? _autoPick() {
    if (!mounted ||
        _stage != _Stage.scanning ||
        _connecting ||
        _checkingTap != null ||
        _blocker != null) {
      return null;
    }
    return autoSelectIndex(_listedToys, mode: mode);
  }

  // Arm (or drop) the "connect to this toy by itself" timer. The wait lets
  // "Smarty found!" show first; everything is re-checked when it fires, so
  // another toy appearing (or the parent tapping) wins.
  void _maybeScheduleAutoSelect() {
    final int? index = _autoPick();
    if (index == null) {
      _cancelAutoSelect();
      return;
    }
    final id = _found[index].device.remoteId;
    if (_autoSelectTimer != null && _autoSelectId == id) return;
    _autoSelectTimer?.cancel();
    _autoSelectId = id;
    _autoSelectTimer = Timer(autoSelectDelay, () {
      _autoSelectTimer = null;
      _autoSelectId = null;
      final int? now = _autoPick();
      if (now == null) return;
      if (ModalRoute.of(context)?.isCurrent != true) return;
      final r = _found[now];
      if (r.device.remoteId != id) return;
      debugPrint('SmartyConnectionPage: connecting to ${_nameOf(r)} by itself '
          '(${mode.name})');
      _connect(r.device, _nameOf(r));
    });
  }

  void _cancelAutoSelect() {
    _autoSelectTimer?.cancel();
    _autoSelectTimer = null;
    _autoSelectId = null;
  }

  void _onTick() {
    if (!mounted || _stage != _Stage.scanning) return;
    final now = DateTime.now();
    final hint = _currentHint();
    if (hint != _hint) setState(() => _hint = hint);

    // Watchdog: another screen's scan (or the OS) may have stopped ours.
    if (_blocker == null &&
        _adapter == BluetoothAdapterState.on &&
        !FlutterBluePlus.isScanningNow &&
        now.difference(_lastScanStart) >= _scanWatchdog) {
      _startScan(restart: true);
    }
  }

  // ---- Tapping a tile ----------------------------------------------------------

  /// A tile was tapped: connect — unless its toy has been quiet for a while
  /// ([tileTapFor]): it may have gone (e.g. it restarted, and came back under
  /// a new Bluetooth address as a new tile), so look for it again first.
  void _onTileTapped(BluetoothDevice device, String name) {
    if (_connecting || _checkingTap != null) return;
    final String id = device.remoteId.str;
    final DateTime? heard = _heardAtById[id];
    final DateTime now = _now();
    if (tileTapFor(heard == null ? null : now.difference(heard)) ==
        TileTap.connect) {
      _connect(device, name);
      return;
    }
    debugPrint('SmartyConnectionPage: $name has been quiet — looking for it '
        'again before connecting');
    _cancelAutoSelect();
    setState(() => _checkingTap = (device: device, name: name, tappedAt: now));
    _checkingTapTimer = Timer(staleTapWait, _onCheckedTapGone);
    // The look itself may have stopped under us (the watchdog would restart
    // it only later).
    if (_adapter == BluetoothAdapterState.on &&
        !FlutterBluePlus.isScanningNow) {
      unawaited(_startScan(restart: true));
    }
  }

  /// The toy of the tile being checked was heard from again: connect.
  void _maybeConnectCheckedTap() {
    final tap = _checkingTap;
    if (tap == null) return;
    final DateTime? heard = _heardAtById[tap.device.remoteId.str];
    if (heard == null || heard.isBefore(tap.tappedAt)) return;
    _cancelCheckingTap();
    _connect(tap.device, tap.name);
  }

  /// The toy of the tile being checked stayed quiet: drop its tile (until it
  /// is heard from again) and keep looking.
  void _onCheckedTapGone() {
    _checkingTapTimer = null;
    final tap = _checkingTap;
    if (!mounted || tap == null) return;
    final String id = tap.device.remoteId.str;
    debugPrint('SmartyConnectionPage: ${tap.name} is gone — dropped from the '
        'list');
    final DateTime? advertTime = _advertTimeById[id];
    setState(() {
      _checkingTap = null;
      if (advertTime != null) _droppedAt[id] = advertTime;
    });
    _applyResults();
  }

  void _cancelCheckingTap() {
    _checkingTapTimer?.cancel();
    _checkingTapTimer = null;
    _checkingTap = null;
  }

  // ===========================================================================
  // Connecting
  // ===========================================================================

  Future<void> _connect(BluetoothDevice device, String name) async {
    if (_connecting) return;
    _connecting = true;
    _cancelAutoSelect();
    // Remember what this toy advertised (its profile size and whether it is
    // linked — the account proof — depend on it); it stops advertising once
    // connected.
    final id = device.remoteId.str;
    if (_advertById.containsKey(id)) {
      _ble.rememberAdvert(id, _advertById[id]);
    }
    setState(() {
      _stage = _Stage.connecting;
      _target = device;
      _targetName = name;
      _targetListing = _listingById[id];
      _targetAdvertPairing = _advertById[id]?.pairing;
      _targetRegistered = _advertById[id]?.registered;
      _targetKnown = _knownFor(id, name);
      _clearFailure();
    });
    await _stopScan();

    try {
      await (widget.connectToy ?? _ble.connectAndInitialize)(device);
    } on ConnectException catch (e) {
      _connecting = false;
      debugPrint('SmartyConnectionPage: connect failed (${e.kind.name}'
          '${e.staleBond ? ', stale pairing' : ''}): ${e.cause}');
      if (!mounted) return;
      if (e.kind == ConnectFailure.bluetoothOff ||
          e.kind == ConnectFailure.needsPermission) {
        // Shown as the Bluetooth state; the look restarts once it's fixed.
        setState(() {
          _blockerFromError = e.kind == ConnectFailure.bluetoothOff
              ? ToyPhase.bluetoothOff
              : ToyPhase.needsPermission;
          _stage = _Stage.scanning;
          _clearLook();
          _lookingSince = DateTime.now();
        });
        return;
      }
      setState(() {
        _stage = _Stage.failed;
        _failure = e.kind;
        _failureStaleBond = e.staleBond;
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

    // One of the account's toys (by name): make sure it really is that toy
    // before treating it as the parent's.
    final KnownToy? known = _targetKnown;
    if (known != null) {
      final bool? same = await _isSameToy(known);
      if (!mounted) {
        _connecting = false;
        return;
      }
      if (same == false) {
        _connecting = false;
        await _notYourToy(device);
        return;
      }
    }

    _connecting = false;
    _ourToy = device;
    if (!mounted) return;
    if (_ble.phase.value != ToyPhase.connected) {
      _onLinkLost();
      return;
    }
    _runAfterConnect();
  }

  /// Whether the connected toy's own id (ab06) is [known]'s: true / false,
  /// or null when it can't be read (the link step still checks the account).
  Future<bool?> _isSameToy(KnownToy known) async {
    String? id = _ble.savedToyDeviceId;
    if (id == null) {
      try {
        id = await _ble.readDeviceId();
      } catch (e) {
        debugPrint('SmartyConnectionPage: reading the toy id failed: $e');
      }
    }
    final String got = (id ?? '').trim().toLowerCase();
    if (got.isEmpty || got == '{}') return null;
    final bool same = got == known.deviceId.trim().toLowerCase();
    debugPrint('SmartyConnectionPage: ${known.bleName} is '
        '${same ? '' : 'NOT '}the account\'s toy (${known.deviceId} vs $got)');
    return same;
  }

  /// The toy that connected carries the name of one of the account's toys
  /// but is a different toy: let it go (it was just saved as this phone's
  /// toy — undo that) and say so. From now on it is listed by what it
  /// advertises, like any other toy.
  Future<void> _notYourToy(BluetoothDevice device) async {
    _notYoursIds.add(device.remoteId.str);
    _ourToy = null;
    // Stage first: forgetToy() moves the phase, which must not read as
    // "lost touch".
    setState(() {
      _stage = _Stage.failed;
      _clearFailure();
      _failureNotYours = true;
    });
    await _ble.forgetToy();
    _target = null;
  }

  // ===========================================================================
  // After connect: link → Wi-Fi → done
  // ===========================================================================

  Future<void> _runAfterConnect() async {
    if (!mounted) return;
    final int gen = ++_flowGen;
    _wifiSub?.cancel();
    _wifiSub = null;
    _cancelWifiTimers();
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
    // show the link step rather than silently skipping it. Linked to this
    // account already (e.g. this phone was just added to it): nothing to do.
    final bool? registered = await _ble.refreshRegistered();
    if (_stale(gen) || !mounted) return false;
    if (registered == true) {
      setState(() => _linkDone = true);
      return true;
    }

    // Taken now, while this page's context is sure to be usable.
    final UserContextProvider? profile = _profileProvider();
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
      // A toy that needed linking was new, reset, or erased itself after
      // being removed from an account: its profile is empty (or not this
      // family's). Send the one this account has — even if the link just
      // dropped: it then goes out when Smarty is back.
      unawaited(profile?.resendAfterLink());
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

  // The child's profile (null in tests that don't provide it).
  UserContextProvider? _profileProvider() {
    try {
      return Provider.of<UserContextProvider>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  /// The account link found this toy linked to another account: forget it
  /// (drops the link, clears it as this account's toy — Home then offers
  /// setup) and end setup with an explanation.
  Future<void> _abortOwnedElsewhere() async {
    _flowGen++;
    _wifiSub?.cancel();
    _wifiSub = null;
    _cancelWifiTimers();
    // Its name for the message, before it's forgotten.
    _ownedElsewhereName = _ble.savedToyName ?? _targetName;
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

  void _cancelWifiTimers() {
    _wifiRecheckTimer?.cancel();
    _wifiRecheckTimer = null;
    _wifiStartingTimer?.cancel();
    _wifiStartingTimer = null;
    _wifiDeadlineTimer?.cancel();
    _wifiDeadlineTimer = null;
  }

  /// What the toy we connected advertised about Wi-Fi just before we
  /// connected (null = not seen in this look, or not reported).
  bool? get _advertWifiUp {
    final id = _ourToy?.remoteId.str;
    return id == null ? null : _advertById[id]?.wifiUp;
  }

  Future<void> _wifiStep(int gen) async {
    // Follow the toy's status for the whole Wi-Fi step: it may finish
    // joining its saved Wi-Fi by itself, or report a problem.
    _wifiSub?.cancel();
    _wifiSub = _ble.wifiStatusStream.listen((_) {
      if (_stale(gen) || _ble.phase.value != ToyPhase.connected) return;
      if (_stage == _Stage.done || _wifiPageOpen) return;
      _evaluateWifi(gen);
    });
    // Smarty isn't on Wi-Fi and we stop waiting: straight to the network
    // list — once per page.
    _openListOnPick = !_listOpenedByItself;
    _startWifiCheck(gen);
  }

  /// Start (or restart, for Check again / back from the list) the Wi-Fi
  /// check: ask the toy now and every [wifiRecheckEvery], and decide by
  /// [wifiStartingWait] / [wifiCheckWait]. Try again ([retrying]) doesn't
  /// wait again: one fresh look at the toy's status, then an answer.
  void _startWifiCheck(int gen, {bool retrying = false}) {
    if (_stale(gen)) return;
    _cancelWifiTimers();
    _wifiCheckStart = DateTime.now();
    _wifiRetrying = retrying;
    _wifiAnswered = false;
    if (retrying) {
      unawaited(_recheckStatusThenDecide(gen));
      return;
    }
    _wifiRecheckTimer = Timer.periodic(wifiRecheckEvery, (_) {
      if (_stale(gen) || _stage != _Stage.checkingWifi || _wifiPageOpen) return;
      unawaited(_ble.readStatusUpdate());
      _evaluateWifi(gen);
    });
    _wifiStartingTimer = Timer(wifiStartingWait, () => _evaluateWifi(gen));
    _wifiDeadlineTimer = Timer(wifiCheckWait, () => _evaluateWifi(gen));
    unawaited(_ble.readStatusUpdate());
    _evaluateWifi(gen);
  }

  // Try again: read the toy's status once (a few seconds at most), then
  // decide — on Wi-Fi now, or the network list.
  Future<void> _recheckStatusThenDecide(int gen) async {
    try {
      await _ble.readStatusUpdate().timeout(wifiRecheckEvery);
    } catch (e) {
      debugPrint('SmartyConnectionPage: status re-read failed: $e');
    }
    _evaluateWifi(gen);
  }

  void _evaluateWifi(int gen) {
    if (_stale(gen) || _stage == _Stage.done || _wifiPageOpen) return;
    final WifiDecision d = decideWifiStep(
      status: _ble.connectedWifi,
      advertWifiUp: _advertWifiUp,
      waited: DateTime.now().difference(_wifiCheckStart),
      retrying: _wifiRetrying,
    );
    switch (d) {
      case WifiDecision.connected:
        _finish(gen);
        return;
      case WifiDecision.checking:
        if (_wifiAnswered) {
          // After an answer the toy started over (e.g. it is joining again):
          // a fresh check, with its own wait.
          _startWifiCheck(gen);
          return;
        }
        if (_stage != _Stage.checkingWifi) {
          setState(() => _stage = _Stage.checkingWifi);
        }
        return;
      case WifiDecision.needsSetup:
      case WifiDecision.authFailed:
      case WifiDecision.unreachable:
      case WifiDecision.couldNotCheck:
      case WifiDecision.pickNetwork:
        // An answer: stop polling (the status stream still follows the toy,
        // e.g. it joins its saved Wi-Fi later and setup finishes by itself).
        _cancelWifiTimers();
        _wifiAnswered = true;
        final bool openList =
            d == WifiDecision.pickNetwork && _openListOnPick;
        _openListOnPick = false;
        if (_stage != _Stage.wifiNeeded || _wifiDecision != d) {
          setState(() {
            _stage = _Stage.wifiNeeded;
            _wifiDecision = d;
          });
        }
        if (openList) {
          _listOpenedByItself = true;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (_stale(gen) ||
                _stage != _Stage.wifiNeeded ||
                _wifiDecision != WifiDecision.pickNetwork ||
                ModalRoute.of(context)?.isCurrent != true) {
              return;
            }
            unawaited(_openWifiSetup());
          });
        }
        return;
    }
  }

  /// Try again ([retrying]: no waiting again — on Wi-Fi now, or the network
  /// list) / Check again (wait again): show [wifiCheckingLabel] meanwhile.
  void _recheckWifi({required bool retrying}) {
    final int gen = _flowGen;
    if (_stale(gen)) return;
    _openListOnPick = retrying;
    setState(() => _stage = _Stage.checkingWifi);
    _startWifiCheck(gen, retrying: retrying);
  }

  Future<void> _openWifiSetup() async {
    if (_wifiPageOpen) return;
    final int gen = _flowGen;
    _wifiPageOpen = true;
    // The step gave up waiting: say so over the list.
    final String? intro = _stage == _Stage.wifiNeeded &&
            _wifiDecision == WifiDecision.pickNetwork
        ? wifiPickNetworkLine
        : null;
    final bool? joined;
    try {
      // WifiNetworkPage pops `true` once the toy has actually joined.
      joined = await Navigator.push<bool>(
        context,
        MaterialPageRoute(builder: (_) => WifiNetworkPage(intro: intro)),
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
    // Back without joining: check where the toy stands now — without opening
    // the list again by itself.
    _openListOnPick = false;
    _startWifiCheck(gen);
  }

  void _finish(int gen) {
    if (_stale(gen) || _stage == _Stage.done) return;
    _wifiSub?.cancel();
    _wifiSub = null;
    _cancelWifiTimers();
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
        title: Text(
          mode == SetupMode.reconnect
              ? 'Reconnect Smarty'
              : 'Set up Smarty',
          style: const TextStyle(
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
            heading: ownedElsewhereHeading,
            text: ownedElsewhereMessage(_ownedElsewhereName),
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
        !_scanError &&
        _hint == ScanHint.stoppedWaiting &&
        _blocker == null;
    final bool reconnect = mode == SetupMode.reconnect;
    // The account's toy is linked: a new phone only needs this account —
    // say so when that is the toy the page is after.
    final List<String> lines = reconnect
        ? const [reconnectFirstLine, newPhoneLine]
        : [
            setupFirstBootLine,
            setupButtonHoldLine,
            if (_lookingForYours) newPhoneLine,
          ];
    final TextStyle bodyStyle = TextStyle(
      fontSize: 16,
      height: 1.35,
      color: emphasise ? Colors.orange.shade800 : Colors.blue.shade800,
    );
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
                for (final line in lines) ...[
                  const SizedBox(height: 6),
                  Text(line, style: bodyStyle),
                ],
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
    final checking = _checkingTap;
    // Checking a tapped tile's toy is still there reads as connecting: it
    // connects as soon as the toy is heard from.
    final bool connecting = _stage == _Stage.connecting || checking != null;

    // Every toy in the main list is a tile (kept, dimmed, while connecting);
    // the one being connected (or checked) is always shown.
    final List<(BluetoothDevice, String?, ToyListing)> tiles = [
      for (final r in _found)
        (
          r.device,
          _nameOf(r),
          _listingById[r.device.remoteId.str] ?? ToyListing.candidate,
        ),
    ];
    final BluetoothDevice? target = checking?.device ?? _target;
    if (connecting &&
        target != null &&
        !tiles.any((t) => t.$1.remoteId == target.remoteId)) {
      tiles.insert(
          0,
          checking != null
              ? (
                  checking.device,
                  checking.name,
                  _listingById[checking.device.remoteId.str] ??
                      ToyListing.candidate,
                )
              : (target, _targetName, _targetListing ?? ToyListing.candidate));
    }

    final LookSectionView view = lookSectionView(
      connecting: connecting,
      listed: tiles.length,
      scanStopped: _scanError && !connecting,
      hint: _hint,
      reconnect: mode == SetupMode.reconnect,
    );
    out.add(_sectionHeader(
      view.header,
      leading: switch (view.icon) {
        LookIcon.spinner => _inlineSpinner(),
        LookIcon.found =>
          Icon(Icons.check_circle, color: Colors.green.shade600, size: 20),
        LookIcon.none => null,
      },
    ));
    if (view.subtitle != null) {
      out
        ..add(const SizedBox(height: 4))
        ..add(Text(
          view.subtitle!,
          style: TextStyle(fontSize: 15, color: _secondaryTextColor),
        ));
    }

    if (tiles.isNotEmpty) {
      out.add(const SizedBox(height: 16));
      for (final t in tiles) {
        // A lone toy gets a clear "Tap to connect" (we may connect to it by
        // ourselves after a moment anyway — see autoSelectIndex).
        out.add(_toyTile(t.$1, t.$2, t.$3,
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
                pairPromptNote(
                    onlyYours: tiles.every((t) => t.$3 == ToyListing.yours)),
                style: TextStyle(fontSize: 15, color: _headingColor),
              ),
            ),
          ],
        ));
    }

    // Toys that aren't waiting to pair: greyed, but tappable (one may know
    // this phone from another account) — and another family's toys, which
    // only explain themselves when tapped.
    if (!connecting && _others.isNotEmpty) {
      out
        ..add(const SizedBox(height: 24))
        ..add(Text(
          otherToysHeading,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: _secondaryTextColor,
          ),
        ))
        ..add(const SizedBox(height: 8));
      for (final r in _others) {
        out.add(_toyTile(r.device, _nameOf(r),
            _listingById[r.device.remoteId.str] ?? ToyListing.other));
      }
    }

    // Text only while the look is running; "Look again" only once it has
    // actually stopped (see lookSectionView).
    if (view.hint != null) {
      out
        ..add(const SizedBox(height: 20))
        ..add(Text(
          view.hint!,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 15,
            color: view.hintIsWarning
                ? Colors.orange.shade800
                : _secondaryTextColor,
          ),
        ));
    }
    if (view.showLookAgain) {
      out
        ..add(const SizedBox(height: 8))
        ..add(Center(
          child: TextButton.icon(
            onPressed: _lookAgain,
            icon: const Icon(Icons.refresh),
            label: const Text('Look again'),
          ),
        ));
    }
    // Reconnecting and the toy still isn't here: other ways on.
    if (_showWayOut) {
      out
        ..add(const SizedBox(height: 16))
        ..add(Center(
          child: TextButton(
            onPressed: _switchToNewToy,
            child: const Text(
              'Set up a different Smarty',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
        ))
        ..add(Center(
          child: TextButton(
            onPressed: () => unawaited(_removeReconnectTarget()),
            child: Text(
              noLongerHaveToyLabel,
              style: TextStyle(fontSize: 15, color: _secondaryTextColor),
            ),
          ),
        ));
    }
    return out;
  }

  Widget _toyTile(BluetoothDevice device, String? rawName, ToyListing listing,
      {bool highlight = false}) {
    final bool checking = _checkingTap?.device.remoteId == device.remoteId;
    final bool isTarget = checking ||
        (_target != null && _target!.remoteId == device.remoteId);
    final bool busy =
        _connecting || _checkingTap != null || _stage != _Stage.scanning;
    final String? code = BleManager.toyCode(rawName);
    final String display = BleManager.toyDisplayName(rawName);
    final bool otherFamily = listing == ToyListing.otherFamily;
    final bool other = listing == ToyListing.other || otherFamily;
    // "Your Smarty" only for this account's own toy; anything else is just
    // "Smarty" + its code (it could be a neighbour's).
    final String title = switch (listing) {
      ToyListing.yours => 'Your Smarty',
      ToyListing.candidate => display,
      ToyListing.other ||
      ToyListing.otherFamily => code != null ? '$display $code' : display,
    };
    final String? subtitle = otherFamily
        ? otherFamilySubtitle
        : other
            ? otherToySubtitle
            : code;
    final Color accent = Colors.blue.shade600;
    final Widget card = Card(
      elevation: highlight ? 3 : (other ? 0 : 1),
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
        subtitle: subtitle != null ? Text(subtitle) : null,
        trailing: checking || (isTarget && _stage == _Stage.connecting)
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
                : Icon(otherFamily ? Icons.lock_outline : Icons.chevron_right,
                    color: busy || other ? Colors.grey : accent),
        onTap: busy
            ? null
            : otherFamily
                ? () => unawaited(_onOtherFamilyTapped(device, rawName))
                : () => _onTileTapped(device, rawName ?? ''),
      ),
    );
    // Greyed: it can't pair with this phone unless its buttons are held — or,
    // another family's, at all.
    return other && !isTarget ? Opacity(opacity: 0.6, child: card) : card;
  }

  /// Another family's toy was tapped ([ToyListing.otherFamily]): never
  /// connect — explain. The account's toys are asked for once more first
  /// (from memory, normally): if the read before came back empty (offline,
  /// slow), this may be the parent's own toy after all, and then it is
  /// connected as such.
  Future<void> _onOtherFamilyTapped(
      BluetoothDevice device, String? rawName) async {
    if (_explainingOtherFamily) return;
    _explainingOtherFamily = true;
    try {
      _onKnownToys(await _knownSource.knownToysForAccount());
      if (!mounted || _stage != _Stage.scanning || _connecting) return;
      if (_isYours(device.remoteId.str, rawName)) {
        _onTileTapped(device, rawName ?? '');
        return;
      }
      if (ModalRoute.of(context)?.isCurrent != true) return;
      await _explainOtherFamily(rawName);
    } finally {
      _explainingOtherFamily = false;
    }
  }

  Future<void> _explainOtherFamily(String? rawName) {
    return showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(Icons.lock_outline, color: Colors.orange.shade400),
        title: const Text(otherFamilyHeading),
        content: Text(otherFamilyMessage(rawName)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildFailure() {
    if (_failureNotYours) {
      return _buildMessage(
        icon: Icons.help_outline,
        iconColor: Colors.orange.shade400,
        text: notYourToyMessage,
        actions: [_primaryButton('Try again', Icons.refresh, _lookAgain)],
      );
    }
    final kind = _failure ?? ConnectFailure.unknown;
    final bool isIOS = Platform.isIOS;
    final ConnectAdvice advice = connectAdviceFor(
      kind,
      staleBond: _failureStaleBond,
      yours: _targetListing == ToyListing.yours,
      advertPairing: _targetAdvertPairing,
      registered: _targetRegistered,
    );
    final bool forgetOld = advice == ConnectAdvice.forgetOldPairing;
    final bool notConfirmed = advice == ConnectAdvice.notConfirmed;
    return _buildMessage(
      icon: advice == ConnectAdvice.plain ? Icons.error_outline : Icons.link_off,
      iconColor: Colors.orange.shade400,
      // Old pairing: the heading line, then the steps as a numbered list
      // (same words as Home). Otherwise: one line.
      text: switch (advice) {
        ConnectAdvice.forgetOldPairing => pairingBrokenHeading,
        ConnectAdvice.notConfirmed => notConfirmedMessage,
        ConnectAdvice.holdButtons => setUpWithAnotherPhoneMessage,
        ConnectAdvice.maybeHoldButtons => maybeAnotherPhoneMessage,
        ConnectAdvice.plain => connectFailureMessage(kind, isIOS: isIOS),
      },
      steps: forgetOld ? pairingBrokenStepList(isIOS: isIOS) : null,
      // The way out when this account can't prove it's the toy's.
      hint: notConfirmed ? resetAndSetUpAgainLine : null,
      actions: [
        _primaryButton('Try again', Icons.refresh, _lookAgain),
        if (forgetOld && isIOS) ...[
          const SizedBox(height: 8),
          TextButton(
            onPressed: () => unawaited(BleService.openBluetoothSettings()),
            child: const Text('Open Settings'),
          ),
        ],
      ],
    );
  }

  // Same copy as Home's Bluetooth views (setup_steps.dart). Bluetooth off on
  // iOS: Control Center first; "Open Settings" can only open this app's page,
  // and says so under it.
  Widget _buildBlocker(ToyPhase blocker) {
    final bool isIOS = Platform.isIOS;
    if (blocker == ToyPhase.needsPermission) {
      return _buildMessage(
        icon: Icons.bluetooth_searching,
        iconColor: Colors.blue.shade400,
        // Heading = the state (as on Home's card); text = what to do.
        heading: 'Bluetooth permission needed',
        text: bluetoothPermissionLine,
        hint: bluetoothPermissionHint(isIOS: isIOS),
        actions: [
          _primaryButton(
            'Open Settings',
            Icons.settings,
            () => unawaited(BleService.openAppPermissionSettings()),
          ),
        ],
      );
    }
    final BluetoothOffView view = bluetoothOffViewFor(isIOS: isIOS);
    return _buildMessage(
      icon: Icons.bluetooth_disabled,
      iconColor: Colors.blue.shade400,
      heading: 'Bluetooth is off',
      text: view.line,
      hint: view.quickStep,
      actions: [
        _primaryButton(
          view.buttonLabel,
          view.turnsOn ? Icons.bluetooth : Icons.settings,
          () => unawaited(_ble.requestBluetoothOn()),
        ),
      ],
      actionNote: view.buttonNote,
    );
  }

  /// [actionNote]: a line right under the [actions] (where a button goes,
  /// when its label can't say).
  Widget _buildMessage({
    required IconData icon,
    required Color iconColor,
    String? heading,
    required String text,
    List<String>? steps,
    String? hint,
    required List<Widget> actions,
    String? actionNote,
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
        if (steps != null) ...[
          const SizedBox(height: 12),
          NumberedSteps(
            steps: steps,
            style: TextStyle(fontSize: 16, color: _secondaryTextColor),
          ),
        ],
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
        if (actionNote != null) ...[
          const SizedBox(height: 8),
          Text(
            actionNote,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _secondaryTextColor),
          ),
        ],
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
    final String wifiLabel = _stage == _Stage.checkingWifi
        ? wifiCheckingLabel
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
    final WifiDecision d = _wifiDecision;
    final bool problem =
        d == WifiDecision.authFailed || d == WifiDecision.unreachable;
    final VoidCallback? openWifi = _wifiPageOpen ? null : _openWifiSetup;

    final IconData icon = switch (d) {
      WifiDecision.couldNotCheck => Icons.wifi_find,
      _ when problem => Icons.wifi_off,
      _ => Icons.wifi,
    };
    final Color iconColor =
        d == WifiDecision.needsSetup || d == WifiDecision.pickNetwork
            ? Colors.blue.shade400
            : Colors.orange.shade400;
    final String message =
        wifiDecisionMessage(d, ssid: _ble.lastKnownWifiName) ?? '';

    final List<Widget> actions = switch (d) {
      WifiDecision.authFailed || WifiDecision.unreachable => [
          Center(
            child: _primaryButton('Try again', Icons.refresh,
                () => _recheckWifi(retrying: true)),
          ),
          const SizedBox(height: 8),
          Center(
            child: _secondaryButton(
                'Use a different Wi-Fi', Icons.wifi, openWifi),
          ),
        ],
      WifiDecision.couldNotCheck => [
          Center(
            child: _primaryButton('Check again', Icons.refresh,
                () => _recheckWifi(retrying: false)),
          ),
          const SizedBox(height: 8),
          Center(child: _secondaryButton('Set up Wi-Fi', Icons.wifi, openWifi)),
        ],
      _ => [
          Center(child: _primaryButton('Connect Wi-Fi', Icons.wifi, openWifi)),
        ],
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(icon, size: 48, color: iconColor),
        const SizedBox(height: 12),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 17, color: _headingColor),
        ),
        const SizedBox(height: 20),
        ...actions,
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

  Widget _secondaryButton(
      String label, IconData icon, VoidCallback? onPressed) {
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 20),
      label: Text(label, style: const TextStyle(fontSize: 16)),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.blue.shade700,
        side: BorderSide(color: Colors.blue.shade300),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

enum _StepState { pending, active, done, attention, skipped }

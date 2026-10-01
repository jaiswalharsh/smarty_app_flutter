import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../dev_config.dart';
import '../utils/wifi_utils.dart';
import 'ble_service.dart';
import 'known_toys_service.dart' show KnownToysService;
import 'link_check_service.dart';
import 'toy_claim.dart';

/// Outcome of a Wi-Fi provisioning attempt, derived from the device's own status
/// characteristic — NOT merely from the BLE credential write being acknowledged.
enum WifiProvisionResult {
  connected,        // device reported it joined the target SSID (got an IP)
  wrongPassword,    // device reported "Auth Failed"
  failed,           // device reported a non-auth connection failure
  bleDisconnected,  // the BLE link to the toy dropped — a join result can't arrive
  timeout,          // no definitive status within the wait window
  writeError,       // couldn't even deliver the credentials over BLE
}

/// Where the app stands with the parent's saved toy. The single source of truth
/// for every "is Smarty there?" UI — screens render from [BleManager.phase]
/// instead of running their own connect logic.
///
/// Firmware facts this relies on (bt_setup.c): a bonded toy advertises
/// continuously whenever it is on and not connected, so a short scan that sees
/// nothing means off / out of range / connected to another phone — we can't
/// tell which, so [notNearby] must never claim "the toy is off". A toy
/// keeps its bonds when its pairing window opens; only a factory reset (or
/// the toy erasing itself after being removed from its account) drops them,
/// which surfaces here as [pairingBroken]. A toy linked to an account only
/// lets a phone pair once it has proved it is on that account (the claim —
/// see [BleManager.shouldClaim]); its buttons can't open pairing.
enum ToyPhase {
  /// Signed out, or no toy saved for this account. Offer setup.
  noToy,

  /// A toy is saved but the phone's Bluetooth is off (or unavailable).
  /// Never presented as "the toy is off".
  bluetoothOff,

  /// A toy is saved but the app isn't allowed to use Bluetooth.
  needsPermission,

  /// Short (≤3 s) check for the saved toy is running. Also shown while the
  /// Bluetooth adapter hasn't reported a definite state yet.
  probing,

  /// Saved toy not seen. A pending background connect is armed and will
  /// connect by itself as soon as the toy advertises — no user action needed.
  notNearby,

  /// Link is coming up / the Smarty service is being set up.
  connecting,

  /// The phone holds a pairing the toy no longer knows (the toy was reset,
  /// or erased itself after being removed from its account), or the toy
  /// turned this phone away (it couldn't prove it is on the toy's account).
  /// iOS: the parent must forget Smarty in Settings → Bluetooth. Android: the
  /// bond is removed automatically; the next attempt pairs fresh. Never
  /// auto-retried.
  pairingBroken,

  /// Fully set up: characteristics cached, status monitoring running.
  connected,
}

/// Why a connect/initialize attempt failed. See [ConnectException] and
/// [BleManager.classifyConnectError].
enum ConnectFailure {
  /// The phone's stored pairing is stale (toy wiped its bonds), or the toy
  /// refused to pair with this phone (set up with another phone and not
  /// waiting to pair, or linked and this phone couldn't prove its account —
  /// see [ConnectException.staleBond]). Recovery: forget in iOS Settings;
  /// removeBond on Android (done automatically by BleManager).
  pairingBroken,

  /// The attempt was cancelled (by the app itself, or the user declined).
  cancelledByUser,

  /// Timed out / not found / generic Android 133 — most likely out of range
  /// or off.
  outOfRange,

  /// Something answered but it has no usable Smarty service.
  notSmarty,

  /// The phone's Bluetooth is off.
  bluetoothOff,

  /// The app lacks Bluetooth permission.
  needsPermission,

  /// The toy turned down this phone's account proof (the claim — see
  /// [BleManager.shouldClaim]): the proof write failed, or the toy hung up
  /// right after it. This phone's account isn't the toy's (or the key it
  /// used is out of date — it is dropped, so Try again reads it afresh).
  notYourAccount,

  /// Anything else.
  unknown,
}

/// Thrown by [BleManager.initialize] and [BleManager.connectAndInitialize].
/// [kind] is what the UI should branch on; [cause] is the underlying error, for
/// logging only — never show it to the parent.
class ConnectException implements Exception {
  final ConnectFailure kind;
  final Object? cause;

  /// For [ConnectFailure.pairingBroken]: the phone's Bluetooth said outright
  /// that the toy has dropped THIS phone's stored pairing (see
  /// [BleManager.isStaleBondEvidence]) — the parent should forget the old
  /// pairing. false = the pairing was refused without saying so, e.g. a toy
  /// set up with another phone that isn't waiting to pair.
  final bool staleBond;

  const ConnectException(this.kind, [this.cause, this.staleBond = false]);

  @override
  String toString() =>
      'ConnectException(${kind.name}${staleBond ? ', stale pairing' : ''}): '
      '$cause';
}

/// What one link drop means for the stale-pairing check. See
/// [LinkDropTracker.linkDown].
enum LinkDropVerdict {
  /// We dropped the link ourselves (disconnect(), cancel, adapter going off).
  /// Doesn't count either way.
  intentional,

  /// The link had been up long enough: an ordinary drop (toy switched off,
  /// walked away). Breaks any quick-drop streak.
  normal,

  /// Dropped within [LinkDropTracker.quickWindow] of coming up, but not (yet)
  /// often enough to call the pairing broken.
  quick,

  /// The drop's own reason says the toy rejected our keys (iOS CBError 14
  /// "Peer removed pairing information", Android HCI 0x05/0x06/0x3D …).
  pairingReason,

  /// [LinkDropTracker.threshold] quick drops in a row — the signature of a toy
  /// that no longer knows this phone (iOS connects, fails to encrypt and hangs
  /// up ~0.4 s later, often without a telling reason).
  repeatedQuickDrops,

  /// The toy hung up on a link where no account proof was given and nothing
  /// encrypted ever worked, [LinkDropTracker.turnedAwayAfter]–
  /// [LinkDropTracker.turnedAwayBefore] after it came up: the toy closes the
  /// link of a phone that neither proved its account nor is paired with it
  /// 30 s after it connects (bt_setup.c). A refused pairing, decided at
  /// once.
  turnedAway,
}

/// Pure bookkeeping for the "connected, then dropped almost at once" signature
/// of a stale pairing. One instance follows one toy's link; every up/down is
/// reported here from whichever code path sees it first, so each link is
/// counted exactly once ([linkDown] is idempotent until the next [linkUp]).
///
/// The streak survives failed attempts, re-arms and backoff (it is only
/// broken by a link that stayed up past [quickWindow], or by [reset]), so the
/// second quick drop in a row is always recognised — whichever path the drop
/// happened in (pending connect, mid-initialize, after connected).
class LinkDropTracker {
  LinkDropTracker({
    this.quickWindow = const Duration(seconds: 4),
    this.threshold = 2,
    this.turnedAwayAfter = const Duration(seconds: 20),
    this.turnedAwayBefore = const Duration(seconds: 60),
  });

  /// A drop sooner than this after link-up counts as quick.
  final Duration quickWindow;

  /// Quick drops in a row that mean "pairing broken".
  final int threshold;

  /// A link that never got encrypted ([linkSecured]) nor carried an account
  /// proof ([linkProved]) and dropped this long after coming up — up to
  /// [turnedAwayBefore] — was the toy turning this phone away
  /// ([LinkDropVerdict.turnedAway]).
  final Duration turnedAwayAfter;
  final Duration turnedAwayBefore;

  bool _up = false;
  DateTime? _upAt;
  bool _secure = false;
  bool _proved = false;
  int _quickDrops = 0;

  /// Whether a link is currently recorded as up.
  bool get isUp => _up;

  /// Quick drops in the current streak.
  int get quickDrops => _quickDrops;

  /// The link came up at [now]. A second call for the same link is ignored
  /// (keeps the first, earliest time).
  void linkUp(DateTime now) {
    if (_up) return;
    _up = true;
    _upAt = now;
    _secure = false;
    _proved = false;
  }

  /// Something encrypted worked on the link that is up (the phone is paired
  /// with the toy): its drop can't be the toy turning this phone away.
  void linkSecured() {
    if (_up) _secure = true;
  }

  /// The toy took this phone's account proof on the link that is up: it now
  /// waits (up to a minute) for the phone to pair — a drop after that is
  /// the pairing not finishing, not the toy turning this phone away.
  void linkProved() {
    if (_up) _proved = true;
  }

  /// The link went down at [now]. Returns null when no link was recorded as
  /// up (already counted, or it never came up — e.g. a failed direct
  /// connect, which is classified from its error instead).
  ///
  /// [intentional] (we dropped it) leaves the streak unchanged;
  /// [pairingReason] decides at once, and so does a link that never got
  /// encrypted nor carried an account proof dropping
  /// [turnedAwayAfter]–[turnedAwayBefore] after it came up
  /// ([LinkDropVerdict.turnedAway]). A [repeatedQuickDrops],
  /// [pairingReason] or [turnedAway] verdict resets the streak.
  LinkDropVerdict? linkDown(
    DateTime now, {
    bool pairingReason = false,
    bool intentional = false,
  }) {
    if (!_up) return null;
    final DateTime? upAt = _upAt;
    final bool secure = _secure || _proved;
    _up = false;
    _upAt = null;
    _secure = false;
    _proved = false;
    if (intentional) return LinkDropVerdict.intentional;
    if (pairingReason) {
      _quickDrops = 0;
      return LinkDropVerdict.pairingReason;
    }
    final Duration? held = upAt == null ? null : now.difference(upAt);
    if (!secure &&
        held != null &&
        held >= turnedAwayAfter &&
        held <= turnedAwayBefore) {
      _quickDrops = 0;
      return LinkDropVerdict.turnedAway;
    }
    if (held == null || held > quickWindow) {
      _quickDrops = 0; // a link that held breaks the streak
      return LinkDropVerdict.normal;
    }
    _quickDrops++;
    if (_quickDrops >= threshold) {
      _quickDrops = 0;
      return LinkDropVerdict.repeatedQuickDrops;
    }
    return LinkDropVerdict.quick;
  }

  /// A connect attempt failed before any link was up (iOS reports a failed
  /// encryption with stale keys as didFailToConnectPeripheral — the app
  /// never sees "connected"). Counts like a quick drop; [pairingReason]
  /// decides at once. Callers must report each failed attempt once, and only
  /// failures that can mean a stale pairing (not routine ones such as
  /// Android's GATT 133).
  LinkDropVerdict linkFailed({bool pairingReason = false}) {
    _up = false;
    _upAt = null;
    if (pairingReason) {
      _quickDrops = 0;
      return LinkDropVerdict.pairingReason;
    }
    _quickDrops++;
    if (_quickDrops >= threshold) {
      _quickDrops = 0;
      return LinkDropVerdict.repeatedQuickDrops;
    }
    return LinkDropVerdict.quick;
  }

  /// Forget everything (pairing repaired / toy forgotten / signed out).
  void reset() {
    _up = false;
    _upAt = null;
    _secure = false;
    _proved = false;
    _quickDrops = 0;
  }
}

/// What a toy says about itself in its advertisement, before any connection:
/// Service Data under the Smarty service UUID 0xABCD, 2 bytes `[flags, ver]`
/// (bt_setup.c adv data).
///
/// - `flags` bit0 = pairing mode (waiting for a phone), bit1 = on Wi-Fi,
///   bit2 = registered (holds its backend secret). Bits 3–7 reserved.
/// - `ver` = 1: the profile attribute (ab03) holds 1024 bytes. Absent / 0:
///   older firmware, 500 bytes.
///
/// Firmware from before this marker advertises no service data at all —
/// [fromScanResult] then returns null and callers treat the toy as before.
/// Pure and immutable, so it can be unit-tested with hand-made scan results.
@immutable
class ToyAdvert {
  /// Toy is in pairing mode (waiting for a phone). null = not reported.
  final bool? pairing;

  /// Toy is on Wi-Fi. null = not reported.
  final bool? wifiUp;

  /// Toy holds its backend secret. null = not reported.
  final bool? registered;

  /// Advert format version (`ver` byte); 0 when absent.
  final int version;

  const ToyAdvert({
    this.pairing,
    this.wifiUp,
    this.registered,
    this.version = 0,
  });

  /// Service data present but no (or a zero) version byte.
  bool get isLegacy => version == 0;

  /// Parse the 0xABCD service data out of a scan result, or null when the
  /// toy sent none (old firmware).
  static ToyAdvert? fromScanResult(ScanResult r) =>
      fromServiceData(r.advertisementData.serviceData);

  /// [fromScanResult] on a raw service-data map. FBP keys it by [Guid], and
  /// `Guid("abcd")` equals the 128-bit base form
  /// `0000abcd-0000-1000-8000-00805f9b34fb`, so either spelling from the
  /// platform matches. Other UUIDs are ignored; empty data counts as none.
  static ToyAdvert? fromServiceData(Map<Guid, List<int>> serviceData) {
    final List<int>? data = serviceData[BleManager.smartyServiceGuid];
    if (data == null || data.isEmpty) return null;
    final int flags = data[0] & 0xFF;
    final int version = data.length >= 2 ? data[1] & 0xFF : 0;
    return ToyAdvert(
      pairing: flags & 0x01 != 0,
      wifiUp: flags & 0x02 != 0,
      registered: flags & 0x04 != 0,
      version: version,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ToyAdvert &&
      other.pairing == pairing &&
      other.wifiUp == wifiUp &&
      other.registered == registered &&
      other.version == version;

  @override
  int get hashCode => Object.hash(pairing, wifiUp, registered, version);

  @override
  String toString() => 'ToyAdvert(pairing: $pairing, wifiUp: $wifiUp, '
      'registered: $registered, version: $version)';
}

/// One status report from the toy (ab04), whatever format it came in. Each
/// field is null when the report didn't include it. Pure and immutable — see
/// [ToyStatus.parse].
@immutable
class ToyStatus {
  /// Raw `wifi` value: a network name, or a status token such as
  /// "Initializing" / "No credentials" / "Auth Failed" (wifi_config.c).
  final String? wifi;
  final int? battery;

  /// Whether the toy holds its backend secret (JSON only).
  final bool? registered;

  const ToyStatus({this.wifi, this.battery, this.registered});

  /// Parse a status value. Formats the firmware has used:
  ///  - JSON (notifications, and reads since 2026-09):
  ///    `{"version":"1.0","battery":90,"wifi":"HomeNet","registered":false,…}`
  ///  - legacy key-value (reads on older firmware): `BAT:90,WIFI:HomeNet` —
  ///    WIFI is written last, so it runs to the end (a name may contain `,`
  ///    or `:`);
  ///  - oldest: `HomeNet,90`.
  /// Returns null for something unusable — including JSON-looking text that
  /// doesn't parse (e.g. cut short), which must never be taken for a
  /// network name.
  static ToyStatus? parse(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return null;

    if (text.startsWith('{') || text.startsWith('[')) {
      final Object? decoded;
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        return null;
      }
      if (decoded is! Map) return null;
      final Object? wifi = decoded['wifi'];
      final Object? reg = decoded['registered'];
      return ToyStatus(
        wifi: wifi?.toString(),
        battery: _batteryFrom(decoded['battery']),
        registered: reg is bool ? reg : null,
      );
    }

    final int wifiAt = text.indexOf('WIFI:');
    final int batAt = text.indexOf('BAT:');
    if (wifiAt >= 0 || batAt >= 0) {
      String? wifi;
      if (wifiAt >= 0) {
        String rest = text.substring(wifiAt + 'WIFI:'.length);
        // Tolerate the other order too ("WIFI:x,BAT:90").
        final int batAfter = rest.lastIndexOf(',BAT:');
        if (batAt > wifiAt && batAfter >= 0) rest = rest.substring(0, batAfter);
        wifi = rest.trim();
      }
      int? battery;
      if (batAt >= 0) {
        final m = RegExp(r'^BAT:\s*(\d+)').firstMatch(text.substring(batAt));
        if (m != null) battery = int.tryParse(m.group(1)!);
      }
      return ToyStatus(wifi: wifi, battery: battery);
    }

    final List<String> parts = text.split(',');
    return ToyStatus(
      wifi: parts.first.trim(),
      battery: parts.length >= 2 ? int.tryParse(parts[1].trim()) : null,
    );
  }

  static int? _batteryFrom(Object? v) {
    if (v is int) return v;
    if (v is double) return v.toInt();
    if (v == null) return null;
    final digits = v.toString().replaceAll(RegExp(r'[^0-9]'), '');
    return digits.isEmpty ? null : int.tryParse(digits);
  }

  @override
  String toString() =>
      'ToyStatus(wifi: $wifi, battery: $battery, registered: $registered)';
}

/// What reading the toy's own id (ab06) gave — see [BleManager.readToyId].
@immutable
class ToyIdRead {
  /// The toy's id ([id]).
  const ToyIdRead.ready(String this.id) : stillStarting = false;

  /// No id. [stillStarting]: the toy answered, but its id was still empty
  /// every time — it is still starting up (tap Try again). Otherwise no read
  /// was answered at all (the link is gone, or the toy has no id to read).
  const ToyIdRead.none({required this.stillStarting}) : id = null;

  final String? id;
  final bool stillStarting;

  @override
  String toString() => id != null
      ? 'ToyIdRead($id)'
      : 'ToyIdRead(none${stillStarting ? ', still starting' : ''})';
}

// A singleton class to manage BLE connections and data
class BleManager {
  // Legacy device-global persistence keys (pre per-user scoping). Kept only for
  // one-time migration into the uid-scoped keys below — a second account on the
  // same phone must not inherit the first account's saved toy.
  static const String _legacyDeviceIdKey = 'smarty_saved_device_id';
  static const String _legacyDeviceNameKey = 'smarty_saved_device_name';
  static String _deviceIdKeyFor(String uid) => 'smarty_saved_device_id_$uid';
  static String _deviceNameKeyFor(String uid) =>
      'smarty_saved_device_name_$uid';
  // Last Wi-Fi name is per TOY (keyed by its BLE id), so a newly set-up toy
  // never inherits the previous toy's network name. The per-account key it
  // used to live under is migrated once, then removed.
  String _lastWifiKeyFor(String toyId) => 'smarty_last_wifi_toy_$toyId';
  static String _legacyLastWifiKeyFor(String uid) => 'smarty_last_wifi_$uid';
  // Local "linked" record for firmware that can't report `registered`, keyed
  // by the toy's own id (ab06). Same key the setup page has always written.
  static String _registeredRecordKey(String toyDeviceId) =>
      'device_registered_$toyDeviceId';
  // Advert format version last seen for a toy, keyed by its BLE id, so the
  // profile size limit is known while it is connected (a connected toy
  // doesn't advertise). See [userContextMaxBytes].
  static String _advVersionKeyFor(String toyId) => 'toy_adv_ver_$toyId';

  /// Every SharedPreferences key this class keeps for the account [uid] (used
  /// when the account is deleted). Per-toy keys (last Wi-Fi name, advert
  /// version) are not listed: [clearSavedDevice] removes those for the saved
  /// toy.
  static List<String> accountPrefsKeys(String uid) => [
        _deviceIdKeyFor(uid),
        _deviceNameKeyFor(uid),
        _legacyLastWifiKeyFor(uid),
      ];

  // Current Firebase uid, or null when signed out. Firebase.initializeApp is
  // awaited in main() before runApp, so this is safe to read on demand.
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // Singleton instance
  static final BleManager _instance = BleManager._internal();

  // Factory constructor
  factory BleManager() {
    return _instance;
  }

  // Private constructor
  BleManager._internal();

  /// The 16-bit Smarty service every toy advertises (bt_setup.c).
  static final Guid smartyServiceGuid = Guid("abcd");

  /// How long a launch/resume/"Check again" probe scans for the saved toy. A
  /// bonded toy advertises every 160–320 ms, so 3 s is ~10 chances.
  static const Duration probeScanDuration = Duration(seconds: 3);

  /// Timeout for a DIRECT connect once the probe has seen the toy advertise.
  static const Duration directConnectTimeout = Duration(seconds: 10);

  /// How long a toy that isn't linked to an account waits for a phone after
  /// its + and – buttons are held (bt_setup.c). A toy that has never been
  /// paired waits for as long as it is on.
  static const Duration toyPairingWindow = Duration(minutes: 2);

  // Connected device
  BluetoothDevice? _connectedDevice;

  // In-flight initialize() and the device it targets. Concurrent callers for
  // the same device share this future instead of returning before the
  // characteristics are cached.
  Future<void>? _initializeFuture;
  BluetoothDevice? _initializingDevice;

  // ---- Connection-phase state machine (see watchSavedToy) -------------------

  final ValueNotifier<ToyPhase> _phase = ValueNotifier(ToyPhase.probing);

  /// Current [ToyPhase]. Every transition in BleManager goes through here, so
  /// UIs can simply `ValueListenableBuilder` on it.
  ValueListenable<ToyPhase> get phase => _phase;

  // Bumped by forgetToy()/disconnectAndReset(): async steps started under an
  // older generation abandon themselves instead of resurrecting a connection
  // the parent just forgot or signed out of.
  int _sessionGen = 0;

  // Single-flight watchSavedToy(), tagged with the session generation it was
  // started under so a run from before sign-out/sign-in is never reused.
  Future<void>? _watchFuture;
  int _watchGen = -1;

  // BLE id of a saved toy whose pairing is known broken and not yet repaired
  // (set on pairingBroken; cleared by a successful initialize() or
  // forgetToy()). While it matches the toy being watched, "not seen" stays
  // [ToyPhase.pairingBroken] instead of [ToyPhase.notNearby], and no
  // background autoConnect is armed: after the parent resets the toy its
  // bonds are gone, and once its pairing window closes it neither
  // advertises nor accepts stale keys — "it'll connect by itself" would be a
  // dead end. Kept per toy id (not a bare bool) so it survives a sign-out /
  // sign-in of the same toy but never leaks onto another account's toy.
  String? _repairToyId;
  bool _needsRepairFor(BluetoothDevice device) =>
      _repairToyId != null && _repairToyId == device.remoteId.str;


  // Device a direct connect() is in flight for (connectAndInitialize). Lets
  // forgetToy()/disconnectAndReset() cancel it — _connectedDevice is still
  // null at that point.
  BluetoothDevice? _connectingDevice;

  // Launch/resume probe scan ownership (see _probeScan / cancelProbe).
  int _probeToken = 0;
  StreamSubscription<List<ScanResult>>? _probeSub;
  Completer<bool>? _probeFound;

  // The device whose background autoConnect we armed, its connection-state
  // listener, and the backoff re-arm timer after a failed attempt.
  BluetoothDevice? _armedDevice;
  StreamSubscription<BluetoothConnectionState>? _pendingSub;
  Timer? _rearmTimer;
  int _consecutiveFailures = 0;

  // Adapter-state watch: re-runs watchSavedToy when Bluetooth comes back on.
  StreamSubscription<BluetoothAdapterState>? _adapterSub;
  bool _waitingForAdapter = false;

  // Stale-pairing detection (see [LinkDropTracker] and _watchLink): one
  // tracker for the toy we are connecting to / waiting for, fed by a
  // connection-state listener that lives across attempts, so a drop that
  // happens mid-initialize (before _monitorDeviceConnection is attached) or
  // right after a pending connect is counted too — and its reason is read
  // at the moment of the drop, before an OS auto-reconnect replaces it
  // (FBP's disconnectReason is simply the latest state event).
  final LinkDropTracker _drops = LinkDropTracker();
  String? _dropsToyId;
  BluetoothDevice? _linkWatchDevice;
  StreamSubscription<BluetoothConnectionState>? _linkWatchSub;
  // remoteId -> number of disconnect() calls of ours in flight: the drops
  // they cause are ours, not the toy's.
  final Map<String, int> _ownDisconnects = {};

  // Status keep-alive (see _scheduleStatusPoll).
  Timer? _statusPollTimer;
  int _statusPollsLeft = 0;

  /// While connected and the toy's last status is transitional ("Unknown",
  /// "Initializing", "Reconnecting" …), the status is re-read this often, so
  /// the UI never depends on a single notification to leave "Checking…" /
  /// "Joining Wi-Fi…".
  static const Duration statusPollInterval = Duration(seconds: 5);

  /// Upper bound on keep-alive reads per transitional stretch (~3 min).
  static const int statusPollMaxReads = 36;

  // Cached saved toy for the signed-in account (null = none / not loaded).
  String? _savedToyId;
  String? _savedToyName;

  /// BLE id (remoteId string) of this account's saved toy, or null when none
  /// is saved or it hasn't been loaded yet ([watchSavedToy] loads it).
  String? get savedToyId => _savedToyId;

  /// The saved toy's own id (ab06, MAC-derived — the id its cloud records
  /// are filed under, unlike [savedToyId] which is the phone's Bluetooth
  /// handle), once it has been read over Bluetooth this session; else null.
  String? get savedToyDeviceId {
    final String? remote = _connectedDevice?.remoteId.str ?? _savedToyId;
    final String? id = remote == null ? null : _toyDeviceIdByRemote[remote];
    return _idReadable(id) ? id : null;
  }

  /// Display name of the saved (or connected) toy, e.g. "Smarty-AB12", or
  /// null when no toy is saved. Use [toyDisplayName]/[toyCode] to render it.
  String? get savedToyName {
    final live = _connectedDevice?.platformName;
    if (live != null && live.isNotEmpty) return live;
    return _savedToyName;
  }

  /// Parent-facing name for a raw advertised name: "Smarty-AB12" → "Smarty".
  static String toyDisplayName(String? raw) {
    if (raw == null || raw.trim().isEmpty) return 'Smarty';
    final m = RegExp(r'^(smarty)[-_ ]?[0-9a-z]{4}$', caseSensitive: false)
        .firstMatch(raw.trim());
    return m != null ? 'Smarty' : raw.trim();
  }

  /// The 4-character code in "Smarty-AB12" ("AB12"), or null if the name
  /// doesn't carry one. Shown only as small secondary text.
  static String? toyCode(String? raw) {
    if (raw == null) return null;
    final m = RegExp(r'^smarty[-_ ]?([0-9a-z]{4})$', caseSensitive: false)
        .firstMatch(raw.trim());
    return m?.group(1)?.toUpperCase();
  }

  /// Profile (ab03) size on firmware that advertises no version
  /// (CHAR_VAL_LEN_MAX = 500 in older bt_setup.c).
  static const int userContextMaxBytesLegacy = 500;

  /// Profile (ab03) size on firmware whose advert carries `ver` >= 1.
  static const int userContextMaxBytesV1 = 1024;

  /// Profile size a toy with [advert] accepts: [userContextMaxBytesV1] when
  /// its advert version is >= 1, otherwise [userContextMaxBytesLegacy]
  /// (including no advert data at all). Pure.
  static int profileMaxBytesFor(ToyAdvert? advert) =>
      _profileMaxBytesForVersion(advert?.version ?? 0);

  static int _profileMaxBytesForVersion(int version) => version >= 1
      ? userContextMaxBytesV1
      : userContextMaxBytesLegacy;

  /// Largest profile the current (connected, else saved) toy stores, in UTF-8
  /// bytes — from the advert version last seen for it (remembered per toy, so
  /// it holds while connected). Unknown toy or old firmware: the legacy 500.
  /// Writes above the MTU go out as BLE long (prepared) writes, which the
  /// firmware supports, so this is the real limit for user context.
  int get userContextMaxBytes {
    final id = _currentToyId;
    return _profileMaxBytesForVersion(
        id == null ? 0 : (_advVersionByToy[id] ?? 0));
  }

  /// Usable payload for a single acknowledged characteristic write, in UTF-8
  /// bytes. Long writes make this independent of the negotiated MTU.
  int get maxWritePayloadBytes => userContextMaxBytes;

  // Advert version per toy BLE id (mirrors the `toy_adv_ver_<id>` prefs).
  final Map<String, int> _advVersionByToy = {};

  // What each toy advertised when last seen (null = no advert data), by BLE
  // id, for this app session — e.g. whether it is linked, which decides the
  // claim (see [shouldClaim]).
  final Map<String, ToyAdvert?> _advertByToy = {};

  // Latest sighting of the saved toy by the launch/resume probe.
  String? _lastSeenToyId;
  ToyAdvert? _lastSeenAdvert;
  DateTime? _lastSeenAt;

  /// How long a probe sighting counts as "Smarty is on right now".
  static const Duration recentSightingWindow = Duration(seconds: 20);

  /// Advert data from the last time the probe saw this account's saved toy,
  /// or null (not seen, or old firmware that sends none).
  ToyAdvert? get lastSeenAdvert =>
      _lastSeenToyId != null && _lastSeenToyId == _savedToyId
          ? _lastSeenAdvert
          : null;

  /// When the probe last saw this account's saved toy advertising (any
  /// firmware), or null.
  DateTime? get lastSeenAt =>
      _lastSeenToyId != null && _lastSeenToyId == _savedToyId
          ? _lastSeenAt
          : null;

  /// The saved toy was seen advertising within [recentSightingWindow] — it
  /// is on, even if the connect hasn't happened (yet).
  bool get savedToySeenRecently {
    final at = lastSeenAt;
    return at != null &&
        DateTime.now().difference(at) < recentSightingWindow;
  }

  // Probe saw the saved toy: remember when, what it advertised, and its
  // advert version (for [userContextMaxBytes]).
  void _recordSighting(ScanResult r) {
    final id = r.device.remoteId.str;
    final advert = ToyAdvert.fromScanResult(r);
    _lastSeenToyId = id;
    _lastSeenAdvert = advert;
    _lastSeenAt = DateTime.now();
    debugPrint("BleManager: saw saved toy — $advert");
    rememberAdvert(id, advert);
  }

  /// Record what [toyId] just advertised: whether it is linked (in memory —
  /// it decides the claim, see [shouldClaim]) and its advert version (0 for
  /// no advert data; in memory and in SharedPreferences, so
  /// [userContextMaxBytes] is right once that toy is connected). Called by
  /// the probe and by the setup page when the parent picks a toy.
  void rememberAdvert(String toyId, ToyAdvert? advert) {
    _advertByToy[toyId] = advert;
    final int version = advert?.version ?? 0;
    if (_advVersionByToy[toyId] == version) return;
    _advVersionByToy[toyId] = version;
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setInt(_advVersionKeyFor(toyId), version))
        .catchError((Object e) {
      debugPrint("⚠️ BleManager: Couldn't persist advert version: $e");
      return false;
    });
  }

  void _loadAdvVersion(SharedPreferences prefs, String toyId) {
    if (_advVersionByToy.containsKey(toyId)) return;
    final int? v = prefs.getInt(_advVersionKeyFor(toyId));
    if (v != null) _advVersionByToy[toyId] = v;
  }

  // Cached services
  BluetoothService? _smartyService;

  // Cached characteristics
  BluetoothCharacteristic? _statusCharacteristic;
  BluetoothCharacteristic? _wifiScanCharacteristic;
  BluetoothCharacteristic? _wifiCredsCharacteristic;
  BluetoothCharacteristic? _userDataCharacteristic;
  BluetoothCharacteristic? _deviceSecretCharacteristic;
  BluetoothCharacteristic? _deviceInfoCharacteristic;
  // ab07 "Claim", unencrypted: read → a fresh 16-byte nonce; write the
  // account proof ([claimProof]) to be let in.
  BluetoothCharacteristic? _claimCharacteristic;

  // Connection state subscription
  StreamSubscription<BluetoothConnectionState>? _connectionStateSubscription;

  // Status notification subscription
  StreamSubscription<List<int>>? _statusNotificationSubscription;

  // Fires when the peripheral sends a GATT "Service Changed" indication
  // (e.g. after a firmware upgrade; older firmware also sent one right after
  // every new bond). iOS then invalidates the toy's services — including our
  // status subscription — and Android caches services for bonded devices, so
  // we must re-discover and re-subscribe. See [_onServicesReset].
  StreamSubscription<void>? _servicesResetSubscription;
  Timer? _servicesResetDebounce;
  bool _servicesResetRunning = false;
  bool _servicesResetAgain = false;

  // Status information
  String _connectedWifi = "Unknown";
  int _batteryLevel = 0;
  // Whether the toy is linked to this account — a DERIVED value (see
  // [deriveRegistered]): the toy's own status field (`"registered"`) wins;
  // firmware that predates that field falls back to a local record kept per
  // toy id (see [refreshRegistered]); the account check can overrule both.
  // null = unknown (not read yet, or the toy's id couldn't be read).
  final ValueNotifier<bool?> _registered = ValueNotifier(null);
  bool? _statusRegistered; // from the status JSON; null = not reported
  bool? _localRegistered; // local record (old firmware); null = not loaded
  // The connection on which [markRegistered] ran (this app just wrote the
  // toy's secret over it), or null. While it is still the live connection a
  // `"registered":false` status is stale — older firmware only refreshed its
  // status value on a battery/Wi-Fi change, so reads kept returning the
  // pre-link JSON — and must not flip [registered] back. Cleared with the
  // rest of the connection state (disconnect, forgetToy, sign-out).
  BluetoothDevice? _linkedOnConnection;
  Future<void>? _localRegLoad;
  // "Linked" must mean linked to THIS account: the toy's `registered` only
  // says it holds SOME key (maybe another account's, a deleted account's, or
  // a dev emulator's). Once per connection, a toy that counts as linked is
  // checked against the account's records (see [_checkAccount]).
  final LinkCheck _linkCheck = LinkCheckService();
  // The claim (see [shouldClaim]): where claim keys come from; the link the
  // last account proof was written on, when, and which key (by toy id /
  // name) it used; and the link on which something encrypted last worked.
  // Proof and secure marks are cleared when a link is set up afresh.
  ClaimKeys? _claimKeysOverride;
  ClaimKeys get _claimKeys => _claimKeysOverride ?? KnownToysService.instance;
  BluetoothDevice? _provedOn;
  DateTime? _provedAt;
  String? _proofKeyToyId;
  String? _proofKeyToyName;
  BluetoothDevice? _securedOn;

  /// Tests only: where claim keys come from (null = the app's own).
  @visibleForTesting
  set debugClaimKeys(ClaimKeys? keys) => _claimKeysOverride = keys;
  BluetoothDevice? _accountCheckFor; // connection the check belongs to
  Future<void>? _accountCheck; // in flight or finished, for that connection
  bool _accountCheckSettled = false;
  bool? _accountHasToy; // its answer; null = not asked / can't tell
  // ab06 id per BLE id, filled by readDeviceId(). Survives link drops so
  // markRegistered() can write the local record even while reconnecting.
  final Map<String, String> _toyDeviceIdByRemote = {};
  // Last real SSID the toy reported (or we provisioned), so "Auth Failed" can
  // name the network. Persisted per toy; [_lastWifiToyId] is the toy it
  // belongs to.
  String? _lastKnownWifiName;
  String? _lastWifiToyId;

  // Stream controllers for status updates
  final _wifiStatusController = StreamController<String>.broadcast();
  final _batteryStatusController = StreamController<int>.broadcast();
  final _wifiStatusMessageController = StreamController<String>.broadcast();

  // Getters
  BluetoothDevice? get connectedDevice => _connectedDevice;
  BluetoothService? get smartyService => _smartyService;
  String get connectedWifi => _connectedWifi;
  int get batteryLevel => _batteryLevel;

  /// Whether the toy is linked to this account (holds its backend secret).
  /// The toy's status JSON (`"registered"`) wins; for firmware without that
  /// field it comes from a local record kept per toy (written by
  /// [markRegistered]) — `false` when the toy's id is readable but no record
  /// exists. Either way, `false` when the account's records say the toy isn't
  /// on this account (checked once per connection — see [deriveRegistered]).
  /// null = unknown (not read yet, or the id couldn't be read).
  bool? get registered => _registered.value;

  /// Listenable form of [registered] (fires on status updates, when the
  /// local record loads, when the account check answers, and on
  /// [markRegistered]).
  ValueListenable<bool?> get registeredListenable => _registered;

  /// Whether the connected toy is this account's own from before this
  /// connection — see [isAccountToyConfirmed]. Fires when the account check
  /// answers and when the link goes. The child's profile on such a toy is the
  /// account's, so the phone keeps a copy of it (UserContextProvider): the
  /// copy that is sent back to the toy after a reset.
  ValueListenable<bool> get accountToyConfirmed => _accountToyConfirmed;
  final ValueNotifier<bool> _accountToyConfirmed = ValueNotifier(false);

  /// [accountToyConfirmed] from its inputs (pure, for tests): the toy counts
  /// as linked ([registered]) and the account's records list it
  /// ([accountHasToy], the account check on this connection). Never for a
  /// toy this app linked on this connection ([linkedThisConnection]): it was
  /// new, reset or erased, so what it holds isn't the account's profile.
  static bool isAccountToyConfirmed({
    required bool? registered,
    required bool linkedThisConnection,
    required bool? accountHasToy,
  }) =>
      registered == true && !linkedThisConnection && accountHasToy == true;

  /// Same as [registered]; kept for existing callers.
  bool? get deviceRegistered => _registered.value;

  /// [registered] from its inputs (pure, for tests), first match wins:
  /// 1. this app linked the toy on the current connection
  ///    ([linkedThisConnection]) → true (a `false` status is a stale pre-link
  ///    value);
  /// 2. the account's records say the toy isn't on this account
  ///    ([accountHasToy] == false) → false, whatever the toy says — its key
  ///    belongs to someone else (or to nobody any more);
  /// 3. otherwise the toy's status field, else the local record.
  /// [accountHasToy] null (not checked, offline, signed out) changes nothing.
  static bool? deriveRegistered({
    required bool? statusRegistered,
    required bool? localRegistered,
    bool linkedThisConnection = false,
    bool? accountHasToy,
  }) {
    if (linkedThisConnection) return true;
    if (accountHasToy == false) return false;
    return statusRegistered ?? localRegistered;
  }

  /// Whether to start the account check for the connected toy (pure, for
  /// tests). Only with the account link on ([linkingEnabled]), only for a toy
  /// that currently counts as linked ([registered] true — a "not linked" can't
  /// get more "not linked"), never once this app linked it on this connection,
  /// and once per connection ([checkedThisConnection]): an answer of "can't
  /// tell" ([lastAnswerUnknown]) is retried only when a caller asks
  /// ([retryUnknown] — the setup page's link step).
  static bool shouldStartAccountCheck({
    bool linkingEnabled = DevConfig.linkingEnabled,
    required bool? registered,
    required bool linkedThisConnection,
    required bool checkedThisConnection,
    bool lastAnswerUnknown = false,
    bool retryUnknown = false,
  }) {
    if (!linkingEnabled || linkedThisConnection || registered != true) {
      return false;
    }
    if (!checkedThisConnection) return true;
    return retryUnknown && lastAnswerUnknown;
  }

  bool get _linkedThisConnection =>
      _linkedOnConnection != null && _linkedOnConnection == _connectedDevice;

  bool get _accountCheckedThisConnection =>
      _accountCheckFor != null && _accountCheckFor == _connectedDevice;

  void _updateRegistered() {
    final bool? accountHasToy =
        _accountCheckedThisConnection ? _accountHasToy : null;
    _registered.value = deriveRegistered(
      statusRegistered: _statusRegistered,
      localRegistered: _localRegistered,
      linkedThisConnection: _linkedThisConnection,
      accountHasToy: accountHasToy,
    );
    _accountToyConfirmed.value = isAccountToyConfirmed(
      registered: _registered.value,
      linkedThisConnection: _linkedThisConnection,
      accountHasToy: accountHasToy,
    );
    // The toy now counts as linked (status / local record): make sure it is
    // linked to THIS account. Single-flight, once per connection.
    if (_registered.value == true) unawaited(_checkAccount());
  }

  /// Check the connected toy against this account's records (see
  /// [LinkCheck]) when [shouldStartAccountCheck] says so; otherwise return
  /// the check already running / done on this connection (or nothing).
  /// A "not on this account" answer makes [registered] false for the rest of
  /// this connection — Home then offers "Finish setup" and the setup page
  /// runs its link step. "Can't tell" changes nothing.
  Future<void> _checkAccount({bool retryUnknown = false}) {
    final BluetoothDevice? device = _connectedDevice;
    if (device == null) return Future.value();
    final bool checked = _accountCheckedThisConnection && _accountCheck != null;
    if (shouldStartAccountCheck(
      registered: _registered.value,
      linkedThisConnection: _linkedThisConnection,
      checkedThisConnection: checked,
      lastAnswerUnknown: _accountCheckSettled && _accountHasToy == null,
      retryUnknown: retryUnknown,
    )) {
      _accountCheckFor = device;
      _accountHasToy = null;
      _accountCheckSettled = false;
      return _accountCheck = _runAccountCheck(device);
    }
    return checked ? _accountCheck! : Future.value();
  }

  Future<void> _runAccountCheck(BluetoothDevice device) async {
    bool current() =>
        _connectedDevice == device && _accountCheckFor == device;
    try {
      String? id = _toyDeviceIdByRemote[device.remoteId.str];
      if (!_idReadable(id)) id = await readDeviceId();
      if (!current()) return;
      if (!_idReadable(id)) {
        debugPrint("⚠️ BleManager: account check skipped (no toy id)");
        return;
      }
      final bool? onAccount = await _linkCheck.isLinkedToThisAccount(id!);
      if (!current()) return;
      _accountHasToy = onAccount;
      if (onAccount == false && !_linkedThisConnection) {
        debugPrint("🔗 BleManager: toy $id is not linked to this account — "
            "setup must link it (toy says registered: $_statusRegistered)");
      }
      _updateRegistered();
    } catch (e) {
      debugPrint("⚠️ BleManager: account check failed: $e");
    } finally {
      if (_accountCheckFor == device) _accountCheckSettled = true;
    }
  }

  void _clearAccountCheck() {
    _accountCheckFor = null;
    _accountCheck = null;
    _accountCheckSettled = false;
    _accountHasToy = null;
  }

  /// Call after a successful device-secret write: flip the flag ourselves
  /// (older firmware doesn't re-notify status on that write, and its status
  /// value keeps saying `"registered":false` until something else changes),
  /// and keep the local record (used by firmware that can't report the flag).
  /// For the rest of this connection a `"registered":false` status is ignored.
  void markRegistered() {
    if (_statusRegistered != null) _statusRegistered = true;
    _localRegistered = true;
    _linkedOnConnection = _connectedDevice;
    _updateRegistered();
    unawaited(_persistRegistered());
  }

  Future<void> _persistRegistered() async {
    final String? remote = _connectedDevice?.remoteId.str ?? _savedToyId;
    String? id = remote == null ? null : _toyDeviceIdByRemote[remote];
    if (!_idReadable(id) && _connectedDevice != null) {
      id = await readDeviceId();
    }
    if (!_idReadable(id)) {
      debugPrint("⚠️ BleManager: couldn't record the link locally (no toy id)");
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_registeredRecordKey(id!), true);
    } catch (e) {
      debugPrint("⚠️ BleManager: couldn't persist the link record: $e");
    }
  }

  static bool _idReadable(String? id) =>
      id != null && id.trim().isNotEmpty && id != '{}';

  /// Make [registered] as definite as possible for the connected toy and
  /// return it: reads the status if the toy hasn't reported yet, for
  /// firmware without the `registered` field loads the local record keyed by
  /// the toy's id, and — when that says "linked" — waits for the check that
  /// it is linked to THIS account (≤ ~5 s; retried here if it couldn't tell
  /// earlier on this connection). Returns null if it still can't tell (or
  /// nothing is connected).
  Future<bool?> refreshRegistered() async {
    final device = _connectedDevice;
    if (device == null) return _registered.value;
    if (_statusRegistered == null) {
      await readStatusUpdate();
    }
    if (_connectedDevice != device) return _registered.value;
    if (_statusRegistered == null) {
      await (_localRegLoad ??= _loadLocalRegistered(device)
          .whenComplete(() => _localRegLoad = null));
      if (_connectedDevice != device) return _registered.value;
    }
    await _checkAccount(retryUnknown: true);
    return _registered.value;
  }

  Future<void> _loadLocalRegistered(BluetoothDevice device) async {
    if (_localRegistered != null) return;
    String? id = _toyDeviceIdByRemote[device.remoteId.str];
    // readDeviceId re-reads while the id is still empty (~3 s at most).
    if (!_idReadable(id)) {
      id = await readDeviceId();
      if (_connectedDevice != device || _statusRegistered != null) return;
    }
    if (!_idReadable(id)) return; // can't tell — stays unknown
    final bool linked;
    try {
      final prefs = await SharedPreferences.getInstance();
      linked = prefs.getBool(_registeredRecordKey(id!)) ?? false;
    } catch (e) {
      debugPrint("⚠️ BleManager: couldn't read the link record: $e");
      return;
    }
    if (_connectedDevice != device || _localRegistered != null) return;
    _localRegistered = linked;
    _updateRegistered();
  }

  String? get _currentToyId => _connectedDevice?.remoteId.str ?? _savedToyId;

  /// Last real Wi-Fi network name the current toy reported or was given, or
  /// null. Never another toy's.
  String? get lastKnownWifiName =>
      _lastWifiToyId != null && _lastWifiToyId == _currentToyId
          ? _lastKnownWifiName
          : null;

  Stream<String> get wifiStatusStream => _wifiStatusController.stream;
  Stream<int> get batteryStatusStream => _batteryStatusController.stream;
  Stream<String> get wifiStatusMessageStream =>
      _wifiStatusMessageController.stream;
  bool get isConnected => _connectedDevice != null;
  // Non-connected statuses from ESP32 (wifi_config.c) and Flutter internals
  static const _nonConnectedStatuses = {
    '', 'Unknown', 'NotConnected', 'Initializing',
    'Auth Failed', 'Connection Failed', 'No credentials', 'Reconnecting',
  };
  bool get isWifiConnected => isWifiConnectedStatus(_connectedWifi);

  /// Whether a raw `wifi` status value means "joined a network" (a real SSID
  /// rather than a status token). Pure.
  static bool isWifiConnectedStatus(String wifi) =>
      wifi.trim().isNotEmpty &&
      !_nonConnectedStatuses.contains(wifi) &&
      !wifi.contains('Failed');

  void _setPhase(ToyPhase next) {
    if (_phase.value == next) return;
    debugPrint("🧭 BleManager: phase ${_phase.value.name} → ${next.name}");
    _phase.value = next;
  }

  /// Initialize the manager with an already-connected [device]: discover the
  /// Smarty service, cache characteristics, and start status/connection
  /// monitoring.
  ///
  /// Contract: completes normally only when the required characteristics are
  /// cached; [phase] is then [ToyPhase.connected] and the device is saved as
  /// this account's toy. On failure it throws a [ConnectException] (kind from
  /// [classifyConnectError] — e.g. [ConnectFailure.notSmarty] when the Smarty
  /// service is missing, [ConnectFailure.pairingBroken] for a stale bond),
  /// disconnects the link, resets the manager state, and has already moved
  /// [phase] to the matching recovery state (pairingBroken / bluetoothOff /
  /// needsPermission / notNearby with a background reconnect armed, or noToy).
  /// Concurrent calls for the same device share one attempt; a call for a
  /// different device waits for the in-flight attempt to settle first. If a
  /// different toy is currently connected, its link is dropped first (it
  /// would otherwise stay connected with nobody listening).
  Future<void> initialize(BluetoothDevice device) =>
      _initialize(device, _sessionGen);

  // [gen] is the CALLER's session generation (e.g. taken before its
  // connect()), so a sign-out/forget during the caller's own awaits aborts
  // this attempt too.
  Future<void> _initialize(BluetoothDevice device, int gen) {
    final inFlight = _initializeFuture;
    if (inFlight != null) {
      if (_initializingDevice == device) return inFlight;
      return inFlight
          .catchError((_) {})
          .then((_) => _initialize(device, gen));
    }

    // Already fully initialized with this device (characteristics cached).
    if (_connectedDevice == device && _statusCharacteristic != null) {
      return Future.value();
    }

    _initializingDevice = device;
    return _initializeFuture = _initializeImpl(device, gen).whenComplete(() {
      _initializeFuture = null;
      _initializingDevice = null;
    });
  }

  Future<void> _initializeImpl(BluetoothDevice device, int gen) async {
    if (gen != _sessionGen) {
      // Forgotten / signed out before we even started: drop the caller's link
      // (unless it's somehow the live one) and don't touch shared state.
      if (_connectedDevice?.remoteId != device.remoteId) {
        try {
          await _disconnectOwn(device);
        } catch (_) {}
      }
      throw const ConnectException(ConnectFailure.cancelledByUser);
    }
    _watchLink(device);
    if (device.isConnected) _noteLinkUp(device);
    // A link being set up afresh: nothing proved or encrypted on it yet.
    if (_provedOn == device) _provedOn = null;
    if (_securedOn == device) _securedOn = null;
    _setPhase(ToyPhase.connecting);

    // Switching toys: drop the previous toy's link first. Reset FIRST so its
    // connection listener can't treat our own disconnect as a link loss (and
    // re-arm a reconnect to it).
    final old = _connectedDevice;
    if (old != null && old.remoteId != device.remoteId) {
      debugPrint("BleManager: switching toys — disconnecting ${old.remoteId.str}");
      _resetConnectionState();
      try {
        await _disconnectOwn(old);
      } catch (e) {
        debugPrint("⚠️ BleManager: Disconnecting previous toy failed: $e");
      }
    }

    // A background connect armed for a DIFFERENT toy (e.g. the parent is
    // setting up a new Smarty) must not hijack the link later.
    final armed = _armedDevice;
    if (armed != null && armed != device) {
      await _cancelPendingConnect(switchingTo: device);
    }

    try {
      _connectedDevice = device;
      _connectedWifi = "Unknown";
      // Listen for "services changed" BEFORE discovering: the toy's
      // indication can arrive while discovery / the first subscribe (which
      // triggers pairing) is still in flight, and a reset we didn't hear
      // leaves the app with dead characteristics and no status updates.
      _servicesResetSubscription?.cancel();
      _servicesResetSubscription =
          device.onServicesReset.listen((_) => _onServicesReset(device, gen));
      // Fresh link: registration is re-learned from this toy's status (or
      // its local record) and the account check — never carried over from
      // before.
      _statusRegistered = null;
      _localRegistered = null;
      _clearAccountCheck();
      _updateRegistered();
      debugPrint("🔄 BleManager: Initializing with device: ${device.platformName}");

      // Request larger MTU for WiFi scan chunks, JSON status notifications
      // and the 32-byte account proof. Android only — requestMtu always
      // throws on iOS, which negotiates the MTU itself. A failure here is not
      // fatal: long writes still work (the toy takes them for the proof too).
      if (Platform.isAndroid) {
        try {
          await device.requestMtu(512);
          debugPrint("✅ BleManager: MTU negotiated");
        } catch (e) {
          debugPrint("⚠️ BleManager: MTU request failed: $e");
        }
      }

      // Discover services (unencrypted).
      bool servicesReady = await _discoverServices();

      if (!servicesReady) {
        if (device.isDisconnected) {
          // The link died under discovery — not a "wrong device" verdict.
          throw StateError('Link dropped during service discovery');
        }
        debugPrint("❌ BleManager: Service discovery failed — required services/characteristics not found");
        throw const ConnectException(ConnectFailure.notSmarty);
      }

      // Prove this phone is on the toy's account BEFORE anything encrypted —
      // no status read, no subscription, no device-id read, no bonding: a
      // linked toy refuses to pair with (and drops) a phone it doesn't know
      // that hasn't proved that. Skipped when there is no key at hand; a
      // phone the toy already knows gets in without it.
      await _claim(device);

      // Trigger bonding on Android (prevents double pairing popup bug) —
      // after the proof, see above. iOS handles bonding automatically when
      // encrypted characteristics are accessed (a toy that took the proof
      // also asks for it itself).
      if (Platform.isAndroid) {
        try {
          await device.createBond();
          debugPrint("BleManager: Bond created/confirmed on Android");
        } catch (e) {
          debugPrint("BleManager: Bond creation skipped (may already be bonded): $e");
        }
      }

      // Enable status notifications and WAIT for the result: the firmware
      // starts encryption right after connect, so a stale pairing surfaces
      // here (insufficient authentication/encryption) rather than as a silent
      // background failure. Other errors stay non-fatal, as before — e.g. a
      // slow first-time pairing prompt must not abort setup.
      try {
        await _subscribeStatus(_statusCharacteristic!);
        _noteLinkSecured(device);
      } catch (e) {
        if (classifyConnectError(e) == ConnectFailure.pairingBroken) rethrow;
        debugPrint("⚠️ BleManager: Enabling status notifications failed (non-fatal): $e");
      }
      _setupStatusUpdates();

      if (device.isDisconnected) {
        throw StateError('Link dropped during setup');
      }

      // Set up connection state monitoring
      _monitorDeviceConnection();

      if (gen != _sessionGen) {
        // Forgotten / signed out while we were setting up — and don't re-save
        // the toy the parent just forgot.
        throw const ConnectException(ConnectFailure.cancelledByUser);
      }

      // Persist device ID for auto-reconnect on next app launch
      try {
        await _saveDeviceId(device);
      } catch (e) {
        debugPrint("⚠️ BleManager: Failed to save device for auto-reconnect: $e");
      }

      _consecutiveFailures = 0;
      _repairToyId = null; // the pairing works again
      _rearmTimer?.cancel();
      _setPhase(ToyPhase.connected);

      // First status read (notifications only carry changes). With the
      // account link on, also settle [registered] for firmware that can't
      // report it (local record by toy id), and check that a toy that says
      // it's linked is linked to THIS account.
      unawaited(DevConfig.linkingEnabled
          ? refreshRegistered().then((_) {})
          : readStatusUpdate());
      // And keep re-reading while the status is still transitional: right
      // after a toy reboot it reports "Initializing", and the screens must
      // not hang on that if the Wi-Fi notification that follows is lost.
      _startStatusPoll();
    } catch (e) {
      // Classify BEFORE our own disconnect overwrites the disconnect reason.
      final DisconnectReason? reason =
          device.isDisconnected ? device.disconnectReason : null;
      final bool staleBond = isStaleBondEvidence(e, reason);
      ConnectException failure;
      if (e is ConnectException) {
        failure = e;
      } else {
        final kind = _classifyForDevice(e, device);
        failure = ConnectException(
            kind, e, kind == ConnectFailure.pairingBroken && staleBond);
      }
      // The claim decides some drops: the toy hangs up at once on a wrong
      // proof, and on a phone that touched it encrypted without one.
      final ConnectFailure? claimVerdict = _claimVerdict(device, failure);
      if (claimVerdict == ConnectFailure.notYourAccount) {
        _forgetClaimKeyOf(device);
      }
      if (claimVerdict != null) {
        failure = ConnectException(claimVerdict, e, false);
      }
      debugPrint("❌ BleManager: initialize failed (${failure.kind.name}): $e");
      // Reset FIRST so the intentional disconnect below can't fire the
      // disconnect handler, then drop the link so a half-initialized device
      // isn't left connected. (disconnect() also clears a pending autoConnect;
      // _onConnectFailure re-arms it with backoff when appropriate.)
      _resetConnectionState();
      try {
        await _disconnectOwn(device);
      } catch (de) {
        debugPrint("⚠️ BleManager: Disconnect after failed initialize: $de");
      }
      // The link watcher may have judged the pairing broken meanwhile (its
      // view of the drop can land after ours) — report it as such.
      if (failure.kind != ConnectFailure.pairingBroken &&
          failure.kind != ConnectFailure.cancelledByUser &&
          failure.kind != ConnectFailure.notYourAccount &&
          _needsRepairFor(device)) {
        failure = ConnectException(ConnectFailure.pairingBroken, e, staleBond);
      }
      if (_armedDevice == device) {
        _pendingSub?.cancel();
        _pendingSub = null;
        _armedDevice = null;
      }
      if (gen == _sessionGen) {
        await _onConnectFailure(device, failure);
      }
      throw failure;
    }
  }

  // ---- The claim: proving this phone is on the toy's account ---------------

  /// How long to wait for the claim key (this phone's copy, else the
  /// account's records) before going on without the proof.
  static const Duration claimKeyTimeout = Duration(seconds: 6);

  /// The toy hangs up at once on a wrong proof: a link that goes down this
  /// soon after the proof was written means the proof was turned down.
  static const Duration claimRejectWindow = Duration(seconds: 3);

  /// Whether to prove the account to a toy before touching anything
  /// encrypted (pure): the toy has the claim characteristic (ab07) and
  /// doesn't say it is unlinked ([advertRegistered] true, or not known —
  /// e.g. a background reconnect without a fresh sighting). A linked toy
  /// only lets a phone pair once it has proved it is on the toy's account
  /// (reading a fresh nonce, writing [claimProof] of it); a phone it already
  /// knows gets in without. The key is looked up only when this says so,
  /// and without one the proof is skipped.
  static bool shouldClaim({
    required bool hasClaimCharacteristic,
    required bool? advertRegistered,
  }) =>
      hasClaimCharacteristic && advertRegistered != false;

  /// What the claim says about a failed connect (pure), or null when it
  /// says nothing (the failure stands):
  /// - [ConnectFailure.notYourAccount] when [failure] already is (the proof
  ///   write failed), or when the link went down ([linkDown]) within
  ///   [claimRejectWindow] after the proof ([sinceProof]; null = no proof on
  ///   this link) — the toy hangs up at once on a wrong proof.
  /// - [ConnectFailure.pairingBroken] (a refused pairing, not a stale one)
  ///   when the toy said it is linked ([advertRegistered]), no proof went to
  ///   it on this link, nothing encrypted worked ([secured] false) and the
  ///   link went down — the toy drops a phone it doesn't know that touches
  ///   it encrypted without a proof — replacing a failure that says less
  ///   ([ConnectFailure.unknown] / [ConnectFailure.outOfRange]).
  /// Never for a cancel, the Bluetooth states or a toy that isn't a Smarty.
  static ConnectFailure? claimVerdictFor({
    required ConnectFailure failure,
    required bool linkDown,
    Duration? sinceProof,
    bool secured = false,
    bool? advertRegistered,
  }) {
    switch (failure) {
      case ConnectFailure.notYourAccount:
        return ConnectFailure.notYourAccount;
      case ConnectFailure.cancelledByUser:
      case ConnectFailure.bluetoothOff:
      case ConnectFailure.needsPermission:
      case ConnectFailure.notSmarty:
        return null;
      default:
        break;
    }
    if (!linkDown) return null;
    if (sinceProof != null) {
      return sinceProof <= claimRejectWindow
          ? ConnectFailure.notYourAccount
          : null;
    }
    if (!secured &&
        advertRegistered == true &&
        (failure == ConnectFailure.unknown ||
            failure == ConnectFailure.outOfRange)) {
      return ConnectFailure.pairingBroken;
    }
    return null;
  }

  // [claimVerdictFor] for a failed initialize of [device].
  ConnectFailure? _claimVerdict(BluetoothDevice device, ConnectException f) {
    final DateTime? at = _provedOn == device ? _provedAt : null;
    return claimVerdictFor(
      failure: f.kind,
      linkDown: device.isDisconnected,
      sinceProof: at == null ? null : DateTime.now().difference(at),
      secured: _securedOn == device,
      advertRegistered: _advertByToy[device.remoteId.str]?.registered,
    );
  }

  // The proof on [device] was just written and the link is going down: the
  // toy turned it down (the drop is its verdict, not a stale pairing).
  bool _justProved(BluetoothDevice device) {
    final DateTime? at = _provedOn == device ? _provedAt : null;
    return at != null && DateTime.now().difference(at) <= claimRejectWindow;
  }

  // The name [device] goes by over Bluetooth ("Smarty-B11E"), for finding
  // its claim key before anything encrypted (its id, ab06, is encrypted).
  String? _nameOf(BluetoothDevice device) {
    for (final String n in [device.advName, device.platformName]) {
      if (n.trim().isNotEmpty) return n.trim();
    }
    return device.remoteId.str == _savedToyId ? _savedToyName : null;
  }

  // Prove the account to [device] when [shouldClaim] says so and a key is at
  // hand: read the nonce (ab07, unencrypted, fresh per connection), write
  // [claimProof] of it back with a response. Throws
  // ConnectException(notYourAccount) when the toy turns the proof down;
  // anything else here just leaves the proof out.
  Future<void> _claim(BluetoothDevice device) async {
    final BluetoothCharacteristic? c = _claimCharacteristic;
    final String remote = device.remoteId.str;
    if (c == null ||
        !shouldClaim(
          hasClaimCharacteristic: true,
          advertRegistered: _advertByToy[remote]?.registered,
        )) {
      return;
    }
    final String? known = _toyDeviceIdByRemote[remote];
    final String? deviceId = _idReadable(known) ? known : null;
    final String? name = _nameOf(device);
    String? key;
    try {
      key = await _claimKeys
          .claimKeyFor(deviceId: deviceId, bleName: name)
          .timeout(claimKeyTimeout, onTimeout: () => null);
    } catch (e) {
      debugPrint("⚠️ BleManager: claim key look-up failed: $e");
    }
    if (key == null || !isClaimKey(key)) {
      debugPrint("BleManager: no claim key for ${name ?? remote} — "
          "connecting without the account proof");
      return;
    }
    final List<int> nonce;
    try {
      nonce = await c.read();
    } catch (e) {
      // The steps that follow find out whether the link is still up.
      debugPrint("⚠️ BleManager: reading the claim nonce failed: $e");
      return;
    }
    if (nonce.length != claimNonceLength) {
      debugPrint("⚠️ BleManager: claim nonce is ${nonce.length} bytes — "
          "connecting without the account proof");
      return;
    }
    _provedOn = device;
    _provedAt = DateTime.now();
    _proofKeyToyId = deviceId;
    _proofKeyToyName = name;
    try {
      await c.write(claimProof(key, nonce),
          withoutResponse: false, allowLongWrite: true);
    } catch (e) {
      debugPrint("❌ BleManager: the toy turned the account proof down: $e");
      throw ConnectException(ConnectFailure.notYourAccount, e);
    }
    _noteLinkProved(device);
    debugPrint("✅ BleManager: account proof sent");
  }

  // The toy turned down the proof made with this key: drop it, so Try
  // again reads the account's records afresh (e.g. the toy was linked again
  // since, with a new secret).
  void _forgetClaimKeyOf(BluetoothDevice device) {
    if (_provedOn != device) return;
    final String? id = _proofKeyToyId;
    unawaited(_claimKeys
        .forgetClaimKey(deviceId: id, bleName: id == null ? _proofKeyToyName : null)
        .catchError((Object e) {
      debugPrint("⚠️ BleManager: dropping the claim key failed: $e");
    }));
  }

  /// The toy said its GATT table changed (Service Changed). Debounced: iOS
  /// can report it more than once in a row.
  void _onServicesReset(BluetoothDevice device, int gen) {
    debugPrint("🔄 BleManager: services reset by the toy — will re-discover");
    _servicesResetDebounce?.cancel();
    _servicesResetDebounce = Timer(const Duration(milliseconds: 400), () {
      unawaited(_recoverFromServicesReset(device, gen));
    });
  }

  /// Re-discover services, re-cache characteristics, re-enable status
  /// notifications and re-read the status after a services reset. Only for
  /// the same toy and session it was armed for; a reset that arrives while
  /// this runs triggers one more pass.
  Future<void> _recoverFromServicesReset(BluetoothDevice device, int gen) async {
    bool stale() =>
        gen != _sessionGen ||
        _connectedDevice?.remoteId != device.remoteId ||
        device.isDisconnected;
    if (stale()) return;
    if (_servicesResetRunning) {
      _servicesResetAgain = true;
      return;
    }
    _servicesResetRunning = true;
    try {
      do {
        _servicesResetAgain = false;
        // Let an initialize() that is still running finish first (it does
        // its own discovery); then redo the parts the reset invalidated.
        final inFlight = _initializeFuture;
        if (inFlight != null) {
          try {
            await inFlight;
          } catch (_) {}
        }
        if (stale()) return;

        final bool ok = await _discoverServices();
        if (stale()) return;
        if (!ok || _statusCharacteristic == null) {
          debugPrint("⚠️ BleManager: re-discovery after services reset found no status characteristic");
          continue;
        }
        // Always re-subscribe: FBP's isNotifying reads a cached CCCD value
        // that survives the reset, but iOS dropped the subscription.
        try {
          await _subscribeStatus(_statusCharacteristic!);
        } catch (e) {
          debugPrint("⚠️ BleManager: re-enabling status notifications after services reset failed: $e");
        }
        if (stale()) return;
        _setupStatusUpdates();
        await readStatusUpdate();
        debugPrint("✅ BleManager: recovered from services reset");
      } while (_servicesResetAgain && !stale());
    } finally {
      _servicesResetRunning = false;
    }
  }

  // Monitor device connection state
  void _monitorDeviceConnection() {
    final device = _connectedDevice;
    if (device == null) return;

    // Cancel any previous subscription to avoid listener accumulation
    _connectionStateSubscription?.cancel();

    _connectionStateSubscription = device.connectionState.listen((BluetoothConnectionState state) {
      debugPrint("💡 Device connection state changed: $state");

      if (state == BluetoothConnectionState.connected) {
        // When connected, ensure notifications are set up
        if (_statusCharacteristic != null) {
          _setupNotificationsIfNeeded();
        }
      } else if (state == BluetoothConnectionState.disconnected) {
        debugPrint("❌ Device disconnected from BLE manager");

        // Reset the device and service references
        _resetConnectionState();

        // Notify listeners about the disconnection (Wi-Fi pages resolve
        // pending waits on this). No snackbar: Home/Settings update in place
        // from [phase].
        _wifiStatusController.add("NotConnected");
        _wifiStatusMessageController.add("Device disconnected");

        unawaited(_onLinkLost(device));
      }
    });
  }

  // Reset the connection state when device is disconnected
  void _resetConnectionState() {
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _statusNotificationSubscription?.cancel();
    _statusNotificationSubscription = null;
    _servicesResetSubscription?.cancel();
    _servicesResetSubscription = null;
    _servicesResetDebounce?.cancel();
    _servicesResetDebounce = null;
    _statusPollTimer?.cancel();
    _statusPollTimer = null;
    _statusPollsLeft = 0;
    _smartyService = null;
    _statusCharacteristic = null;
    _wifiScanCharacteristic = null;
    _wifiCredsCharacteristic = null;
    _userDataCharacteristic = null;
    _deviceSecretCharacteristic = null;
    _deviceInfoCharacteristic = null;
    _claimCharacteristic = null;
    _connectedWifi = "NotConnected";
    _statusRegistered = null;
    _localRegistered = null;
    _linkedOnConnection = null;
    _clearAccountCheck();
    _registered.value = null;
    _accountToyConfirmed.value = false;
    _connectedDevice = null;
  }

  // Discover services and cache characteristics. Returns false if required
  // service or characteristics are missing.
  Future<bool> _discoverServices() async {
    if (_connectedDevice == null) return false;

    try {
      List<BluetoothService> services =
          await _connectedDevice!.discoverServices();
      _smartyService = BleService.findSmartyService(services);

      if (_smartyService == null) {
        debugPrint("❌ BleManager: Smarty service not found among ${services.length} services");
        return false;
      }

      // Cache characteristics
      _statusCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab04",
      );
      _wifiScanCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab01",
      );
      _wifiCredsCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab02",
      );
      _userDataCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab03",
      );
      _deviceSecretCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab05",
      );
      _deviceInfoCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab06",
      );
      _claimCharacteristic = BleService.findCharacteristic(
        _smartyService!,
        "ab07",
      );

      debugPrint("📋 BleManager: Characteristics — "
          "status=${_statusCharacteristic != null ? 'OK' : 'MISSING'}, "
          "wifiScan=${_wifiScanCharacteristic != null ? 'OK' : 'MISSING'}, "
          "wifiCreds=${_wifiCredsCharacteristic != null ? 'OK' : 'MISSING'}, "
          "userData=${_userDataCharacteristic != null ? 'OK' : 'MISSING'}, "
          "deviceSecret=${_deviceSecretCharacteristic != null ? 'OK' : 'MISSING'}, "
          "deviceInfo=${_deviceInfoCharacteristic != null ? 'OK' : 'MISSING'}, "
          "claim=${_claimCharacteristic != null ? 'OK' : 'MISSING'}");

      // Require at least the status characteristic
      if (_statusCharacteristic == null) {
        debugPrint("❌ BleManager: Required status characteristic (ab04) not found");
        return false;
      }

      return true;
    } catch (e) {
      debugPrint("❌ BleManager: Error discovering services: $e");
      return false;
    }
  }

  // Set up status updates
  void _setupStatusUpdates() {
    if (_statusCharacteristic == null) return;

    try {
      // Enable notifications (initialize() normally already did, awaited)
      if (!_statusCharacteristic!.isNotifying) {
        _statusCharacteristic!.setNotifyValue(true).catchError((Object e) {
          debugPrint("❌ BleManager: Error enabling status notifications: $e");
          return false;
        });
      }

      // Cancel previous subscription to avoid accumulation
      _statusNotificationSubscription?.cancel();

      // Variables for debouncing
      String lastStatusString = "";
      DateTime lastUpdateTime = DateTime.now();

      // Listen for notifications
      _statusNotificationSubscription = _statusCharacteristic!.lastValueStream.listen(
        (value) {
          if (value.isEmpty) return;

          String statusString = utf8.decode(value, allowMalformed: true);

          // Debounce: Skip if this is the same status string received within the last 500ms
          if (statusString == lastStatusString &&
              DateTime.now().difference(lastUpdateTime).inMilliseconds < 500) {
            return;
          }

          // Update debounce tracking
          lastStatusString = statusString;
          lastUpdateTime = DateTime.now();

          debugPrint("📊 BleManager: Status notification received: $statusString");

          // Process status data
          _processStatusData(value);
        },
        onError: (error) {
          debugPrint("❌ BleManager: Status notification stream error: $error");
          _statusNotificationSubscription = null;
        },
        onDone: () {
          _statusNotificationSubscription = null;
        },
      );

      // Notifications will emit the current value automatically — no explicit read needed
    } catch (e) {
      debugPrint("❌ BleManager: Error setting up status updates: $e");
    }
  }

  // Read status update from the device
  Future<void> readStatusUpdate() async {
    if (_statusCharacteristic == null) {
      debugPrint("⚠️ BleManager: Status characteristic not available");
      return;
    }
    
    try {
      debugPrint("📡 BleManager: Reading status update...");
      
      // Set up notifications if needed
      await _setupNotificationsIfNeeded();
      
      // Read the characteristic value
      List<int> data = await _statusCharacteristic!.read();
      
      if (data.isEmpty) {
        // debugPrint("⚠️ BleManager: Status update empty, retrying...");
        
        // Wait a bit and try again
        await Future.delayed(Duration(milliseconds: 300));
        data = await _statusCharacteristic!.read();
        
        if (data.isEmpty) {
          // debugPrint("⚠️ BleManager: Status update still empty, retrying again...");
          
          // Try one more time
          await Future.delayed(Duration(milliseconds: 500));
          data = await _statusCharacteristic!.read();
          
          if (data.isEmpty) {
            debugPrint("⚠️ BleManager: Status update still empty after retries");
            return;
          }
        }
      }
      
      // The status is encrypted: reading it means the phone is paired.
      final BluetoothDevice? live = _connectedDevice;
      if (live != null) _noteLinkSecured(live);

      // Process the data
      await _processStatusData(data);
      
    } catch (e) {
      debugPrint("❌ BleManager: Error reading status update: $e");
    }
  }
  
  // Helper method to set up notifications if not already set up
  Future<bool> _setupNotificationsIfNeeded() async {
    if (_statusCharacteristic == null) return false;
    
    try {
      // Check if notifications are already set up
      if (!_statusCharacteristic!.isNotifying) {
        // Enable notifications
        await _subscribeStatus(_statusCharacteristic!);
        // debugPrint("✅ BleManager: Status notifications set up");
      }
      return true;
    } catch (e) {
      debugPrint("❌ BleManager: Error setting up status notifications: $e");
      return false;
    }
  }
  
  /// Status values that are not a settled answer yet: nothing heard, the
  /// link just dropped, or the toy is (re)joining Wi-Fi. While the toy's last
  /// status is one of these, [BleManager] keeps re-reading it. Pure.
  static bool isStatusTransitional(String wifi) {
    final String s = wifi.trim();
    return s.isEmpty ||
        s == 'Unknown' ||
        s == 'NotConnected' ||
        s == 'Initializing' ||
        s == 'Reconnecting';
  }

  // Enable status notifications with a bounded wait. If the platform never
  // answers (FBP timeout) — seen on iOS when CoreBluetooth believes the
  // characteristic is already subscribed and so writes nothing, while the
  // freshly booted toy has notifications off (bt_setup.c only notifies after
  // a CCCD write on the current link) — force a real CCCD write by turning it
  // off and on again. Other errors propagate for the caller to classify.
  Future<void> _subscribeStatus(BluetoothCharacteristic c) async {
    try {
      await c.setNotifyValue(true, timeout: 8);
      return;
    } on FlutterBluePlusException catch (e) {
      final bool timedOut = e.platform == ErrorPlatform.fbp &&
          e.code == FbpErrorCode.timeout.index;
      if (!timedOut || c.device.isDisconnected) rethrow;
      debugPrint("⚠️ BleManager: status subscribe got no answer — re-subscribing");
    }
    try {
      await c.setNotifyValue(false, timeout: 4);
    } catch (e) {
      debugPrint("BleManager: status unsubscribe (before re-subscribe) failed: $e");
    }
    await c.setNotifyValue(true, timeout: 8);
  }

  // Status keep-alive: while connected and the last status is transitional,
  // re-read it every [statusPollInterval] (at most [statusPollMaxReads]
  // times). Notifications stay the fast path; this only guarantees that a
  // lost or never-subscribed notification can't leave the UI on "Checking…"
  // / "Joining Wi-Fi…" for good.
  void _startStatusPoll() {
    _statusPollsLeft = statusPollMaxReads;
    _scheduleStatusPoll();
  }

  void _scheduleStatusPoll() {
    _statusPollTimer?.cancel();
    _statusPollTimer = null;
    final BluetoothDevice? device = _connectedDevice;
    if (device == null ||
        _statusCharacteristic == null ||
        _statusPollsLeft <= 0 ||
        !isStatusTransitional(_connectedWifi)) {
      return;
    }
    _statusPollTimer = Timer(statusPollInterval, () async {
      if (_connectedDevice != device) return;
      _statusPollsLeft--;
      await readStatusUpdate();
      if (_connectedDevice == device) _scheduleStatusPoll();
    });
  }

  // Apply one status value (notification or read) from the toy.
  Future<void> _processStatusData(List<int> data) async {
    if (data.isEmpty) return;

    final String statusString = utf8.decode(data, allowMalformed: true);
    debugPrint("📱 BleManager: Received status update: $statusString");

    final ToyStatus? status = ToyStatus.parse(statusString);
    if (status == null) {
      debugPrint("⚠️ BleManager: Unrecognised status value, ignored: $statusString");
      return;
    }

    // "registered" BEFORE the Wi-Fi event, so listeners that rebuild on it
    // read a consistent snapshot.
    if (status.registered == false && _linkedThisConnection) {
      // Stale: we wrote this toy's secret on this very connection (see
      // [markRegistered]); older firmware keeps serving its pre-link status.
      debugPrint("📱 BleManager: ignoring stale registered:false (linked on this connection)");
    } else if (status.registered != null) {
      _statusRegistered = status.registered;
      _updateRegistered();
    }

    final String? wifiName = status.wifi;
    if (wifiName != null) {
      final bool wasTransitional = isStatusTransitional(_connectedWifi);
      _connectedWifi = wifiName;
      // Settled -> transitional again (e.g. the toy lost its Wi-Fi and is
      // rejoining): keep an eye on it with a fresh read budget.
      if (!wasTransitional && isStatusTransitional(wifiName)) {
        _startStatusPoll();
      }
      _rememberWifiName(wifiName);
      _wifiStatusController.add(wifiName);
      _wifiStatusMessageController.add(WifiUtils.getWifiStatusMessage(wifiName));
    }

    if (status.battery != null) {
      _batteryLevel = status.battery!;
      _batteryStatusController.add(_batteryLevel);
    }
  }

  /// Tests only: apply a raw status value ([raw], e.g.
  /// `{"wifi":"HomeNet","registered":false}`) as if Smarty had sent it.
  @visibleForTesting
  Future<void> debugApplyStatus(String raw) =>
      _processStatusData(utf8.encode(raw));

  /// Tests only: forget whatever [debugApplyStatus] set (no Wi-Fi status, no
  /// "registered"), as after a disconnect.
  @visibleForTesting
  void debugResetConnectionState() => _resetConnectionState();

  // Write the free-form user context string to Smarty (char 0xAB03).
  // Uses an acknowledged (long, if needed) write so the BLE stack surfaces
  // failures. Throws [ArgumentError] if the UTF-8 encoding exceeds
  // [userContextMaxBytes] — the firmware would otherwise truncate/reject it.
  Future<bool> writeUserContext(String context) async {
    final List<int> value = utf8.encode(context);
    if (value.length > userContextMaxBytes) {
      throw ArgumentError.value(
        context,
        'context',
        'User context is ${value.length} bytes (UTF-8); Smarty accepts at most '
            '$userContextMaxBytes bytes',
      );
    }

    if (_userDataCharacteristic == null) {
      debugPrint("❌ BleManager: User context characteristic (ab03) not found");
      return false;
    }

    try {
      await _userDataCharacteristic!
          .write(value, withoutResponse: false, allowLongWrite: true);
      return true;
    } catch (e) {
      debugPrint("❌ BleManager: Error writing user context: $e");
      return false;
    }
  }

  // Read the free-form user context string currently stored on Smarty.
  // Returns the decoded string (possibly empty) on success, or null on error.
  Future<String?> readUserContext() async {
    if (_userDataCharacteristic == null) {
      debugPrint("❌ BleManager: User context characteristic (ab03) not found");
      return null;
    }

    try {
      final List<int> data = await _userDataCharacteristic!.read();
      return utf8.decode(data, allowMalformed: true);
    } catch (e) {
      debugPrint("❌ BleManager: Error reading user context: $e");
      return null;
    }
  }

  /// How the toy's own id (ab06) is read: an empty answer (or the "{}"
  /// placeholder) is read again after each of these waits — 5 reads over
  /// ~3 s — before giving up. Right after the toy starts its id is still
  /// empty for a while, and ab06 uses ESP_GATT_AUTO_RSP: the first read once
  /// the id is set can still return the old (empty) value.
  static const List<Duration> toyIdReadWaits = [
    Duration.zero,
    Duration(milliseconds: 400),
    Duration(milliseconds: 600),
    Duration(milliseconds: 800),
    Duration(milliseconds: 1200),
  ];

  /// Read the toy's id with [read] (one read of ab06: its text, or a throw),
  /// once after each of [waits] ([toyIdReadWaits]), until one gives a real
  /// id. [wait] stands in for the waits in tests. Toy-free, for tests.
  static Future<ToyIdRead> readToyIdWithRetries(
    Future<String> Function() read, {
    List<Duration> waits = toyIdReadWaits,
    Future<void> Function(Duration) wait = Future<void>.delayed,
  }) async {
    bool answered = false;
    for (int attempt = 0; attempt < waits.length; attempt++) {
      if (waits[attempt] > Duration.zero) await wait(waits[attempt]);
      try {
        final String value = await read();
        answered = true;
        if (_idReadable(value)) return ToyIdRead.ready(value);
        debugPrint("⚠️ BleManager: toy id not ready yet (got '$value')");
      } catch (e) {
        debugPrint("❌ BleManager: reading the toy id failed "
            "(attempt ${attempt + 1}): $e");
      }
    }
    return ToyIdRead.none(stillStarting: answered);
  }

  /// Read the connected toy's own id (ab06, MAC-derived) — re-read while it
  /// is still empty ([toyIdReadWaits]). The answer says whether the toy is
  /// still starting up when there is no id.
  Future<ToyIdRead> readToyId() async {
    final BluetoothCharacteristic? c = _deviceInfoCharacteristic;
    if (c == null) {
      debugPrint("❌ BleManager: Device info characteristic (ab06) not found");
      return const ToyIdRead.none(stillStarting: false);
    }
    final String? remote = _connectedDevice?.remoteId.str;
    final ToyIdRead read = await readToyIdWithRetries(
        () async => utf8.decode(await c.read(), allowMalformed: true));
    final String? id = read.id;
    if (id != null) {
      debugPrint("BleManager: Read device ID: $id");
      if (remote != null) _toyDeviceIdByRemote[remote] = id;
    } else {
      debugPrint("❌ BleManager: device ID unavailable after retries "
          "(${read.stillStarting ? 'still starting' : 'no answer'})");
    }
    return read;
  }

  /// [readToyId]'s id, or null.
  Future<String?> readDeviceId() async => (await readToyId()).id;

  // Write device secret to ESP32 for Firebase registration
  Future<bool> writeDeviceSecret(String secret) async {
    if (_deviceSecretCharacteristic == null) {
      debugPrint("❌ BleManager: Device secret characteristic (ab05) not found");
      return false;
    }

    try {
      List<int> value = utf8.encode(secret);
      await _deviceSecretCharacteristic!
          .write(value, withoutResponse: false, allowLongWrite: true);
      debugPrint("BleManager: Device secret written (${value.length} bytes)");
      return true;
    } catch (e) {
      debugPrint("❌ BleManager: Error writing device secret: $e");
      return false;
    }
  }

  // Connect to WiFi
  Future<bool> connectToWifi(String ssid, String password) async {
    if (_wifiCredsCharacteristic == null) {
      debugPrint("❌ BleManager: WiFi credentials characteristic not found");
      return false;
    }

    try {
      // Format the credentials
      String creds = '$ssid,$password';
      List<int> value = utf8.encode(creds);

      // Write the credentials
      await _wifiCredsCharacteristic!
          .write(value, withoutResponse: false, allowLongWrite: true);
      return true;
    } catch (e) {
      debugPrint("❌ BleManager: Error connecting to WiFi: $e");
      return false;
    }
  }

  // Firmware needs ~4 connect cycles to emit "Connection Failed" for an absent
  // AP; the old 20 s window expired before the real verdict arrived, so the
  // parent got a misleading "still connecting" while a definitive answer was
  // seconds away.
  static const Duration _wifiProvisionTimeout = Duration(seconds: 45);

  /// Send Wi-Fi credentials AND wait for the device to report the real outcome.
  ///
  /// The plain [connectToWifi] returns as soon as the BLE write is acknowledged,
  /// which only means the credentials were delivered — the ESP32 then tries to
  /// join asynchronously and reports success (the SSID) or failure ("Auth
  /// Failed" / "Connection Failed") over the status characteristic. Showing
  /// "Connected!" on the bare write ack made a wrong password look like success
  /// (APP-1). This method subscribes to the status stream FIRST, writes the
  /// credentials, then resolves on the first definitive status (or a timeout).
  Future<WifiProvisionResult> connectToWifiAndAwait(
    String ssid,
    String password, {
    Duration timeout = _wifiProvisionTimeout,
  }) async {
    if (_wifiCredsCharacteristic == null) {
      debugPrint("❌ BleManager: WiFi credentials characteristic not found");
      return WifiProvisionResult.writeError;
    }

    final completer = Completer<WifiProvisionResult>();

    // The firmware truncates the reported SSID by BYTES (32 today, 31 on
    // deployed builds), possibly mid-character, and we decode status with
    // allowMalformed — so build the accepted forms the same way.
    final ssidBytes = utf8.encode(ssid);
    final acceptedSsids = <String>{
      ssid,
      for (final n in const [32, 31])
        if (ssidBytes.length > n)
          utf8.decode(ssidBytes.sublist(0, n), allowMalformed: true),
    };

    // Subscribe BEFORE writing so a fast result isn't missed. Firmware status
    // tokens come from wifi_config.c (exact strings, incl. the space).
    StreamSubscription<String>? sub;
    sub = wifiStatusStream.listen((status) {
      final s = status.trim();
      if (s == 'Auth Failed') {
        if (!completer.isCompleted) completer.complete(WifiProvisionResult.wrongPassword);
      } else if (s == 'Connection Failed' || s == 'No credentials') {
        if (!completer.isCompleted) completer.complete(WifiProvisionResult.failed);
      } else if (s == 'NotConnected') {
        // The BLE link to the toy dropped — a join result can never arrive now,
        // so resolve immediately instead of waiting out the full timeout.
        if (!completer.isCompleted) completer.complete(WifiProvisionResult.bleDisconnected);
      } else if (acceptedSsids.contains(s) || acceptedSsids.contains(status)) {
        // On IP_EVENT_STA_GOT_IP the device reports the joined SSID as its
        // status. Firmware truncates it to 32 (deployed: 31) UTF-8 bytes, so
        // accept those byte-truncated prefixes too.
        if (!completer.isCompleted) completer.complete(WifiProvisionResult.connected);
      }
      // Transient states ("Initializing", "Reconnecting") are ignored — we keep
      // waiting for a terminal result.
    });

    try {
      final wrote = await connectToWifi(ssid, password);
      if (!wrote) {
        return WifiProvisionResult.writeError;
      }
      return await completer.future
          .timeout(timeout, onTimeout: () => WifiProvisionResult.timeout);
    } catch (e) {
      debugPrint("❌ BleManager: connectToWifiAndAwait error: $e");
      return WifiProvisionResult.failed;
    } finally {
      await sub.cancel();
    }
  }

  // Reset WiFi connection
  Future<bool> resetWifiConnection() async {
    if (_wifiCredsCharacteristic == null) {
      debugPrint("❌ BleManager: WiFi credentials characteristic not found");
      return false;
    }

    try {
      // Send RESET command
      List<int> value = utf8.encode("RESET");
      await _wifiCredsCharacteristic!.write(value, withoutResponse: false);
      return true;
    } catch (e) {
      debugPrint("❌ BleManager: Error resetting WiFi connection: $e");
      return false;
    }
  }
  
  // Forget WiFi network - alias for resetWifiConnection with clearer naming
  Future<bool> forgetWifi() async {
    // debugPrint("📶 BleManager: Forgetting WiFi network");
    return resetWifiConnection();
  }

  // Scan for WiFi networks
  Future<List<WifiNetwork>> scanWifiNetworks() async {
    // Defensive: if the cached table was refreshed lazily (or the Service
    // Changed listener hasn't fired yet), try one re-discovery before giving up.
    if (_wifiScanCharacteristic == null) {
      debugPrint("⚠️ BleManager: WiFi scan characteristic missing — re-discovering services");
      await _discoverServices();
    }
    if (_wifiScanCharacteristic == null) {
      debugPrint("❌ BleManager: WiFi scan characteristic not found after re-discovery");
      return [];
    }

    StreamSubscription<List<int>>? subscription;
    try {
      // Set up a completer to wait for scan results
      Completer<List<WifiNetwork>> completer = Completer<List<WifiNetwork>>();
      List<String> networkEntries = [];
      bool receivedEndMarker = false;
      int expectedNetworks = 0;
      
      // Enable notifications
      await _wifiScanCharacteristic!.setNotifyValue(true);

      // Listen for notifications.
      //
      // Use onValueReceived, NOT lastValueStream. lastValueStream re-emits the
      // characteristic's last cached value the instant we subscribe. After the
      // first scan that cached value is the previous scan's "END" marker, so on
      // every refresh the listener would immediately see "END" with no networks
      // collected and complete with an empty list — "No WiFi networks found" —
      // before the firmware's fresh scan (~5s) even reports back. onValueReceived
      // only fires on real reads/notifications, so we wait for genuine results.
      subscription = _wifiScanCharacteristic!.onValueReceived.listen((value) {
        if (value.isEmpty) return;

        String notification = utf8.decode(value, allowMalformed: true);
        // debugPrint("📶 BleManager: Received WiFi scan notification: $notification");
        
        // Check for TOTAL marker which indicates how many networks to expect
        if (notification.startsWith("TOTAL:")) {
          try {
            expectedNetworks = int.parse(notification.substring(6));
            debugPrint("📶 BleManager: Expecting $expectedNetworks networks");
          } catch (e) {
            debugPrint("❌ BleManager: Error parsing TOTAL count: $e");
          }
          return;
        }
        
        // Check for END marker
        if (notification == "END") {
          receivedEndMarker = true;
          debugPrint("📶 BleManager: Received END marker, scan complete");
          
          // Complete the future with all collected networks
          if (!completer.isCompleted) {
            // Process all collected entries
            List<WifiNetwork> networks = WifiUtils.processWifiScanData(networkEntries.join('\n'));
            completer.complete(networks);
            subscription?.cancel();
          }
          return;
        }
        
        // Add the notification to our list of entries
        networkEntries.add(notification);
        
        // If we have received all expected networks and an END marker, or if we have more than expected
        if ((expectedNetworks > 0 && networkEntries.length >= expectedNetworks && receivedEndMarker) || 
            (expectedNetworks > 0 && networkEntries.length > expectedNetworks + 5)) {
          if (!completer.isCompleted) {
            // debugPrint("📶 BleManager: Received all expected networks or more than expected");
            List<WifiNetwork> networks = WifiUtils.processWifiScanData(networkEntries.join('\n'));
            completer.complete(networks);
            subscription?.cancel();
          }
        }
      });

      // Trigger a scan
      bool supportsWrite =
          _wifiScanCharacteristic!.properties.write ||
          _wifiScanCharacteristic!.properties.writeWithoutResponse;

      if (supportsWrite) {
        // A single "SCAN" write is the trigger. Notifications were already
        // enabled by setNotifyValue() above, so results arrive without a read —
        // avoiding a second, redundant scan trigger on the firmware.
        List<int> triggerValue = utf8.encode("SCAN");
        await _wifiScanCharacteristic!.write(
          triggerValue,
          withoutResponse:
              _wifiScanCharacteristic!.properties.writeWithoutResponse,
        );
        // debugPrint("📶 BleManager: Sent SCAN command to trigger WiFi scan");
      } else {
        // Fallback for a read/notify-only characteristic: a read triggers the
        // firmware scan instead.
        await _wifiScanCharacteristic!.read();
      }

      // Set a timeout (cancelled on completion via whenComplete below)
      final scanTimer = Timer(Duration(seconds: 15), () {
        if (!completer.isCompleted) {
          debugPrint("⏱️ BleManager: WiFi scan timeout reached");
          if (networkEntries.isNotEmpty) {
            // Process whatever entries we have received
            List<WifiNetwork> networks = WifiUtils.processWifiScanData(networkEntries.join('\n'));
            completer.complete(networks);
          } else {
            completer.complete([]);
          }
          subscription?.cancel();
        }
      });

      // Guarantee cleanup when completer resolves (any path)
      return completer.future.whenComplete(() {
        scanTimer.cancel();
        subscription?.cancel();
      });
    } catch (e) {
      subscription?.cancel();
      debugPrint("❌ BleManager: Error scanning for WiFi networks: $e");
      return [];
    }
  }

  // Save device ID for auto-reconnect
  Future<void> _saveDeviceId(BluetoothDevice device) async {
    final uid = _uid;
    if (uid == null) {
      // No signed-in user — never persist to a device-global key.
      debugPrint("BleManager: Skipped saving device — no signed-in user");
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    final id = device.remoteId.str;
    await prefs.setString(_deviceIdKeyFor(uid), id);
    await prefs.setString(_deviceNameKeyFor(uid), device.platformName);
    _savedToyId = id;
    if (device.platformName.isNotEmpty) _savedToyName = device.platformName;
    _loadAdvVersion(prefs, id);
    // A different toy is now saved: its own last Wi-Fi name (if any), never
    // the previous toy's.
    if (_lastWifiToyId != id) {
      _lastKnownWifiName = prefs.getString(_lastWifiKeyFor(id));
      _lastWifiToyId = id;
    }
    debugPrint("BleManager: Saved device for auto-reconnect: ${device.platformName} (${device.remoteId.str})");
  }

  // Get saved device ID
  Future<String?> getSavedDeviceId() async {
    final uid = _uid;
    if (uid == null) return null;
    final prefs = await SharedPreferences.getInstance();
    // Fall back to the legacy global key so a tester who saved a toy before
    // per-user scoping still triggers auto-reconnect (which does the migration).
    return prefs.getString(_deviceIdKeyFor(uid)) ??
        prefs.getString(_legacyDeviceIdKey);
  }

  // Clear saved device
  Future<void> clearSavedDevice() async {
    final String? toyId = _savedToyId;
    // Clear the in-memory copy first, so a prefs failure can't leave the
    // forgotten toy "saved" for this session.
    _savedToyId = null;
    _savedToyName = null;
    _lastKnownWifiName = null;
    _lastWifiToyId = null;
    _lastSeenToyId = null;
    _lastSeenAdvert = null;
    _lastSeenAt = null;
    if (toyId != null) _advVersionByToy.remove(toyId);
    final prefs = await SharedPreferences.getInstance();
    final uid = _uid;
    if (uid != null) {
      final String? storedId = prefs.getString(_deviceIdKeyFor(uid));
      await prefs.remove(_deviceIdKeyFor(uid));
      await prefs.remove(_deviceNameKeyFor(uid));
      await prefs.remove(_legacyLastWifiKeyFor(uid));
      for (final id in {toyId, storedId}) {
        if (id != null) {
          await prefs.remove(_lastWifiKeyFor(id));
          await prefs.remove(_advVersionKeyFor(id));
        }
      }
    } else if (toyId != null) {
      await prefs.remove(_lastWifiKeyFor(toyId));
      await prefs.remove(_advVersionKeyFor(toyId));
    }
    // Also drop the legacy global keys so a forgotten toy can't linger there.
    await prefs.remove(_legacyDeviceIdKey);
    await prefs.remove(_legacyDeviceNameKey);
    debugPrint("BleManager: Cleared saved device");
  }

  // Loads this account's saved toy into the cache, doing the one-time legacy
  // key migration. Returns the saved remote id, or null when none.
  Future<String?> _loadSavedToy(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    String? savedId = prefs.getString(_deviceIdKeyFor(uid));
    String? savedName = prefs.getString(_deviceNameKeyFor(uid));

    // One-time migration from the pre per-user global keys: attribute the
    // legacy saved toy to the first account that reconnects after the update,
    // then remove the legacy keys so no other account inherits it.
    if (savedId == null) {
      final legacyId = prefs.getString(_legacyDeviceIdKey);
      if (legacyId != null) {
        savedId = legacyId;
        savedName = prefs.getString(_legacyDeviceNameKey);
        await prefs.setString(_deviceIdKeyFor(uid), legacyId);
        if (savedName != null) {
          await prefs.setString(_deviceNameKeyFor(uid), savedName);
        }
        await prefs.remove(_legacyDeviceIdKey);
        await prefs.remove(_legacyDeviceNameKey);
      }
    }

    _savedToyId = savedId;
    _savedToyName = savedId == null ? null : (savedName ?? "Smarty");
    if (savedId != null) _loadAdvVersion(prefs, savedId);
    if (savedId == null) {
      _lastKnownWifiName = null;
      _lastWifiToyId = null;
    } else if (_lastWifiToyId != savedId) {
      String? lastWifi = prefs.getString(_lastWifiKeyFor(savedId));
      // One-time move from the old per-account key to the per-toy key.
      final legacyWifi = prefs.getString(_legacyLastWifiKeyFor(uid));
      if (legacyWifi != null) {
        if (lastWifi == null) {
          lastWifi = legacyWifi;
          await prefs.setString(_lastWifiKeyFor(savedId), legacyWifi);
        }
        await prefs.remove(_legacyLastWifiKeyFor(uid));
      }
      _lastKnownWifiName = lastWifi;
      _lastWifiToyId = savedId;
    }
    return savedId;
  }

  // Remember a real SSID (never a status token) so "Auth Failed" can name it.
  void _rememberWifiName(String ssid) {
    final s = ssid.trim();
    if (s.isEmpty || _nonConnectedStatuses.contains(s) || s.contains('Failed')) {
      return;
    }
    final toyId = _currentToyId;
    if (toyId == null) return;
    if (_lastKnownWifiName == s && _lastWifiToyId == toyId) return;
    _lastKnownWifiName = s;
    _lastWifiToyId = toyId;
    if (_uid == null) return;
    SharedPreferences.getInstance()
        .then((prefs) => prefs.setString(_lastWifiKeyFor(toyId), s))
        .catchError((Object e) {
      debugPrint("⚠️ BleManager: Couldn't persist last Wi-Fi name: $e");
      return false;
    });
  }

  // ===========================================================================
  // Launch / resume / reconnect state machine
  // ===========================================================================

  /// Bring [phase] up to date for this account's saved toy and (re)start the
  /// cheapest way of reaching it. Idempotent and single-flight: safe to call on
  /// launch (after sign-in), on app resume, on "Check again", and when the
  /// adapter turns on. Returns once the quick probe has settled — it never
  /// waits for a sleeping toy.
  ///
  /// Steps:
  /// 1. No signed-in user / no saved toy → [ToyPhase.noToy].
  /// 2. Adapter off → [ToyPhase.bluetoothOff]; unauthorized →
  ///    [ToyPhase.needsPermission]; not yet known → stays [ToyPhase.probing].
  ///    An adapter-state listener re-runs this when Bluetooth comes on. Never
  ///    turns Bluetooth on by itself (see [requestBluetoothOn]).
  /// 3. [ToyPhase.probing]: (a) saved toy already connected to the app or the
  ///    OS (e.g. after a hot restart) → initialize; (b) otherwise scan up to
  ///    [probeScanDuration] for its advert → direct connect
  ///    ([directConnectTimeout]) → initialize.
  /// 4. Not seen → [ToyPhase.notNearby] with `connect(autoConnect: true)` left
  ///    pending (no timeout): the toy connects by itself when it wakes up.
  ///
  /// Failures route through the same classification as [initialize]; a stale
  /// pairing lands in [ToyPhase.pairingBroken] and is not retried until this is
  /// called again. Until that pairing is repaired (a successful connect, or
  /// [forgetToy]), a probe that sees nothing stays in
  /// [ToyPhase.pairingBroken] and no background connect is armed.
  Future<void> watchSavedToy() {
    final running = _watchFuture;
    if (running != null && _watchGen == _sessionGen) return running;
    final gen = _sessionGen;
    _watchGen = gen;
    late final Future<void> run;
    run = _watchSavedToyImpl(gen).whenComplete(() {
      if (identical(_watchFuture, run)) _watchFuture = null;
    });
    _watchFuture = run;
    return run;
  }

  Future<void> _watchSavedToyImpl(int gen) async {
    // Yield first so a caller in the middle of a build never gets a
    // synchronous phase change (listeners would setState during build).
    await Future<void>.value();
    if (gen != _sessionGen) return;
    try {
      final uid = _uid;
      if (uid == null) {
        _setPhase(ToyPhase.noToy);
        return;
      }

      // Someone (pending autoConnect, connection page) is mid-initialize:
      // let it finish, then re-evaluate from there. Checked BEFORE "already
      // up" so we never report connected for a half-initialized link.
      for (var inFlight = _initializeFuture;
          inFlight != null;
          inFlight = _initializeFuture) {
        await inFlight.catchError((_) {});
        if (gen != _sessionGen) return;
      }

      final savedId = await _loadSavedToy(uid);
      if (gen != _sessionGen) return;

      // Already up — nothing to do, as long as it's THIS account's toy.
      final live = _connectedDevice;
      if (live != null && _statusCharacteristic != null) {
        if (savedId != null && live.remoteId.str == savedId) {
          _setPhase(ToyPhase.connected);
          return;
        }
        // A link that isn't this account's toy (e.g. left over from before a
        // sign-out) must not show as "connected" — drop it.
        debugPrint("BleManager: dropping link to ${live.remoteId.str} — not this account's toy");
        _resetConnectionState();
        try {
          await _disconnectOwn(live);
        } catch (_) {}
        if (gen != _sessionGen) return;
      }

      if (savedId == null) {
        await _cancelPendingConnect();
        _setPhase(ToyPhase.noToy);
        return;
      }


      _ensureAdapterWatch();
      final adapter = await BleService.getBluetoothState();
      if (gen != _sessionGen) return;
      switch (adapter) {
        case BluetoothAdapterState.on:
          _waitingForAdapter = false;
          break;
        case BluetoothAdapterState.off:
        case BluetoothAdapterState.turningOff:
        case BluetoothAdapterState.unavailable:
          _waitingForAdapter = true;
          _setPhase(ToyPhase.bluetoothOff);
          return;
        case BluetoothAdapterState.unauthorized:
          _waitingForAdapter = true;
          _setPhase(ToyPhase.needsPermission);
          return;
        default:
          // unknown / turningOn: undecided — NOT "off". Keep probing; the
          // adapter listener re-runs us once it settles.
          _waitingForAdapter = true;
          _setPhase(ToyPhase.probing);
          return;
      }

      _setPhase(ToyPhase.probing);
      final device = BluetoothDevice.fromId(savedId);

      // (a) Already connected to the app, or to the OS (e.g. after a hot
      // restart the native link survives but Dart state is gone).
      bool alreadyUp = device.isConnected;
      if (!alreadyUp) {
        try {
          final system = await FlutterBluePlus.systemDevices([smartyServiceGuid]);
          alreadyUp = system.any((d) => d.remoteId == device.remoteId);
        } catch (e) {
          debugPrint("⚠️ BleManager: systemDevices failed: $e");
        }
      }
      if (gen != _sessionGen) return;
      if (alreadyUp) {
        debugPrint("BleManager: Saved toy already connected — initializing");
        await _connectAndInitQuietly(device, gen);
        return;
      }

      // Pending autoConnect already fired while we were getting here?
      if (_initializeFuture != null || _connectedDevice != null) return;

      // (b) Quick scan for the saved toy's advert.
      final bool seen;
      try {
        seen = await _probeScan(device);
      } catch (e) {
        final kind = classifyConnectError(e);
        if (gen != _sessionGen) return;
        if (kind == ConnectFailure.needsPermission) {
          _setPhase(ToyPhase.needsPermission);
          return;
        }
        if (kind == ConnectFailure.bluetoothOff) {
          _setPhase(ToyPhase.bluetoothOff);
          return;
        }
        debugPrint("⚠️ BleManager: probe scan failed ($e)");
        await _settleNotSeen(device);
        return;
      }
      if (gen != _sessionGen) return;
      if (_initializeFuture != null || _connectedDevice != null) return;

      if (seen) {
        // Direct connect is much faster than autoConnect's background scans.
        // Cancel the pending request first so we don't issue two connects.
        await _cancelPendingConnect(switchingTo: device);
        await _connectAndInitQuietly(device, gen);
        return;
      }

      debugPrint("BleManager: Saved toy not seen in ${probeScanDuration.inSeconds}s");
      await _settleNotSeen(device);
    } catch (e) {
      debugPrint("❌ BleManager: watchSavedToy error: $e");
      if (gen == _sessionGen && _phase.value == ToyPhase.probing) {
        _setPhase(_repairToyId != null && _repairToyId == _savedToyId
            ? ToyPhase.pairingBroken
            : ToyPhase.notNearby);
      }
    }
  }

  // The saved toy wasn't reached. Normally: [ToyPhase.notNearby] with a
  // background connect armed. While its pairing awaits repair: stay on
  // [ToyPhase.pairingBroken] (Home keeps the repair instructions) and arm
  // nothing — see [_repairToyId].
  Future<void> _settleNotSeen(BluetoothDevice device) async {
    if (_needsRepairFor(device)) {
      debugPrint("BleManager: pairing still needs repair — staying on pairingBroken");
      _setPhase(ToyPhase.pairingBroken);
      return;
    }
    _setPhase(ToyPhase.notNearby);
    await _armPendingConnect(device);
  }

  // Scan up to [probeScanDuration] for [device]'s advert. Returns true on the
  // first sighting. Throws on scan errors (e.g. permission) for the caller to
  // classify. Skips (returns false) if another screen is already scanning, so
  // a resume never kills the setup page's scan — the pending autoConnect
  // covers that case.
  //
  // FBP has ONE scan: startScan replaces whatever runs and stopScan stops it,
  // whoever started it. So the probe holds an owner token: a screen that
  // needs the scanner calls [cancelProbe] first, after which this probe
  // ignores results (they're the screen's) and leaves the scan running.
  Future<bool> _probeScan(BluetoothDevice device) async {
    if (FlutterBluePlus.isScanningNow) {
      debugPrint("BleManager: another scan is running — skipping probe scan");
      return false;
    }
    final int token = ++_probeToken;
    final found = Completer<bool>();
    _probeFound = found;
    final sub = FlutterBluePlus.onScanResults.listen((results) {
      if (found.isCompleted) return;
      // Not our scan any more (cancelled, or replaced/stopped by a screen).
      if (token != _probeToken || !FlutterBluePlus.isScanningNow) return;
      for (final r in results) {
        if (r.device.remoteId == device.remoteId) {
          _recordSighting(r);
          found.complete(true);
          return;
        }
      }
    }, onError: (Object e) {
      debugPrint("⚠️ BleManager: probe scan stream error: $e");
    });
    _probeSub = sub;
    try {
      await FlutterBluePlus.startScan(
        withServices: [smartyServiceGuid],
        // Scan filters are OR-ed; on Android also match the saved MAC in case
        // the service UUID only rides in the scan response.
        withRemoteIds: Platform.isAndroid ? [device.remoteId.str] : const [],
        timeout: probeScanDuration,
      );
      if (token != _probeToken) return false; // cancelled while starting
      return await found.future.timeout(
        probeScanDuration + const Duration(milliseconds: 300),
        onTimeout: () => false,
      );
    } finally {
      await sub.cancel();
      if (identical(_probeSub, sub)) _probeSub = null;
      if (identical(_probeFound, found)) _probeFound = null;
      // Stop the scan only if it is still ours — after cancelProbe() the
      // running scan belongs to whoever asked for the cancel.
      if (token == _probeToken) {
        try {
          await FlutterBluePlus.stopScan();
        } catch (e) {
          debugPrint("⚠️ BleManager: stopScan failed: $e");
        }
      }
    }
  }

  /// Give up the launch/resume probe scan (if one is running) so a screen can
  /// start its own scan: the probe stops listening, won't stop the screen's
  /// scan, and resolves as "not seen" — [phase] then settles as for a probe
  /// that found nothing ([ToyPhase.notNearby], or [ToyPhase.pairingBroken]
  /// while a pairing awaits repair). Call right before your own `startScan`.
  void cancelProbe() {
    final found = _probeFound;
    if (found == null) return;
    debugPrint("BleManager: probe scan cancelled — a screen needs the scanner");
    _probeToken++;
    _probeFound = null;
    final sub = _probeSub;
    _probeSub = null;
    unawaited(sub?.cancel());
    if (!found.isCompleted) found.complete(false);
  }

  /// Direct-connect [device] (skipped if already connected) and [initialize]
  /// it. Cancels any pending background connect first.
  ///
  /// Contract: completes when [phase] is [ToyPhase.connected]; otherwise throws
  /// a [ConnectException] after [phase] has been moved to the matching
  /// recovery state (see [initialize]). Intended for the setup page's "tap a
  /// toy" path so it shares classification with the launch flow.
  Future<void> connectAndInitialize(
    BluetoothDevice device, {
    Duration timeout = directConnectTimeout,
  }) async {
    final gen = _sessionGen;
    await _cancelPendingConnect(switchingTo: device);
    if (gen != _sessionGen) {
      throw const ConnectException(ConnectFailure.cancelledByUser);
    }
    _setPhase(ToyPhase.connecting);
    _watchLink(device);
    if (!device.isConnected) {
      _connectingDevice = device;
      try {
        await device.connect(timeout: timeout, mtu: null);
      } catch (e) {
        if (gen != _sessionGen) {
          // forgetToy()/disconnectAndReset() cancelled this connect.
          throw ConnectException(ConnectFailure.cancelledByUser, e);
        }
        final DisconnectReason? reason = device.disconnectReason;
        final kind = _classifyForDevice(e, device);
        final failure = ConnectException(kind, e,
            kind == ConnectFailure.pairingBroken &&
                isStaleBondEvidence(e, reason));
        debugPrint("❌ BleManager: connect failed (${failure.kind.name}): $e");
        await _onConnectFailure(device, failure);
        throw failure;
      } finally {
        if (_connectingDevice?.remoteId == device.remoteId) {
          _connectingDevice = null;
        }
      }
      if (gen != _sessionGen) {
        // Signed out / forgotten while the link came up: it must not carry
        // over to the next account.
        try {
          await _disconnectOwn(device);
        } catch (_) {}
        throw const ConnectException(ConnectFailure.cancelledByUser);
      }
      _noteLinkUp(device);
    }
    await _initialize(device, gen);
  }

  // connectAndInitialize for the state machine: failures are already reflected
  // in [phase], so just log them.
  Future<void> _connectAndInitQuietly(BluetoothDevice device, int gen) async {
    if (gen != _sessionGen) return;
    try {
      await connectAndInitialize(device);
    } on ConnectException catch (e) {
      debugPrint("BleManager: connect attempt ended: ${e.kind.name}");
    } catch (e) {
      debugPrint("BleManager: connect attempt error: $e");
    }
  }

  // Arm `connect(autoConnect: true)` for [device] and leave it pending with no
  // timeout; when the OS connects, initialize. Idempotent per device.
  Future<void> _armPendingConnect(BluetoothDevice device) async {
    final gen = _sessionGen;
    _rearmTimer?.cancel();
    _rearmTimer = null;
    if (_uid == null) return;
    if (_needsRepairFor(device)) {
      // Reconnecting would only replay the stale keys (and on iOS FBP would
      // keep retrying). Recovery goes through the setup page instead.
      debugPrint("BleManager: not arming background connect — pairing needs repair");
      return;
    }
    if (FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on) {
      // The adapter listener re-runs watchSavedToy when it comes back on.
      return;
    }
    if (_armedDevice != null && _armedDevice != device) {
      await _cancelPendingConnect(switchingTo: device);
    }
    // Our listener still attached = we armed it and nothing failed since.
    final bool wasArmed = _pendingSub != null && _armedDevice == device;
    _armedDevice = device;
    _watchLink(device);

    _pendingSub?.cancel();
    final sub = device.connectionState.listen((state) {
      if (state == BluetoothConnectionState.connected) {
        _onPendingConnected(device, gen);
      }
    });
    _pendingSub = sub;

    // FBP keeps autoConnect devices armed across link drops / adapter
    // restarts itself, so normally we only issue the request when it isn't
    // already. But FBP flags the device BEFORE calling the platform and never
    // unflags it if that call throws — so a flag without our listener
    // (never armed by us, or a failed attempt) counts as NOT armed.
    if (device.isConnected) return;
    if (device.isAutoConnectEnabled && wasArmed) return;
    try {
      await device.connect(autoConnect: true, mtu: null);
      debugPrint("BleManager: Background connect armed for ${device.remoteId.str}");
    } catch (e) {
      final kind = classifyConnectError(e);
      debugPrint("⚠️ BleManager: Arming background connect failed (${kind.name}): $e");
      // Leave nothing half-armed: drop our listener and clear FBP's stale
      // autoConnect flag (disconnect() removes it), so the next attempt
      // really re-arms.
      if (identical(_pendingSub, sub)) {
        _pendingSub = null;
        if (_armedDevice == device) _armedDevice = null;
      }
      unawaited(sub.cancel());
      try {
        await _disconnectOwn(device);
      } catch (_) {}
      if (gen != _sessionGen) return;
      if (kind == ConnectFailure.needsPermission) {
        _setPhase(ToyPhase.needsPermission);
      } else if (kind == ConnectFailure.bluetoothOff) {
        _setPhase(ToyPhase.bluetoothOff);
      }
    }
  }

  void _onPendingConnected(BluetoothDevice device, int gen) {
    if (gen != _sessionGen) return;
    _noteLinkUp(device);
    if (_connectedDevice == device && _statusCharacteristic != null) return;
    if (_needsRepairFor(device)) {
      // A connect that was already on its way when the pairing was judged
      // broken: don't initialize (it would only replay the stale keys).
      debugPrint("BleManager: background connect fired but the pairing needs repair — dropping it");
      if (_armedDevice == device) {
        _pendingSub?.cancel();
        _pendingSub = null;
        _armedDevice = null;
      }
      unawaited(_disconnectOwn(device).catchError((Object _) {}));
      return;
    }
    if (_initializeFuture != null) {
      final other = _initializingDevice;
      if (other != null && other.remoteId != device.remoteId) {
        // A different toy is being set up right now; this background link
        // would be left connected with nobody using it. Drop it.
        debugPrint("BleManager: background connect fired while setting up another toy — dropping it");
        if (_armedDevice == device) {
          _pendingSub?.cancel();
          _pendingSub = null;
          _armedDevice = null;
        }
        unawaited(_disconnectOwn(device).catchError((Object e) {
          debugPrint("⚠️ BleManager: dropping background link failed: $e");
        }));
      }
      return; // same toy: that initialize is already on it
    }
    debugPrint("BleManager: Background connect fired — initializing");
    _pendingSub?.cancel();
    _pendingSub = null;
    _initialize(device, gen).catchError((Object e) {
      debugPrint("BleManager: initialize after background connect failed: $e");
    });
  }

  // Cancel the pending background connect (if any) and the backoff timer.
  // Never drops a live, initialized link. [switchingTo]: the toy the caller
  // is about to connect/initialize instead — an armed device that has
  // ALREADY connected (but isn't that toy) is then disconnected, since
  // nobody would take over its link.
  Future<void> _cancelPendingConnect({BluetoothDevice? switchingTo}) async {
    _rearmTimer?.cancel();
    _rearmTimer = null;
    _pendingSub?.cancel();
    _pendingSub = null;
    final armed = _armedDevice;
    _armedDevice = null;
    if (armed == null) return;
    if (armed.isConnected) {
      // Connected already: it is being (or has been) initialized — leave it,
      // unless we are switching to a different toy.
      if (switchingTo == null || armed.remoteId == switchingTo.remoteId) return;
      // A live, initialized link is dropped by initialize() itself (after
      // detaching its listeners), never from here.
      if (_connectedDevice?.remoteId == armed.remoteId) return;
      if (_initializingDevice?.remoteId == armed.remoteId) return;
    }
    try {
      await _disconnectOwn(armed);
    } catch (_) {
      // Nothing pending / already disconnected — ignore.
    }
  }

  // Link to an initialized toy dropped.
  Future<void> _onLinkLost(BluetoothDevice device) async {
    final gen = _sessionGen;
    final reason = device.disconnectReason;
    debugPrint("BleManager: link lost ($reason)");
    if (_uid == null) {
      _setPhase(ToyPhase.noToy);
      return;
    }
    final adapter = FlutterBluePlus.adapterStateNow;
    if (adapter == BluetoothAdapterState.off ||
        adapter == BluetoothAdapterState.turningOff) {
      _waitingForAdapter = true;
      _setPhase(ToyPhase.bluetoothOff);
      return;
    }
    // Count this drop (unless the link watcher already did) — a stale
    // pairing can also show up as a drop right after "connected".
    if (isPairingBrokenReason(reason) || _noteLinkDown(device)) {
      await _enterPairingBroken(device);
      return;
    }
    if (gen != _sessionGen) return;
    if (_savedToyId != null && _savedToyId != device.remoteId.str) {
      // Not the saved toy — let the state machine sort it out.
      unawaited(watchSavedToy());
      return;
    }
    await _settleNotSeen(device);
  }

  // Central failure → phase mapping for initialize/connect attempts.
  Future<void> _onConnectFailure(
      BluetoothDevice device, ConnectException failure) async {
    _consecutiveFailures++;
    switch (failure.kind) {
      case ConnectFailure.pairingBroken:
        await _enterPairingBroken(device);
        return;
      case ConnectFailure.bluetoothOff:
        _waitingForAdapter = true;
        _setPhase(ToyPhase.bluetoothOff);
        return;
      case ConnectFailure.needsPermission:
        _waitingForAdapter = true;
        _setPhase(ToyPhase.needsPermission);
        return;
      default:
        break;
    }
    final savedId = _savedToyId;
    if (_uid == null || savedId == null) {
      _setPhase(ToyPhase.noToy);
      return;
    }
    if (_needsRepairFor(BluetoothDevice.fromId(savedId))) {
      // Still waiting on the repair: keep its instructions up, arm nothing.
      _setPhase(ToyPhase.pairingBroken);
      return;
    }
    // Keep waiting for the saved toy in the background, backing off so a toy
    // that connects-then-fails can't spin us in a tight loop.
    _setPhase(ToyPhase.notNearby);
    final int exp = _consecutiveFailures <= 1
        ? 0
        : (_consecutiveFailures - 1 > 5 ? 5 : _consecutiveFailures - 1);
    final int secs = 2 << exp; // 2, 4, 8 … 64
    final delay = Duration(seconds: secs > 60 ? 60 : secs);
    final gen = _sessionGen;
    _rearmTimer?.cancel();
    _rearmTimer = Timer(delay, () {
      if (gen != _sessionGen || _phase.value != ToyPhase.notNearby) return;
      _armPendingConnect(BluetoothDevice.fromId(savedId));
    });
    debugPrint("BleManager: will re-arm background connect in ${delay.inSeconds}s");
  }

  Future<void> _enterPairingBroken(BluetoothDevice device) async {
    final bool already = _needsRepairFor(device);
    _drops.reset();
    _repairToyId = device.remoteId.str;
    _rearmTimer?.cancel();
    _rearmTimer = null;
    if (!already) {
      debugPrint("🧭 BleManager: pairing with ${device.remoteId.str} is broken — "
          "no more background reconnects until it is repaired");
    }
    // Phase first: the rearm timer and every settle path check it (and
    // [_repairToyId]) before arming anything.
    _setPhase(ToyPhase.pairingBroken);
    await _cancelPendingConnect();
    // disconnect() also clears FBP's autoConnect flag (and cancels the iOS 17+
    // system auto-reconnect FBP asks for) — otherwise iOS would keep
    // reconnecting by itself with the stale keys.
    try {
      await _disconnectOwn(device);
    } catch (_) {}
    if (Platform.isAndroid) {
      // Drop the stale bond so the next attempt pairs fresh. (iOS has no API
      // for this — the parent forgets Smarty in Settings → Bluetooth.)
      try {
        await device.removeBond();
        debugPrint("BleManager: Removed stale bond on Android");
      } catch (e) {
        debugPrint("⚠️ BleManager: removeBond failed: $e");
      }
    }
  }

  // ---- Link watch: stale-pairing detection ---------------------------------
  //
  // "Connected, then dropped within a few seconds" is the signature of a toy
  // that rejects our stale pairing: iOS connects (a pending autoConnect does
  // so the moment the toy advertises), fails to encrypt with the old keys and
  // hangs up ~0.4 s later (toy log: reason 0x13, then SMP_CONN_TOUT). One
  // such drop could also be a toy switched off at the wrong moment, so it
  // takes two in a row ([LinkDropTracker.threshold]) — unless the drop's
  // reason already says so.

  // Follow [device]'s link for as long as we connect to / wait for it.
  // Idempotent per device; switching devices starts a fresh streak.
  void _watchLink(BluetoothDevice device) {
    if (_linkWatchSub != null && _linkWatchDevice == device) return;
    _linkWatchSub?.cancel();
    _linkWatchDevice = device;
    if (_dropsToyId != device.remoteId.str) {
      _drops.reset();
      _dropsToyId = device.remoteId.str;
    }
    bool replay = true; // FBP replays the current state on listen
    bool sawUp = false; // a "connected" since the last "disconnected"
    _linkWatchSub = device.connectionState.listen((state) {
      final bool first = replay;
      replay = false;
      if (state == BluetoothConnectionState.connected) {
        sawUp = true;
        // A replayed "connected" is a link of unknown age: don't time it.
        if (!first) _noteLinkUp(device);
      } else if (state == BluetoothConnectionState.disconnected) {
        final bool wasUp = sawUp;
        sawUp = false;
        if (first) return; // just the current state, not an event
        if (wasUp) {
          _onWatchedLinkDown(device);
        } else {
          // "disconnected" with no "connected" before it: a connect attempt
          // that failed. For a pending autoConnect nobody else ever sees
          // this (FBP just re-issues the connect), so it is judged here.
          _onWatchedConnectFailed(device);
        }
      }
    }, onError: (Object e) {
      debugPrint("⚠️ BleManager: link watch stream error: $e");
    });
  }

  void _unwatchLink() {
    _linkWatchSub?.cancel();
    _linkWatchSub = null;
    _linkWatchDevice = null;
    _drops.reset();
    _dropsToyId = null;
  }

  // Something encrypted worked on [device]'s link: it is paired (see
  // [LinkDropTracker.linkSecured]).
  void _noteLinkSecured(BluetoothDevice device) {
    _securedOn = device;
    if (_dropsToyId == device.remoteId.str) _drops.linkSecured();
  }

  // The toy took the account proof on [device]'s link (see
  // [LinkDropTracker.linkProved]).
  void _noteLinkProved(BluetoothDevice device) {
    if (_dropsToyId == device.remoteId.str) _drops.linkProved();
  }

  void _noteLinkUp(BluetoothDevice device) {
    // Another toy is being followed (e.g. setup of a new Smarty while the old
    // one's background connect fires): leave that toy's streak alone.
    if (_dropsToyId != null && _dropsToyId != device.remoteId.str) return;
    _dropsToyId = device.remoteId.str;
    _drops.linkUp(DateTime.now());
  }

  // Record that [device]'s link went down — once per link, whichever path
  // sees it first (link watch, _onLinkLost, a failed initialize). Returns
  // true when this drop means the pairing is broken. Quick-drop streaks only
  // count for the saved toy; a pairing-broken REASON counts for any toy.
  // Must stay synchronous: the reason is only reliable right at the drop.
  bool _noteLinkDown(BluetoothDevice device) {
    if (_dropsToyId != device.remoteId.str) return false;
    final DisconnectReason? reason = device.disconnectReason;
    final bool ours = (_ownDisconnects[device.remoteId.str] ?? 0) > 0 ||
        isOwnDisconnectReason(reason) ||
        FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on;
    // Right after the account proof, the drop is the toy's verdict on the
    // proof (see [claimVerdictFor]) — not a sign of a stale pairing.
    final bool proofTurnedDown = _justProved(device);
    final LinkDropVerdict? verdict = _drops.linkDown(
      DateTime.now(),
      pairingReason: !ours && !proofTurnedDown && isPairingBrokenReason(reason),
      intentional: ours || proofTurnedDown,
    );
    if (verdict == null) return false;
    debugPrint("BleManager: link down — ${verdict.name}"
        "${verdict == LinkDropVerdict.quick ? ' #${_drops.quickDrops}' : ''} ($reason)");
    switch (verdict) {
      case LinkDropVerdict.pairingReason:
      case LinkDropVerdict.turnedAway:
        return true;
      case LinkDropVerdict.repeatedQuickDrops:
        return device.remoteId.str == _savedToyId;
      default:
        return false;
    }
  }

  // The link watch saw [device] drop. If that settles "pairing broken" for
  // the saved toy, stop everything right here — even when the drop landed
  // mid-initialize or before any other listener was attached.
  void _onWatchedLinkDown(BluetoothDevice device) {
    if (!_noteLinkDown(device)) return;
    if (_uid == null || device.remoteId.str != _savedToyId) return;
    unawaited(_enterPairingBroken(device));
  }

  // A connect attempt on the watched toy failed before the link came up. On
  // iOS a stale pairing surfaces exactly like this for a pending autoConnect
  // (didFailToConnectPeripheral "Peer removed pairing information" — the
  // toy logs Connected, then reason 0x13 ~0.4 s later), and FBP re-issues
  // the autoConnect after every such event, so without this check the app
  // would retry forever without ever hearing about it.
  void _onWatchedConnectFailed(BluetoothDevice device) {
    final String id = device.remoteId.str;
    if (_dropsToyId != id) return;
    final DisconnectReason? reason = device.disconnectReason;
    final bool ours = (_ownDisconnects[id] ?? 0) > 0 ||
        isOwnDisconnectReason(reason) ||
        FlutterBluePlus.adapterStateNow != BluetoothAdapterState.on;
    if (ours || reason == null || reason.code == null) return;
    final bool pairing = isPairingBrokenReason(reason);
    // Android reports routine connect failures (GATT 133 …) this way too;
    // there only a pairing reason counts. (iOS never fails a connect for
    // mere absence — a pending connect just waits.)
    if (!pairing && reason.platform != ErrorPlatform.apple) return;
    final LinkDropVerdict verdict = _drops.linkFailed(pairingReason: pairing);
    debugPrint("BleManager: connect attempt failed — ${verdict.name}"
        "${verdict == LinkDropVerdict.quick ? ' #${_drops.quickDrops}' : ''} ($reason)");
    if (verdict != LinkDropVerdict.pairingReason &&
        verdict != LinkDropVerdict.repeatedQuickDrops) {
      return;
    }
    if (_uid == null || id != _savedToyId) return;
    unawaited(_enterPairingBroken(device));
  }

  // Our own disconnect(): the drop it causes is not the toy's doing.
  Future<void> _disconnectOwn(BluetoothDevice device) async {
    final String id = device.remoteId.str;
    _ownDisconnects[id] = (_ownDisconnects[id] ?? 0) + 1;
    try {
      await device.disconnect();
    } finally {
      final int left = (_ownDisconnects[id] ?? 1) - 1;
      if (left <= 0) {
        _ownDisconnects.remove(id);
      } else {
        _ownDisconnects[id] = left;
      }
    }
  }

  /// FBP's iOS/macOS reason code for a disconnect the app asked for
  /// (cancelPeripheralConnection reports no error; FBP substitutes this).
  static const int fbpAppleUserCanceledCode = 23789258;

  /// Whether [reason] is FBP's "we cancelled it ourselves" marker. Pure.
  @visibleForTesting
  static bool isOwnDisconnectReason(DisconnectReason? reason) =>
      reason != null &&
      reason.platform == ErrorPlatform.apple &&
      reason.code == fbpAppleUserCanceledCode;

  // Classification for a failure on [device]: the error itself first, then
  // the link's own disconnect reason / quick-drop streak (counting this drop
  // unless the link watch already did), then a verdict the link watch
  // reached meanwhile.
  ConnectFailure _classifyForDevice(Object error, BluetoothDevice device) {
    final kind = classifyConnectError(error);
    if (kind == ConnectFailure.pairingBroken ||
        kind == ConnectFailure.needsPermission ||
        kind == ConnectFailure.bluetoothOff ||
        kind == ConnectFailure.notSmarty) {
      return kind;
    }
    if (device.isDisconnected) {
      if (isPairingBrokenReason(device.disconnectReason)) {
        return ConnectFailure.pairingBroken;
      }
      if (_noteLinkDown(device)) return ConnectFailure.pairingBroken;
    }
    if (_needsRepairFor(device)) return ConnectFailure.pairingBroken;
    return kind;
  }

  static const List<String> _pairingMarkers = [
    'peer removed pairing',
    'pairing information',
    'authentication',
    'encrypt',
    'insufficient auth',
    'insuf_auth',
    'bond',
    'pin_or_key_missing',
    'key missing',
  ];

  static bool _hasPairingMarker(String lower) =>
      _pairingMarkers.any(lower.contains);

  // Disconnect reasons that mean "the toy rejected our keys":
  //  - iOS CBError 14 peerRemovedPairingInformation, 15 encryptionTimedOut
  //  - Android HCI 0x05 AUTHENTICATION_FAILURE, 0x06 PIN_OR_KEY_MISSING,
  //    0x3D CONNECTION_TERMINATED_MIC_FAILURE
  /// Whether a link's disconnect [reason] means "the toy rejected our keys".
  /// Pure; exposed for tests.
  @visibleForTesting
  static bool isPairingBrokenReason(DisconnectReason? reason) {
    if (reason == null) return false;
    final code = reason.code;
    if (reason.platform == ErrorPlatform.apple && (code == 14 || code == 15)) {
      return true;
    }
    if (reason.platform == ErrorPlatform.android &&
        (code == 0x05 || code == 0x06 || code == 0x3D)) {
      return true;
    }
    final desc = reason.description?.toLowerCase() ?? '';
    return desc.isNotEmpty && _hasPairingMarker(desc);
  }

  /// Whether a failed attempt's [error] (or the link's disconnect [reason])
  /// says outright that the toy has dropped the pairing THIS phone holds —
  /// as opposed to refusing a new pairing (a toy set up with another phone
  /// that isn't waiting to pair). Pure; see [ConnectException.staleBond].
  ///
  /// - iOS: CBError 14 "Peer removed pairing information" (connect error or
  ///   disconnect reason). Not "insufficient authentication / encryption"
  ///   (ATT 5 / 15) or CBError 15: a refused new pairing looks the same.
  /// - Android: HCI 0x06 PIN_OR_KEY_MISSING, 0x3D MIC failure — the toy
  ///   rejected keys this phone already has. Not 0x05 AUTHENTICATION_FAILURE:
  ///   the toy's stack also ends a refused new pairing with it.
  /// - Any text that says so ("peer removed pairing", "pairing
  ///   information", "pin or key missing", "key missing").
  @visibleForTesting
  static bool isStaleBondEvidence(Object? error, [DisconnectReason? reason]) {
    bool staleCode(ErrorPlatform platform, int? code) =>
        (platform == ErrorPlatform.apple && code == 14) ||
        (platform == ErrorPlatform.android && (code == 0x06 || code == 0x3D));
    bool staleText(String? text) {
      final lower = (text ?? '').toLowerCase();
      return lower.contains('peer removed pairing') ||
          lower.contains('pairing information') ||
          lower.contains('pin_or_key_missing') ||
          lower.contains('pin or key missing') ||
          lower.contains('key missing');
    }

    if (reason != null &&
        (staleCode(reason.platform, reason.code) ||
            staleText(reason.description))) {
      return true;
    }
    if (error == null) return false;
    if (error is ConnectException) {
      return error.staleBond || isStaleBondEvidence(error.cause);
    }
    if (error is FlutterBluePlusException &&
        error.function == 'connect' &&
        staleCode(error.platform, error.code)) {
      return true;
    }
    if (error is PlatformException) {
      return staleText('${error.code} ${error.message ?? ''} '
          '${error.details ?? ''}');
    }
    return staleText(error.toString());
  }

  /// Map any BLE error to a [ConnectFailure]. Pure; exposed so the setup page
  /// can branch on the same classification.
  ///
  /// - pairingBroken: messages with "peer removed pairing", "pairing
  ///   information", "authentication", "encrypt", "insufficient auth", "bond";
  ///   GATT op errors 5/8/15 (insufficient authentication / authorization /
  ///   encryption); iOS connect errors 14/15; Android HCI 5/6/0x3D.
  /// - needsPermission: "permission" anywhere (Android runtime permissions).
  /// - bluetoothOff: FBP adapterIsOff / "Bluetooth must be turned on".
  /// - cancelledByUser: FBP connectionCanceled / userRejected, "cancel".
  ///   (Not bare "user": HCI 0x13 "remote user terminated" is a normal drop.)
  /// - outOfRange: timeouts, Android 133 / 147 / HCI 0x08, "not found".
  /// - notSmarty: missing service/characteristic.
  static ConnectFailure classifyConnectError(Object error) {
    if (error is ConnectException) return error.kind;
    if (error is TimeoutException) return ConnectFailure.outOfRange;

    final String lower;
    if (error is PlatformException) {
      lower = '${error.code} ${error.message ?? ''} ${error.details ?? ''}'
          .toLowerCase();
    } else {
      lower = error.toString().toLowerCase();
    }

    if (lower.contains('permission')) return ConnectFailure.needsPermission;
    if (lower.contains('bluetooth must be turned on') ||
        lower.contains('adapter is off') ||
        lower.contains('bluetooth turned off')) {
      return ConnectFailure.bluetoothOff;
    }

    if (error is FlutterBluePlusException) {
      final code = error.code;
      if (error.platform == ErrorPlatform.fbp) {
        if (code == FbpErrorCode.connectionCanceled.index ||
            code == FbpErrorCode.userRejected.index) {
          return ConnectFailure.cancelledByUser;
        }
        if (code == FbpErrorCode.timeout.index) return ConnectFailure.outOfRange;
        if (code == FbpErrorCode.adapterIsOff.index) {
          return ConnectFailure.bluetoothOff;
        }
        if (code == FbpErrorCode.serviceNotFound.index ||
            code == FbpErrorCode.characteristicNotFound.index) {
          return ConnectFailure.notSmarty;
        }
      } else if (error.function == 'connect') {
        // Native connect failure: code is a disconnect reason.
        if (error.platform == ErrorPlatform.apple &&
            (code == 14 || code == 15)) {
          return ConnectFailure.pairingBroken;
        }
        if (error.platform == ErrorPlatform.android) {
          if (code == 0x05 || code == 0x06 || code == 0x3D) {
            return ConnectFailure.pairingBroken;
          }
          if (code == 133 || code == 147 || code == 0x08) {
            return ConnectFailure.outOfRange;
          }
        }
      } else if (code == 5 || code == 8 || code == 15) {
        // GATT operation (read/write/notify) rejected for security reasons.
        return ConnectFailure.pairingBroken;
      }
    }

    if (_hasPairingMarker(lower)) return ConnectFailure.pairingBroken;
    if (lower.contains('cancel')) return ConnectFailure.cancelledByUser;
    // Before the generic "not found": "service not found" is a wrong toy,
    // not an absent one.
    if (lower.contains('smarty service') ||
        lower.contains('service not found') ||
        lower.contains('characteristic not found')) {
      return ConnectFailure.notSmarty;
    }
    if (lower.contains('timeout') ||
        lower.contains('timed out') ||
        lower.contains('not found')) {
      return ConnectFailure.outOfRange;
    }
    return ConnectFailure.unknown;
  }

  // Listen to the adapter for the whole signed-in session: re-run the state
  // machine when Bluetooth comes on, and reflect it going off in place.
  void _ensureAdapterWatch() {
    if (_adapterSub != null) return;
    _adapterSub = FlutterBluePlus.adapterState.listen((state) {
      if (_uid == null) return;
      switch (state) {
        case BluetoothAdapterState.on:
          if (_waitingForAdapter ||
              _phase.value == ToyPhase.bluetoothOff ||
              _phase.value == ToyPhase.needsPermission) {
            _waitingForAdapter = false;
            unawaited(watchSavedToy());
          }
          break;
        case BluetoothAdapterState.off:
        case BluetoothAdapterState.turningOff:
          _rearmTimer?.cancel();
          if (_phase.value != ToyPhase.noToy) {
            _waitingForAdapter = true;
            _setPhase(ToyPhase.bluetoothOff);
          }
          break;
        case BluetoothAdapterState.unauthorized:
          if (_phase.value != ToyPhase.noToy) {
            _waitingForAdapter = true;
            _setPhase(ToyPhase.needsPermission);
          }
          break;
        default:
          break;
      }
    }, onError: (Object e) {
      debugPrint("⚠️ BleManager: adapter state stream error: $e");
    });
  }

  /// Explicit, user-initiated "turn Bluetooth on" (for a button — never called
  /// automatically). Android shows the system dialog; iOS has no API for it,
  /// so this opens the app's own page in Settings instead (iOS allows no link
  /// to Settings → Bluetooth; the line under the button says where it lands).
  /// The adapter listener takes it from there.
  Future<void> requestBluetoothOn() async {
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
        return;
      } catch (e) {
        debugPrint("⚠️ BleManager: turnOn failed/declined: $e");
      }
    }
    await BleService.openBluetoothSettings();
  }

  /// Forget this account's toy: cancel any pending connect, drop the link,
  /// remove the Android bond, clear the saved id/name and the toy's claim
  /// key kept on this phone, and go to [ToyPhase.noToy]. (On iOS the parent
  /// must also forget Smarty in Settings → Bluetooth to set it up again
  /// later.)
  Future<void> forgetToy() async {
    _sessionGen++;
    _watchFuture = null;
    _repairToyId = null;
    // Its claim key goes too — by its id when it was read, else its name.
    final String? toyId = savedToyDeviceId;
    final String? toyName = toyId == null ? savedToyName : null;
    if (toyId != null || toyName != null) {
      unawaited(_claimKeys
          .forgetClaimKey(deviceId: toyId, bleName: toyName)
          .catchError((Object e) {
        debugPrint("⚠️ BleManager: dropping the claim key failed: $e");
      }));
    }
    final device = _connectedDevice ??
        (_savedToyId != null ? BluetoothDevice.fromId(_savedToyId!) : null);
    // A direct connect still in flight (setup page) — cancel it too.
    final connecting = _connectingDevice;
    _connectingDevice = null;
    if (connecting != null && connecting.remoteId != device?.remoteId) {
      try {
        await _disconnectOwn(connecting);
      } catch (_) {}
    }
    await _cancelPendingConnect();
    // Reset FIRST: cancels the connection-state listener so the intentional
    // disconnect below doesn't fire the link-lost handler, which would re-arm
    // a connect to the toy we're forgetting.
    _resetConnectionState();
    _unwatchLink();
    _consecutiveFailures = 0;
    if (device != null) {
      try {
        await _disconnectOwn(device);
      } catch (e) {
        debugPrint("BleManager: Error disconnecting: $e");
      }
      // Remove OS-level bond on Android (iOS manages bonds internally)
      if (Platform.isAndroid) {
        try {
          await device.removeBond();
          debugPrint("BleManager: Bond removed on Android");
        } catch (e) {
          debugPrint("BleManager: Bond removal failed: $e");
        }
      }
    }
    try {
      await clearSavedDevice();
    } catch (e) {
      // The in-memory copy is already cleared; don't let a prefs error
      // escape (callers expect forgetToy to always land on noToy).
      debugPrint("⚠️ BleManager: clearing the saved toy failed: $e");
    }
    _wifiStatusController.add("NotConnected");
    _wifiStatusMessageController.add("Device forgotten");
    _setPhase(ToyPhase.noToy);
  }

  /// Tear down the current BLE session without killing the singleton (sign-out,
  /// app detach): cancels the pending connect and the adapter watch, drops the
  /// link. The stream controllers are process-lifetime and must NEVER be
  /// closed: this singleton survives logout/login, and closed broadcast
  /// controllers cannot be reopened (closing them here bricked BLE until app
  /// restart). The next [watchSavedToy] (after sign-in) settles [phase].
  Future<void> disconnectAndReset() async {
    _sessionGen++;
    _watchFuture = null;
    final device = _connectedDevice;
    // A direct connect still in flight has no _connectedDevice yet — cancel
    // it, or the link would come up under the next account.
    final connecting = _connectingDevice;
    _connectingDevice = null;
    await _cancelPendingConnect();
    await _adapterSub?.cancel();
    _adapterSub = null;
    _waitingForAdapter = false;
    // Reset FIRST: cancels the connection-state listener so the intentional
    // disconnect below doesn't fire the link-lost handler (which would re-arm
    // a reconnect right after logout).
    _resetConnectionState();
    _unwatchLink();
    _consecutiveFailures = 0;
    _savedToyId = null;
    _savedToyName = null;
    _lastKnownWifiName = null;
    _lastWifiToyId = null;
    _lastSeenToyId = null;
    _lastSeenAdvert = null;
    _lastSeenAt = null;
    _wifiStatusController.add("NotConnected");
    final toDrop = <BluetoothDevice>[
      if (device != null) device,
      if (connecting != null && connecting.remoteId != device?.remoteId)
        connecting,
    ];
    for (final d in toDrop) {
      try {
        await _disconnectOwn(d);
      } catch (e) {
        debugPrint("BleManager: Error disconnecting during reset: $e");
      }
    }
    _setPhase(ToyPhase.probing);
  }
}

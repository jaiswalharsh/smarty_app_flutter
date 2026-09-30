import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../dev_config.dart';
import 'ble_manager.dart';

/// A toy linked to the signed-in account (`parents/{uid}/devices/{id}`) —
/// what lets a freshly installed app (or a new phone) recognise the parent's
/// own Smarty before connecting to it.
@immutable
class KnownToy {
  const KnownToy({required this.deviceId, this.bleName});

  /// The toy's own id (its base MAC as 12 lowercase hex, read over Bluetooth
  /// as ab06) — the id its cloud records are filed under.
  final String deviceId;

  /// The name the toy shows over Bluetooth ("Smarty-B11E"), or null when it
  /// can't be told (see [knownToyFromRecord]).
  final String? bleName;

  /// Whether a toy advertising [name] is this one (case and surrounding
  /// spaces ignored).
  bool matchesName(String? name) {
    final String? mine = bleName;
    if (mine == null || name == null) return false;
    return name.trim().toUpperCase() == mine.toUpperCase();
  }

  @override
  bool operator ==(Object other) =>
      other is KnownToy &&
      other.deviceId == deviceId &&
      other.bleName == bleName;

  @override
  int get hashCode => Object.hash(deviceId, bleName);

  @override
  String toString() => 'KnownToy($deviceId, $bleName)';
}

final RegExp _deviceIdPattern = RegExp(r'^[0-9a-f]{12}$');
final RegExp _bleNamePattern = RegExp(
  r'^smarty-([0-9a-f]{4})$',
  caseSensitive: false,
);

/// The toy's Bluetooth name ("Smarty-XXXX") worked out from its cloud
/// [deviceId], or null when [deviceId] isn't 12 hex characters. Pure.
///
/// The firmware names the toy after the last two bytes of its Bluetooth
/// address (bt_setup.c: `"Smarty-%02X%02X", mac[4], mac[5]` of
/// `esp_read_mac(ESP_MAC_BT)`), while [deviceId] is the chip's base address
/// (firebase_sync.c). ESP-IDF makes the Bluetooth address by adding 2 to the
/// LAST BYTE only (mac_addr.c: `mac[5] += MAC_ADDR_UNIVERSE_BT_OFFSET` on a
/// `uint8_t`), so that byte wraps around (0xFE → 0x00, 0xFF → 0x01) with no
/// carry into the byte before it: 1cc3abc9b11c → "Smarty-B11E",
/// 1cc3abc9b1ff → "Smarty-B101".
String? bleNameFromDeviceId(String deviceId) {
  final String id = deviceId.trim().toLowerCase();
  if (!_deviceIdPattern.hasMatch(id)) return null;
  final int byte4 = int.parse(id.substring(8, 10), radix: 16);
  final int byte5 = (int.parse(id.substring(10, 12), radix: 16) + 2) & 0xFF;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0').toUpperCase();
  return 'Smarty-${hex(byte4)}${hex(byte5)}';
}

/// [raw] as a toy's Bluetooth name in the firmware's spelling
/// ("Smarty-B11E"), or null when it isn't one. Pure.
String? normalizeBleName(String? raw) {
  final m = _bleNamePattern.firstMatch((raw ?? '').trim());
  return m == null ? null : 'Smarty-${m.group(1)!.toUpperCase()}';
}

/// One `parents/{uid}/devices/{id}` record as a [KnownToy]: the stored
/// `ble_name` (registerDevice keeps the name the app saw when it linked the
/// toy) when it is a real toy name, else the name worked out from the id
/// ([bleNameFromDeviceId]). Pure.
KnownToy knownToyFromRecord(String id, Map<String, dynamic> data) {
  final Object? stored = data['ble_name'];
  return KnownToy(
    deviceId: id,
    bleName:
        normalizeBleName(stored is String ? stored : null) ??
        bleNameFromDeviceId(id),
  );
}

/// Whether a `parents/{uid}/devices/{id}` record was released by the parent
/// ("I don't have this Smarty any more" while keeping its chats — the
/// `unregisterDevice` function marks it `released: true`). Such a record only
/// keeps the old chats readable: the toy is no longer linked to the account.
/// Pure.
bool isReleasedRecord(Map<String, dynamic> data) => data['released'] == true;

/// The account's toys from its records, in the given order, released ones
/// ([isReleasedRecord]) left out. Pure.
List<KnownToy> knownToysFromRecords(
  List<(String, Map<String, dynamic>)> records,
) => [
  for (final (id, data) in records)
    if (!isReleasedRecord(data)) knownToyFromRecord(id, data),
];

/// Whether the toy [deviceId] (Bluetooth name [bleName], if known) is the one
/// saved on this phone. Pure. No toy saved ([savedToyId], the phone's
/// Bluetooth handle, is null) → false. When the saved toy's own id has been
/// read this session ([savedToyDeviceId]) the ids decide; otherwise its name
/// ([savedToyName], e.g. "Smarty-B11E") is compared with [bleName], or with
/// the name worked out from [deviceId] ([bleNameFromDeviceId]).
bool isSavedToy({
  required String deviceId,
  String? bleName,
  required String? savedToyId,
  String? savedToyDeviceId,
  String? savedToyName,
}) {
  if (savedToyId == null) return false;
  if (savedToyDeviceId != null) return savedToyDeviceId == deviceId;
  final String? saved = normalizeBleName(savedToyName);
  if (saved == null) return false;
  return saved == (normalizeBleName(bleName) ?? bleNameFromDeviceId(deviceId));
}

/// The id of the toy in [toys] called [name] ("Smarty-B11E"), or null when
/// none is (or [name] is null). Pure.
String? knownToyIdNamed(List<KnownToy> toys, String? name) {
  for (final t in toys) {
    if (t.matchesName(name)) return t.deviceId;
  }
  return null;
}

/// Why taking a toy off the account failed ([RemoveToyException]).
enum RemoveToyProblem {
  /// No answer from our server (offline, timeout).
  network,

  /// Signed out, or the sign-in is no longer accepted (HTTP 401).
  signInAgain,

  /// Our server answered with an error.
  server,

  /// The app couldn't tell which of the account's toys this is (Home's ⋯
  /// menu on a toy whose id hasn't been read and whose name matches none of
  /// the account's toys — not linked, or the account couldn't be read).
  notOnAccount,
}

class RemoveToyException implements Exception {
  const RemoveToyException(this.problem);
  final RemoveToyProblem problem;

  /// Parent-facing text: what happened and what to do.
  String get message => switch (problem) {
    RemoveToyProblem.network =>
      "We couldn't reach Smarty's server. Check your internet and try again.",
    RemoveToyProblem.signInAgain => 'Please sign in again, then try again.',
    RemoveToyProblem.server =>
      'Something went wrong on our side. Please try again in a minute.',
    RemoveToyProblem.notOnAccount =>
      "We couldn't find this Smarty on your account. Turn it on, keep it close "
          'to your phone and try again — or use Forget this Smarty to take it '
          'off this phone only.',
  };

  @override
  String toString() => 'RemoveToyException($problem)';
}

/// How long to wait for the `unregisterDevice` Cloud Function.
const Duration removeToyTimeout = Duration(seconds: 10);

/// The body `unregisterDevice` takes. Pure.
Map<String, Object> removeToyRequestBody(
  String deviceId, {
  required bool keepHistory,
}) => {'device_id': deviceId, 'keep_history': keepHistory};

/// Asks our server to take the toy [deviceId] off the signed-in account
/// (the app can't: the database rules deny client writes). POSTs to the
/// `unregisterDevice` Cloud Function with [idToken]; [keepHistory] keeps its
/// chats in the Conversations tab.
///
/// Returns on HTTP 200 — and on 404 "Device not found": the toy isn't on the
/// account (any more), e.g. a retry after a removal whose answer got lost.
/// (Any other 404 — say the function isn't there — is a server problem.)
/// Otherwise throws [RemoveToyException]: no internet or a timeout →
/// [RemoveToyProblem.network], 401 → [RemoveToyProblem.signInAgain], anything
/// else → [RemoveToyProblem.server]. [client] and [url] are for tests.
Future<void> requestToyRemovalOnServer(
  String idToken,
  String deviceId, {
  required bool keepHistory,
  http.Client? client,
  String? url,
  Duration timeout = removeToyTimeout,
}) async {
  final http.Client c = client ?? http.Client();
  final http.Response response;
  try {
    response = await c
        .post(
          Uri.parse(url ?? DevConfig.functionUrl('unregisterDevice')),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $idToken',
          },
          body: jsonEncode(
            removeToyRequestBody(deviceId, keepHistory: keepHistory),
          ),
        )
        .timeout(timeout);
  } on TimeoutException {
    debugPrint('KnownToys: unregisterDevice timed out');
    throw const RemoveToyException(RemoveToyProblem.network);
  } catch (e) {
    // SocketException, ClientException, … — no way through to the server.
    debugPrint('KnownToys: unregisterDevice request failed: $e');
    throw const RemoveToyException(RemoveToyProblem.network);
  } finally {
    if (client == null) c.close();
  }
  final int status = response.statusCode;
  if (status == 200) return;
  if (status == 404 && response.body.trim() == 'Device not found') {
    debugPrint('KnownToys: $deviceId was not on the account (any more)');
    return;
  }
  debugPrint('KnownToys: unregisterDevice HTTP $status');
  throw RemoveToyException(
    status == 401 ? RemoveToyProblem.signInAgain : RemoveToyProblem.server,
  );
}

/// What Home and the setup page ask about the account's toys. The app uses
/// [KnownToysService]; tests use a fake.
abstract class KnownToys {
  /// Toys linked to the signed-in account, most recently linked first. []
  /// when there are none — and also when signed out, offline with nothing
  /// cached, slow (see [KnownToysService.timeout]) or on any error: callers
  /// then simply offer a plain setup. Toys the parent removed while keeping
  /// their chats ([isReleasedRecord]) are not listed.
  Future<List<KnownToy>> knownToysForAccount();

  /// "I don't have this Smarty any more" / "Remove from my account": takes
  /// the toy [deviceId] off the signed-in account so another family can set
  /// it up; [keepHistory] keeps its chats in the Conversations tab. On
  /// success the account's toys are read afresh next time, and when the toy
  /// is the one saved on this phone, the phone forgets it too. Throws
  /// [RemoveToyException] (nothing changed; trying again is safe).
  Future<void> removeFromAccount(String deviceId, {required bool keepHistory});

  /// Whether Home may offer "Reconnect your Smarty" now. false after the
  /// parent forgot their Smarty on purpose ([holdBackReconnectOffer]) —
  /// until the app is next launched, or another account signs in.
  bool get offerReconnect;

  /// The parent just forgot their Smarty (⋯ → Forget this Smarty): don't
  /// offer to reconnect it straight away. In memory only, for the account
  /// signed in now.
  void holdBackReconnectOffer();
}

/// One read of the account's toy records: (id, fields) per record, and
/// whether the answer came from the phone's offline copy.
typedef ToyRecords =
    ({List<(String, Map<String, dynamic>)> records, bool fromCache});

/// [KnownToys] from Firestore: `parents/{uid}/devices` (registerDevice
/// writes a record per linked toy; the parent may read their own). Read once
/// per account and kept in memory; [forgetCachedToys] after a link changes.
class KnownToysService implements KnownToys {
  KnownToysService({
    FirebaseFirestore? db,
    FirebaseAuth? auth,
    @visibleForTesting String? Function()? currentUid,
    @visibleForTesting Future<ToyRecords> Function(String uid)? read,
    @visibleForTesting Future<String?> Function()? freshIdToken,
    @visibleForTesting http.Client? httpClient,
    @visibleForTesting
    bool Function(String deviceId, String? bleName)? isSavedToyCheck,
    @visibleForTesting Future<void> Function()? forgetSavedToy,
    this.timeout = defaultTimeout,
  }) : _dbOverride = db,
       _authOverride = auth,
       _currentUidOverride = currentUid,
       _readOverride = read,
       _freshIdTokenOverride = freshIdToken,
       _httpClient = httpClient,
       _isSavedToyOverride = isSavedToyCheck,
       _forgetSavedToyOverride = forgetSavedToy;

  /// The one the app uses (Home and the setup page share its memory).
  static final KnownToysService instance = KnownToysService();

  /// How long one read may take before it counts as "none".
  static const Duration defaultTimeout = Duration(seconds: 5);

  final Duration timeout;

  final FirebaseFirestore? _dbOverride;
  final FirebaseAuth? _authOverride;
  final String? Function()? _currentUidOverride;
  final Future<ToyRecords> Function(String uid)? _readOverride;
  final Future<String?> Function()? _freshIdTokenOverride;
  final http.Client? _httpClient;
  final bool Function(String deviceId, String? bleName)? _isSavedToyOverride;
  final Future<void> Function()? _forgetSavedToyOverride;

  // Answers per account (uid), and reads in flight. [_gen] is bumped by
  // [forgetCachedToys], so a read started before it isn't kept.
  final Map<String, List<KnownToy>> _cache = {};
  final Map<String, Future<List<KnownToy>>> _inFlight = {};
  int _gen = 0;

  // The account whose parent forgot their Smarty this session ('' when the
  // account couldn't be told) — see [holdBackReconnectOffer].
  String? _heldBackFor;

  // Resolved lazily, so constructing the service never touches Firebase.
  FirebaseFirestore get _db => _dbOverride ?? FirebaseFirestore.instance;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  String? _uid() {
    final override = _currentUidOverride;
    return override != null ? override() : _auth.currentUser?.uid;
  }

  // The signed-in account, or null (signed out, or Firebase not available).
  String? _uidOrNull() {
    try {
      return _uid();
    } catch (e) {
      debugPrint('KnownToys: no account: $e');
      return null;
    }
  }

  Future<ToyRecords> _read(String uid) async {
    final override = _readOverride;
    if (override != null) return override(uid);
    final snap =
        await _db.collection('parents').doc(uid).collection('devices').get();
    // Most recently linked first (same order Conversations picks from).
    final docs =
        snap.docs.toList()..sort((a, b) {
          final ta = a.data()['registered_at'], tb = b.data()['registered_at'];
          if (ta is Timestamp && tb is Timestamp) return tb.compareTo(ta);
          if (ta is Timestamp) return -1;
          if (tb is Timestamp) return 1;
          return a.id.compareTo(b.id);
        });
    return (
      records: [for (final d in docs) (d.id, d.data())],
      fromCache: snap.metadata.isFromCache,
    );
  }

  @override
  Future<List<KnownToy>> knownToysForAccount() {
    final String? uid = _uidOrNull();
    if (uid == null) return Future.value(const []);
    final List<KnownToy>? cached = _cache[uid];
    if (cached != null) return Future.value(cached);
    final Future<List<KnownToy>>? running = _inFlight[uid];
    if (running != null) return running;
    final Future<List<KnownToy>> look = _lookUp(uid, _gen);
    _inFlight[uid] = look;
    look.whenComplete(() {
      if (identical(_inFlight[uid], look)) _inFlight.remove(uid);
    });
    return look;
  }

  Future<List<KnownToy>> _lookUp(String uid, int gen) async {
    try {
      final ToyRecords found = await _read(uid).timeout(timeout);
      final List<KnownToy> toys = List.unmodifiable(
        knownToysFromRecords(found.records),
      );
      // An empty answer from the phone's offline copy may just mean it never
      // saw the records: ask again next time rather than remember "none".
      // Nor keep an answer from before [forgetCachedToys].
      if (gen == _gen && (!found.fromCache || toys.isNotEmpty)) {
        _cache[uid] = toys;
      }
      debugPrint(
        'KnownToys: ${toys.length} on this account '
        '(from cache: ${found.fromCache}) $toys',
      );
      return toys;
    } on TimeoutException {
      debugPrint('KnownToys: no answer within ${timeout.inSeconds} s');
      return const [];
    } catch (e) {
      debugPrint('KnownToys: read failed: $e');
      return const [];
    }
  }

  // A force-refreshed ID token of the signed-in parent, or null when signed
  // out. Throws what Firebase Auth throws.
  Future<String?> _freshIdToken() async {
    final override = _freshIdTokenOverride;
    if (override != null) return override();
    return _auth.currentUser?.getIdToken(true);
  }

  bool _isSavedToy(String deviceId, String? bleName) {
    final override = _isSavedToyOverride;
    if (override != null) return override(deviceId, bleName);
    final ble = BleManager();
    return isSavedToy(
      deviceId: deviceId,
      bleName: bleName,
      savedToyId: ble.savedToyId,
      savedToyDeviceId: ble.savedToyDeviceId,
      savedToyName: ble.savedToyName,
    );
  }

  @override
  Future<void> removeFromAccount(
    String deviceId, {
    required bool keepHistory,
  }) async {
    String? idToken;
    try {
      idToken = await _freshIdToken();
    } on FirebaseAuthException catch (e) {
      debugPrint('KnownToys: token refresh before removal failed: ${e.code}');
      throw RemoveToyException(
        e.code == 'network-request-failed'
            ? RemoveToyProblem.network
            : RemoveToyProblem.signInAgain,
      );
    } catch (e) {
      debugPrint('KnownToys: token refresh before removal failed: $e');
      throw const RemoveToyException(RemoveToyProblem.signInAgain);
    }
    if (idToken == null) {
      throw const RemoveToyException(RemoveToyProblem.signInAgain);
    }

    // The name the account has for it, before the cache is dropped.
    String? bleName;
    for (final toys in _cache.values) {
      for (final t in toys) {
        if (t.deviceId == deviceId) bleName ??= t.bleName;
      }
    }

    await requestToyRemovalOnServer(
      idToken,
      deviceId,
      keepHistory: keepHistory,
      client: _httpClient,
    );
    debugPrint(
      'KnownToys: $deviceId removed from the account '
      '(kept history: $keepHistory)',
    );
    forgetCachedToys();

    if (_isSavedToy(deviceId, bleName)) {
      try {
        await (_forgetSavedToyOverride ?? BleManager().forgetToy)();
      } catch (e) {
        // The account part is done; the phone forgets on a later Forget.
        debugPrint('⚠️ KnownToys: forgetting the removed toy failed: $e');
      }
    }
  }

  /// Drop what was read, so the next ask reads again (a toy was just linked
  /// or removed).
  void forgetCachedToys() {
    _gen++;
    _cache.clear();
    _inFlight.clear();
  }

  @override
  bool get offerReconnect {
    final String? held = _heldBackFor;
    return held == null || held != (_uidOrNull() ?? '');
  }

  @override
  void holdBackReconnectOffer() {
    _heldBackFor = _uidOrNull() ?? '';
  }

  @visibleForTesting
  void debugReset() {
    forgetCachedToys();
    _heldBackFor = null;
  }
}

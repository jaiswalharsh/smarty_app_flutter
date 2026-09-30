import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'known_toys_service.dart' show isReleasedRecord;

/// Answers "is this toy linked to the signed-in account?" from the account's
/// own records. The toy's `registered` flag only says it holds SOME key —
/// maybe one from another account, a deleted account, or a dev emulator — so
/// it can't answer this by itself. [BleManager] asks through this interface
/// (tests use a fake).
abstract class LinkCheck {
  /// true = the toy [deviceId] is linked to this account; false = our server
  /// says it isn't; null = can't tell right now (signed out, offline, slow,
  /// or an error) — callers then keep what they had.
  Future<bool?> isLinkedToThisAccount(String deviceId);
}

/// One look-up of the account's record for a toy: whether it exists, and
/// whether the answer came from the phone's offline copy rather than our
/// server.
typedef DeviceRecordLookup = ({bool exists, bool fromCache});

/// The answer to [LinkCheck.isLinkedToThisAccount] for one look-up (pure, for
/// tests). A missing record only counts when our server said so: the phone's
/// offline copy may simply never have seen it, and an offline parent must not
/// be told to finish a setup they already did.
bool? linkVerdict(DeviceRecordLookup lookup) {
  if (lookup.exists) return true;
  return lookup.fromCache ? null : false;
}

/// Whether a `parents/{uid}/devices/{deviceId}` record's fields ([data], null
/// when there is no record) link the toy to that account: a record the parent
/// released while keeping its chats ([isReleasedRecord]) doesn't. Pure.
bool recordLinksToy(Map<String, dynamic>? data) =>
    data != null && !isReleasedRecord(data);

/// [LinkCheck] against Firestore: `parents/{uid}/devices/{deviceId}` exists
/// (and isn't released — see [recordLinksToy]) exactly when the toy is linked
/// to that account (registerDevice writes it, unregisterDevice releases or
/// removes it, deleteAccount removes it). One read, server first (the default
/// source), bounded by [timeout].
class LinkCheckService implements LinkCheck {
  LinkCheckService({
    FirebaseFirestore? db,
    FirebaseAuth? auth,
    @visibleForTesting String? Function()? currentUid,
    @visibleForTesting
    Future<DeviceRecordLookup> Function(String uid, String deviceId)? lookup,
    this.timeout = defaultTimeout,
  }) : _dbOverride = db,
       _authOverride = auth,
       _currentUidOverride = currentUid,
       _lookupOverride = lookup;

  /// How long one check may take before it counts as "can't tell".
  static const Duration defaultTimeout = Duration(seconds: 5);

  final Duration timeout;

  final FirebaseFirestore? _dbOverride;
  final FirebaseAuth? _authOverride;
  final String? Function()? _currentUidOverride;
  final Future<DeviceRecordLookup> Function(String uid, String deviceId)?
  _lookupOverride;

  // Resolved lazily, so constructing the service never touches Firebase.
  FirebaseFirestore get _db => _dbOverride ?? FirebaseFirestore.instance;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  String? _uid() {
    final override = _currentUidOverride;
    return override != null ? override() : _auth.currentUser?.uid;
  }

  Future<DeviceRecordLookup> _lookup(String uid, String deviceId) async {
    final override = _lookupOverride;
    if (override != null) return override(uid, deviceId);
    final snap =
        await _db
            .collection('parents')
            .doc(uid)
            .collection('devices')
            .doc(deviceId)
            .get();
    return (
      exists: recordLinksToy(snap.exists ? snap.data() : null),
      fromCache: snap.metadata.isFromCache,
    );
  }

  @override
  Future<bool?> isLinkedToThisAccount(String deviceId) async {
    if (deviceId.trim().isEmpty) return null;
    try {
      final String? uid = _uid();
      if (uid == null) {
        debugPrint('LinkCheck: signed out — can\'t tell');
        return null;
      }
      final DeviceRecordLookup found = await _lookup(
        uid,
        deviceId,
      ).timeout(timeout);
      final bool? verdict = linkVerdict(found);
      debugPrint(
        'LinkCheck: toy $deviceId on this account: $verdict '
        '(exists: ${found.exists}, from cache: ${found.fromCache})',
      );
      return verdict;
    } on TimeoutException {
      debugPrint('LinkCheck: no answer within ${timeout.inSeconds} s');
      return null;
    } catch (e) {
      debugPrint('LinkCheck: check failed: $e');
      return null;
    }
  }
}

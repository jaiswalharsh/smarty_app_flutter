import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/conversation.dart';
import 'ble_manager.dart';

/// The parent is signed out (or the session is no longer accepted): the UI
/// shows a sign-in prompt instead of an error. See [convosNeedsSignIn].
class ConvosSignedOut implements Exception {
  const ConvosSignedOut();
  @override
  String toString() => 'ConvosSignedOut';
}

/// Whether [error] (from a [ConvosSource] stream or future) means "sign in
/// again" rather than "something broke".
bool convosNeedsSignIn(Object? error) {
  if (error is ConvosSignedOut) return true;
  if (error is FirebaseException) {
    return error.code == 'permission-denied' ||
        error.code == 'unauthenticated';
  }
  return false;
}

/// What the Convos screens read. [ConvosService] reads Firestore; tests use
/// a fake.
abstract class ConvosSource {
  /// The toy whose chats to show, or null when this account has none.
  /// Throws [ConvosSignedOut] when signed out.
  Future<String?> resolveDeviceId();

  /// Days with chats, newest first, at most [limit].
  Stream<List<ConvoDay>> watchDays(String deviceId, {int limit = 30});

  /// The play sessions filed under [day] ("YYYY-MM-DD"), in any order —
  /// [mergeDayChat] orders them.
  Stream<List<Conversation>> watchDay(String deviceId, String day);

  /// The messages of one play session, in transcript order ([sortTurns]).
  Stream<List<ConversationTurn>> watchTurns(String deviceId, String sessionId);

  /// The most recent day with chats (normally today), or null when none.
  Stream<ConvoDay?> watchToday(String deviceId);
}

/// Reads chat history from Firestore:
/// `parents/{uid}/devices/{deviceId}/{days, conversations/*/turns}` — each
/// method is one realtime listener scoped to what one screen shows.
class ConvosService implements ConvosSource {
  ConvosService({FirebaseFirestore? db, FirebaseAuth? auth})
      : _dbOverride = db,
        _authOverride = auth;

  final FirebaseFirestore? _dbOverride;
  final FirebaseAuth? _authOverride;

  // Resolved lazily, so constructing the service never touches Firebase.
  FirebaseFirestore get _db => _dbOverride ?? FirebaseFirestore.instance;
  FirebaseAuth get _auth => _authOverride ?? FirebaseAuth.instance;

  CollectionReference<Map<String, dynamic>> _devices() {
    final String? uid = _auth.currentUser?.uid;
    if (uid == null) throw const ConvosSignedOut();
    return _db.collection('parents').doc(uid).collection('devices');
  }

  DocumentReference<Map<String, dynamic>> _device(String deviceId) =>
      _devices().doc(deviceId);

  /// Lifts a synchronous [ConvosSignedOut] (or any setup error) into the
  /// stream, so the UI handles it like any other stream error.
  Stream<T> _guard<T>(Stream<T> Function() open) {
    try {
      return open();
    } catch (e, st) {
      return Stream<T>.error(e, st);
    }
  }

  /// The saved toy's own id when it has been read over Bluetooth this
  /// session and is linked to this account; otherwise the most recently
  /// linked toy on the account.
  @override
  Future<String?> resolveDeviceId() async {
    final devices = _devices();
    final snap = await devices.get();
    if (snap.docs.isEmpty) return null;
    final String? ble = BleManager().savedToyDeviceId;
    if (ble != null && snap.docs.any((d) => d.id == ble)) return ble;
    final docs = snap.docs.toList()
      ..sort((a, b) {
        final ta = a.data()['registered_at'], tb = b.data()['registered_at'];
        if (ta is Timestamp && tb is Timestamp) return tb.compareTo(ta);
        if (ta is Timestamp) return -1;
        if (tb is Timestamp) return 1;
        return a.id.compareTo(b.id);
      });
    debugPrint('Convos: showing toy ${docs.first.id} '
        '(${snap.docs.length} on the account)');
    return docs.first.id;
  }

  @override
  Stream<List<ConvoDay>> watchDays(String deviceId, {int limit = 30}) =>
      _guard(() => _device(deviceId)
          .collection('days')
          .orderBy('day', descending: true)
          .limit(limit)
          .snapshots()
          .map((s) => [
                for (final d in s.docs) ConvoDay.fromMap(d.id, d.data()),
              ]));

  /// Newest first, matching the deployed (day ASC, started_at DESC) index;
  /// the page re-orders them.
  @override
  Stream<List<Conversation>> watchDay(String deviceId, String day) =>
      _guard(() => _device(deviceId)
          .collection('conversations')
          .where('day', isEqualTo: day)
          .orderBy('started_at', descending: true)
          .snapshots()
          .map((s) => [
                for (final d in s.docs) Conversation.fromMap(d.id, d.data()),
              ]));

  /// Listens to the whole `turns` collection (one chat is tens of messages)
  /// and sorts on the phone: an `orderBy('press_seq')` query would silently
  /// drop turns from older firmware, which have no `press_seq`.
  @override
  Stream<List<ConversationTurn>> watchTurns(
          String deviceId, String sessionId) =>
      _guard(() => _device(deviceId)
          .collection('conversations')
          .doc(sessionId)
          .collection('turns')
          .snapshots()
          .map((s) => sortTurns([
                for (final d in s.docs)
                  ConversationTurn.fromMap(d.id, d.data()),
              ])));

  /// The newest `days` doc rather than the phone's own date, so it matches
  /// whatever day the backend filed the current chat under.
  @override
  Stream<ConvoDay?> watchToday(String deviceId) =>
      watchDays(deviceId, limit: 1)
          .map((days) => days.isEmpty ? null : days.first);
}

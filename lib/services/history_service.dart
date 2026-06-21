import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/conversation.dart';

/// Reads conversation history from Firestore — the app's first Firestore read
/// path (Stitch migration plan Phase 2a).
///
/// Data model (written by the firmware via the `turn` Cloud Function):
///   parents/{uid}/devices/{deviceId}/conversations/{convId}/turns/{auto}
/// The device is resolved by listing the parent's `devices` collection rather
/// than over BLE, so History works without the toy connected.
class HistoryService {
  HistoryService({FirebaseFirestore? db, FirebaseAuth? auth})
      : _db = db ?? FirebaseFirestore.instance,
        _auth = auth ?? FirebaseAuth.instance;

  final FirebaseFirestore _db;
  final FirebaseAuth _auth;

  String? get _uid => _auth.currentUser?.uid;

  CollectionReference<Map<String, dynamic>>? _devicesRef() {
    final uid = _uid;
    if (uid == null) return null;
    return _db.collection('parents').doc(uid).collection('devices');
  }

  /// The first registered device id for the current parent, or null if none.
  ///
  /// v1 assumes a single toy per account (the common case); multi-device
  /// selection is a future enhancement.
  Future<String?> firstDeviceId() async {
    final devices = _devicesRef();
    if (devices == null) return null;
    final snap = await devices.limit(1).get();
    if (snap.docs.isEmpty) return null;
    return snap.docs.first.id; // doc id == device_id
  }

  /// Conversations for a device, newest first. Conversations missing the
  /// `last_message_at` field (e.g. legacy/empty docs) are naturally excluded.
  Stream<List<Conversation>> watchConversations(String deviceId) {
    final devices = _devicesRef();
    if (devices == null) return const Stream.empty();
    return devices
        .doc(deviceId)
        .collection('conversations')
        .orderBy('last_message_at', descending: true)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => Conversation.fromDoc(d)).toList());
  }

  /// Turns within a conversation, oldest first (chat transcript order).
  Stream<List<ConversationTurn>> watchTurns(String deviceId, String convId) {
    final devices = _devicesRef();
    if (devices == null) return const Stream.empty();
    return devices
        .doc(deviceId)
        .collection('conversations')
        .doc(convId)
        .collection('turns')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((snap) =>
            snap.docs.map((d) => ConversationTurn.fromDoc(d)).toList());
  }
}

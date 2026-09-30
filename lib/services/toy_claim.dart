import 'dart:convert';

import 'package:crypto/crypto.dart';

// The claim: how a phone proves to a toy that it is signed in to the toy's
// account, so the toy lets it pair. The toy's claim characteristic (0xAB07,
// unencrypted) gives a fresh nonce per connection; the phone answers with
// HMAC-SHA256 over that nonce, keyed with the account's claim key for the
// toy — the `device_secret_hash` of `parents/{uid}/devices/{device_id}`,
// which the toy can work out from the secret it holds. Nothing secret goes
// over the air, and a phone of another account has no key.

/// Bytes of the nonce the claim characteristic gives.
const int claimNonceLength = 16;

/// Bytes of the proof written back ([claimProof]).
const int claimProofLength = 32;

final RegExp _claimKeyPattern = RegExp(r'^[0-9a-f]{64}$');

/// Whether [value] is a claim key: 64 lowercase hex characters (a SHA-256
/// hex digest, as the backend stores `device_secret_hash`). Pure.
bool isClaimKey(Object? value) =>
    value is String && _claimKeyPattern.hasMatch(value);

/// The claim key for a device secret: SHA-256 of the secret's UTF-8 bytes,
/// lowercase hex — what registerDevice stores as `device_secret_hash`. Lets
/// the phone that links a toy remember the key without asking the cloud.
/// Pure.
String claimKeyFromSecret(String secret) =>
    sha256.convert(utf8.encode(secret)).toString();

/// The proof for [nonce]: HMAC-SHA256 keyed with [claimKey]'s ASCII bytes
/// (the 64 hex characters themselves, not the digest they spell), over the
/// nonce's raw bytes. [claimProofLength] raw bytes. Pure.
List<int> claimProof(String claimKey, List<int> nonce) =>
    Hmac(sha256, ascii.encode(claimKey)).convert(nonce).bytes;

/// Where BleManager gets the claim key for a toy it is about to connect. The
/// app uses KnownToysService (a per-account cache on the phone, else the
/// account's records); tests use a fake.
abstract class ClaimKeys {
  /// The signed-in account's claim key for the toy with the id [deviceId]
  /// (ab06, when known) or the Bluetooth name [bleName] ("Smarty-B11E"), or
  /// null: signed out, not one of the account's toys, or no key at hand
  /// (offline and never read).
  Future<String?> claimKeyFor({String? deviceId, String? bleName});

  /// The toy turned the key down (or the toy is gone): drop it, so the next
  /// look-up asks the account's records afresh.
  Future<void> forgetClaimKey({String? deviceId, String? bleName});
}

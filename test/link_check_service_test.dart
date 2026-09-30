// "Is this toy linked to THIS account?" — the account-record check that keeps
// a toy holding someone else's (or a dev emulator's) key from counting as
// set up. Firestore itself is replaced by a fake look-up.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/services/link_check_service.dart';

void main() {
  group('linkVerdict', () {
    test('a record means linked, wherever the answer came from', () {
      expect(linkVerdict((exists: true, fromCache: false)), isTrue);
      expect(linkVerdict((exists: true, fromCache: true)), isTrue);
    });

    test('no record: "not linked" only when our server said so', () {
      expect(linkVerdict((exists: false, fromCache: false)), isFalse);
      // The phone's offline copy may never have seen the record.
      expect(linkVerdict((exists: false, fromCache: true)), isNull);
    });
  });

  group('recordLinksToy', () {
    test('a record links the toy; none, or a released one, does not', () {
      expect(recordLinksToy({'device_id': 'x'}), isTrue);
      expect(recordLinksToy({'released': false}), isTrue);
      expect(recordLinksToy(null), isFalse);
      // "I don't have this Smarty any more", chats kept: only the chats stay.
      expect(recordLinksToy({'device_id': 'x', 'released': true}), isFalse);
    });
  });

  group('LinkCheckService', () {
    LinkCheckService service({
      String? uid = 'parent-1',
      Future<DeviceRecordLookup> Function(String uid, String id)? lookup,
      Duration timeout = LinkCheckService.defaultTimeout,
      List<String>? asked,
    }) => LinkCheckService(
      currentUid: () => uid,
      lookup:
          lookup ??
          (u, id) async {
            asked?.add('$u/$id');
            return (exists: id == 'toy-mine', fromCache: false);
          },
      timeout: timeout,
    );

    test("looks in the signed-in parent's own records", () async {
      final asked = <String>[];
      final s = service(asked: asked);
      expect(await s.isLinkedToThisAccount('toy-mine'), isTrue);
      expect(await s.isLinkedToThisAccount('toy-emulator-key'), isFalse);
      expect(asked, ['parent-1/toy-mine', 'parent-1/toy-emulator-key']);
    });

    test("signed out: can't tell, and nothing is looked up", () async {
      final asked = <String>[];
      final s = service(uid: null, asked: asked);
      expect(await s.isLinkedToThisAccount('toy-mine'), isNull);
      expect(asked, isEmpty);
    });

    test("an empty toy id: can't tell", () async {
      expect(await service().isLinkedToThisAccount('  '), isNull);
    });

    test("offline answer without the record: can't tell", () async {
      final s = service(
        lookup: (_, __) async => (exists: false, fromCache: true),
      );
      expect(await s.isLinkedToThisAccount('toy-mine'), isNull);
    });

    test("an error: can't tell", () async {
      final s = service(lookup: (_, __) async => throw StateError('offline'));
      expect(await s.isLinkedToThisAccount('toy-mine'), isNull);
    });

    test("no answer in time: can't tell", () async {
      final never = Completer<DeviceRecordLookup>();
      final s = service(
        lookup: (_, __) => never.future,
        timeout: const Duration(milliseconds: 20),
      );
      expect(await s.isLinkedToThisAccount('toy-mine'), isNull);
    });

    test('the default wait is about 5 seconds', () {
      expect(LinkCheckService.defaultTimeout, const Duration(seconds: 5));
    });
  });
}

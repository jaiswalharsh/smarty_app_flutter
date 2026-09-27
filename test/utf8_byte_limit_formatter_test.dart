import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:smarty_app/screens/user_context_page.dart';
import 'package:smarty_app/services/ble_manager.dart';

TextEditingValue _v(String text) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: text.length),
);

void main() {
  group('Utf8ByteLimitFormatter', () {
    test('byteLength counts UTF-8 bytes, not characters', () {
      expect(Utf8ByteLimitFormatter.byteLength(''), 0);
      expect(Utf8ByteLimitFormatter.byteLength('abc'), 3);
      // Polish diacritics are 2 bytes each.
      expect(Utf8ByteLimitFormatter.byteLength('ą'), 2);
      expect(Utf8ByteLimitFormatter.byteLength('Zażółć'), 10);
      // Emoji outside the BMP is 4 bytes.
      expect(Utf8ByteLimitFormatter.byteLength('🙂'), 4);
    });

    test('allows edits up to exactly the limit', () {
      final f = Utf8ByteLimitFormatter(4);
      final result = f.formatEditUpdate(_v('ab'), _v('abą'));
      expect(result.text, 'abą'); // 4 bytes
    });

    test(
      'rejects an edit that goes over the limit and keeps the old value',
      () {
        final f = Utf8ByteLimitFormatter(4);
        final oldValue = _v('abą'); // 4 bytes
        final result = f.formatEditUpdate(oldValue, _v('abąc')); // 5 bytes
        expect(result, oldValue);
      },
    );

    test('rejects a paste of multi-byte text that exceeds the limit', () {
      final f = Utf8ByteLimitFormatter(6);
      // 4 characters but 8 bytes — a character-based limit would let it in.
      final result = f.formatEditUpdate(_v(''), _v('żółć'));
      expect(result.text, '');
    });

    test('still allows deleting when already over the limit', () {
      final f = Utf8ByteLimitFormatter(4);
      // Over-limit text can arrive programmatically (formatters don't run on
      // controller.text = ...); the user must still be able to trim it.
      final result = f.formatEditUpdate(_v('ąąąą'), _v('ąąą'));
      expect(result.text, 'ąąą');
    });

    test('does not allow growing text that is already over the limit', () {
      final f = Utf8ByteLimitFormatter(4);
      final oldValue = _v('ąąą'); // 6 bytes
      final result = f.formatEditUpdate(oldValue, _v('ąąąa'));
      expect(result, oldValue);
    });

    test('legacy limit matches the old toy profile budget (500 bytes)', () {
      expect(BleManager.userContextMaxBytesLegacy, 500);
      final f = Utf8ByteLimitFormatter(BleManager.userContextMaxBytesLegacy);
      expect(f.formatEditUpdate(_v(''), _v('a' * 500)).text.length, 500);
      expect(f.formatEditUpdate(_v(''), _v('ą' * 251)).text, '');
      expect(f.formatEditUpdate(_v(''), _v('ą' * 250)).text, 'ą' * 250);
    });

    test('with 1024 bytes and a 500-character cap, 500 Polish characters fit',
        () {
      expect(BleManager.userContextMaxBytesV1, 1024);
      final f = Utf8ByteLimitFormatter(BleManager.userContextMaxBytesV1,
          maxChars: 500);
      // 500 × "ż" = 1000 bytes: fits the byte budget and the character cap.
      expect(f.formatEditUpdate(_v(''), _v('ż' * 500)).text, 'ż' * 500);
      // One more character is past the cap, even though bytes would fit.
      expect(f.formatEditUpdate(_v('ż' * 500), _v('ż' * 501)).text, 'ż' * 500);
      expect(f.formatEditUpdate(_v(''), _v('a' * 501)).text, '');
    });

    test('the byte budget still guards emoji under the character cap', () {
      final f = Utf8ByteLimitFormatter(BleManager.userContextMaxBytesV1,
          maxChars: 500);
      // 257 × 4-byte emoji = 1028 bytes > 1024, though only 257 characters.
      expect(f.formatEditUpdate(_v(''), _v('😀' * 257)).text, '');
      expect(f.formatEditUpdate(_v(''), _v('😀' * 256)).text, '😀' * 256);
    });

    test('text already over the character cap can be trimmed, not grown', () {
      final f = Utf8ByteLimitFormatter(1024, maxChars: 5);
      final over = _v('abcdefg');
      expect(f.formatEditUpdate(over, _v('abcdef')).text, 'abcdef');
      expect(f.formatEditUpdate(over, _v('abcdefgh')), over);
    });

    test('charLength counts what the parent sees', () {
      expect(Utf8ByteLimitFormatter.charLength('żółw'), 4);
      expect(Utf8ByteLimitFormatter.charLength('👍🏽'), 1);
    });

    group('onRejected / onAccepted (so a refused paste is never silent)', () {
      late List<TextEditingValue> rejected;
      late int accepted;
      late Utf8ByteLimitFormatter f;

      setUp(() {
        rejected = [];
        accepted = 0;
        f = Utf8ByteLimitFormatter(
          1024,
          maxChars: 500,
          onRejected: rejected.add,
          onAccepted: () => accepted++,
        );
      });

      test('an appended paste past the cap fires onRejected and keeps the '
          "child's text as it was (not cut to fit)", () {
        // The owner's case: 384 characters, then a 476-character paste.
        final before = _v('a' * 384);
        final pasted = _v('a' * 384 + 'b' * 476);
        final result = f.formatEditUpdate(before, pasted);
        expect(result, before);
        expect(rejected, [pasted]);
        expect(accepted, 0);
      });

      test('an edit that fits fires onAccepted, not onRejected', () {
        final result = f.formatEditUpdate(_v('abc'), _v('abcd'));
        expect(result.text, 'abcd');
        expect(accepted, 1);
        expect(rejected, isEmpty);
      });

      test('a byte-budget rejection fires onRejected too', () {
        final small = Utf8ByteLimitFormatter(4, onRejected: rejected.add);
        small.formatEditUpdate(_v('ab'), _v('abżż'));
        expect(rejected.single.text, 'abżż');
      });

      test('no callbacks: behaves exactly as before', () {
        final plain = Utf8ByteLimitFormatter(4);
        expect(plain.formatEditUpdate(_v('ab'), _v('abżż')).text, 'ab');
      });
    });

    test('tooLongEditMessage: names the character cap when that is the limit',
        () {
      expect(tooLongEditMessage('a' * 860, maxChars: 500),
          "That's too long — Smarty can take up to 500 characters.");
      // Under the cap but over the toy's byte budget (emoji): no number a
      // parent can't count.
      expect(tooLongEditMessage('😀' * 300, maxChars: 500),
          "That's too long — Smarty can't fit any more.");
    });
  });
}

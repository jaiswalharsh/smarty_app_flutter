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

    test('app limit matches the BLE user-context budget', () {
      expect(BleManager.userContextMaxBytes, 500);
      final f = Utf8ByteLimitFormatter(BleManager.userContextMaxBytes);
      expect(f.formatEditUpdate(_v(''), _v('a' * 500)).text.length, 500);
      expect(f.formatEditUpdate(_v(''), _v('ą' * 251)).text, '');
      expect(f.formatEditUpdate(_v(''), _v('ą' * 250)).text, 'ą' * 250);
    });
  });
}

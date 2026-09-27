import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/user_context_provider.dart';
import '../services/ble_manager.dart';
import '../utils/theme_provider.dart';

/// Caps text by its UTF-8 byte length rather than its character count: the
/// toy stores the context in a fixed byte budget, and Polish letters such as
/// "ą" or "ż" take 2 bytes each, so a 500-character limit could overflow it.
///
/// Edits that would grow the text past [maxBytes] (or past [maxChars]
/// user-visible characters, when set) are rejected (the previous value is
/// kept). Edits that shrink it are always allowed, so text that is already
/// over a limit (e.g. loaded programmatically) can still be trimmed — never
/// silently cut.
///
/// A rejected edit is never trimmed to fit (a paste is all-or-nothing, so
/// the child's text is never cut mid-word), but it isn't silent either:
/// [onRejected] gets the refused value so the page can say why, and
/// [onAccepted] fires on the next edit that goes through (to clear that
/// message). The formatter itself keeps no state.
class Utf8ByteLimitFormatter extends TextInputFormatter {
  Utf8ByteLimitFormatter(
    this.maxBytes, {
    this.maxChars,
    this.onRejected,
    this.onAccepted,
  });

  final int maxBytes;

  /// Optional cap in characters (grapheme clusters, as the counter shows).
  final int? maxChars;

  /// Called with the refused value when an edit is rejected for being too
  /// long.
  final ValueChanged<TextEditingValue>? onRejected;

  /// Called when an edit that changes the text is let through.
  final VoidCallback? onAccepted;

  static int byteLength(String text) => utf8.encode(text).length;

  static int charLength(String text) => text.characters.length;

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final int newBytes = byteLength(newValue.text);
    final bool bytesOk =
        newBytes <= maxBytes || newBytes <= byteLength(oldValue.text);
    final int? charCap = maxChars;
    final bool charsOk = charCap == null ||
        charLength(newValue.text) <= charCap ||
        charLength(newValue.text) <= charLength(oldValue.text);
    if (bytesOk && charsOk) {
      if (newValue.text != oldValue.text) onAccepted?.call();
      return newValue;
    }
    onRejected?.call(newValue);
    return oldValue;
  }
}

/// Inline message under the field when an edit (usually a paste) was refused
/// for being too long. [rejectedText] is the text the edit would have made.
/// Pure (tests). Past the character cap, name it; otherwise the toy's byte
/// budget ran out first (Polish letters, emoji), which a parent can't count,
/// so just say it doesn't fit.
String tooLongEditMessage(String rejectedText, {required int maxChars}) =>
    Utf8ByteLimitFormatter.charLength(rejectedText) > maxChars
        ? "That's too long — Smarty can take up to $maxChars characters."
        : "That's too long — Smarty can't fit any more.";

/// Live "N / 500 characters" counter under the "About your child" field,
/// plus — after an edit was refused for being too long — [notice] on the
/// left (see [tooLongEditMessage]). Never shows bytes: when the toy's byte
/// budget runs out first it just says the text is as long as it can be.
class UserContextLengthCounter extends StatelessWidget {
  const UserContextLengthCounter({
    super.key,
    required this.controller,
    required this.notice,
    required this.maxBytes,
    required this.maxChars,
    required this.mutedColor,
  });

  final TextEditingController controller;

  /// The "too long" message to show, or null for none.
  final ValueListenable<String?> notice;
  final int maxBytes;
  final int maxChars;
  final Color mutedColor;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([controller, notice]),
      builder: (context, _) {
        final String text = controller.text;
        final int bytes = Utf8ByteLimitFormatter.byteLength(text);
        final int chars = Utf8ByteLimitFormatter.charLength(text);
        if (bytes > maxBytes || chars > maxChars) {
          // Already over (text set in code): Save is off; say so.
          return Align(
            alignment: Alignment.centerRight,
            child: Text(
              UserContextProvider.tooLongMessage,
              style: const TextStyle(fontSize: 12, color: Colors.red),
            ),
          );
        }
        final String label = bytes >= maxBytes
            ? "That's as long as it can be."
            : '$chars / $maxChars characters';
        final String? message = notice.value;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: message == null
                  ? const SizedBox.shrink()
                  : Text(
                      message,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.red.shade600,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            Text(label, style: TextStyle(fontSize: 12, color: mutedColor)),
          ],
        );
      },
    );
  }
}

class UserContextPage extends StatefulWidget {
  const UserContextPage({super.key});

  @override
  State<UserContextPage> createState() => _UserContextPageState();
}

class _UserContextPageState extends State<UserContextPage> {
  /// Length limit shown to parents, enforced in characters. Behind it the
  /// toy's UTF-8 byte budget ([BleManager.userContextMaxBytes] — 1024 on
  /// current firmware, so 500 Polish characters fit; 500 on older firmware)
  /// is enforced silently by [Utf8ByteLimitFormatter] as a safety net.
  static const int maxChars = 500;

  final TextEditingController _controller = TextEditingController();
  final BleManager _bleManager = BleManager();
  ToyPhase? _lastPhase;
  bool _dirty = false;
  bool _bootstrapped = false;
  // Text is over the toy's byte budget (only possible for text set in code,
  // since the input formatter blocks typing past it). Disables Save.
  bool _overLimit = false;
  // "That's too long…" under the field after an edit (usually a paste) was
  // refused; cleared by the next edit that goes through.
  final ValueNotifier<String?> _tooLongNotice = ValueNotifier<String?>(null);
  // Rebuilt when the toy's byte budget changes (e.g. a different toy).
  late Utf8ByteLimitFormatter _limitFormatter =
      _makeLimitFormatter(BleManager.userContextMaxBytesLegacy);

  Utf8ByteLimitFormatter _makeLimitFormatter(int maxBytes) =>
      Utf8ByteLimitFormatter(
        maxBytes,
        maxChars: maxChars,
        onRejected: (rejected) => _tooLongNotice.value =
            tooLongEditMessage(rejected.text, maxChars: maxChars),
        onAccepted: () => _tooLongNotice.value = null,
      );

  Utf8ByteLimitFormatter get _currentLimitFormatter {
    final int maxBytes = _bleManager.userContextMaxBytes;
    if (_limitFormatter.maxBytes != maxBytes) {
      _limitFormatter = _makeLimitFormatter(maxBytes);
    }
    return _limitFormatter;
  }

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _lastPhase = _bleManager.phase.value;

    // Load the latest from the toy after the first frame so the provider is
    // available via context.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final provider = context.read<UserContextProvider>();
      _controller.text = provider.context;
      _dirty = false;
      await _refreshFromToy();
      if (!mounted) return;
      setState(() => _bootstrapped = true);
    });

    // Update the status row on every phase change, and pick up the toy's copy
    // when it comes back (`connected` = characteristics ready to read).
    _bleManager.phase.addListener(_onPhaseChanged);
  }

  void _onPhaseChanged() {
    if (!mounted) return;
    final phase = _bleManager.phase.value;
    final reconnected =
        phase == ToyPhase.connected && _lastPhase != ToyPhase.connected;
    _lastPhase = phase;
    setState(() {});
    if (reconnected && _bootstrapped) _refreshFromToy();
  }

  // Refresh from the toy (the provider pushes a pending local edit instead
  // when there is one) and show the result unless the parent is mid-edit.
  Future<void> _refreshFromToy() async {
    if (!_bleManager.isConnected) return;
    final provider = context.read<UserContextProvider>();
    await provider.refreshFromDevice();
    if (!mounted) return;
    if (!_dirty) {
      _controller.text = provider.context;
      _dirty = false;
      _tooLongNotice.value = null; // new text: the old notice is stale
    }
  }

  void _onTextChanged() {
    final provider = context.read<UserContextProvider>();
    final nowDirty = _controller.text != provider.context;
    final nowOverLimit = Utf8ByteLimitFormatter.byteLength(_controller.text) >
            _bleManager.userContextMaxBytes ||
        Utf8ByteLimitFormatter.charLength(_controller.text) > maxChars;
    if (nowDirty != _dirty || nowOverLimit != _overLimit) {
      setState(() {
        _dirty = nowDirty;
        _overLimit = nowOverLimit;
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _tooLongNotice.dispose();
    _bleManager.phase.removeListener(_onPhaseChanged);
    super.dispose();
  }

  Future<void> _handleSave() async {
    if (_overLimit) return;
    final provider = context.read<UserContextProvider>();
    final newText = _controller.text;
    final result = await provider.save(newText);
    if (!mounted) return;
    switch (result) {
      case ContextSaveResult.sent:
        setState(() => _dirty = false);
        _showSnack('Saved.');
        break;
      case ContextSaveResult.savedPendingSync:
        setState(() => _dirty = false);
        _showSnack(UserContextProvider.savedPendingMessage);
        break;
      case ContextSaveResult.failed:
        _showSnack(
          provider.errorMessage ?? 'Something went wrong. Please try again.',
          isError: true,
        );
        break;
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red.shade600 : Colors.green.shade600,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);
    final provider = context.watch<UserContextProvider>();
    final connected = _bleManager.isConnected;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'About your child',
          style: TextStyle(
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
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                "Tell Smarty what it should know about your child.",
                style: TextStyle(
                  fontSize: 16,
                  color: themeProvider.isDarkMode
                      ? Colors.white70
                      : Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                "Smarty uses this to talk with your child in a way that suits "
                "them.",
                style: TextStyle(
                  fontSize: 13,
                  color: themeProvider.isDarkMode
                      ? Colors.white54
                      : Colors.black54,
                ),
              ),
              const SizedBox(height: 16),
              _buildStatusRow(provider, connected, themeProvider),
              const SizedBox(height: 12),
              Expanded(
                child: TextField(
                  controller: _controller,
                  maxLines: null,
                  expands: true,
                  textAlignVertical: TextAlignVertical.top,
                  // [maxChars] characters for the parent; the toy's real
                  // limit is in bytes (see Utf8ByteLimitFormatter).
                  inputFormatters: [_currentLimitFormatter],
                  enabled: _bootstrapped && !provider.isBusy,
                  decoration: InputDecoration(
                    hintText:
                        "e.g. My daughter Alex is 6, loves dinosaurs, is "
                        "learning to read, and is afraid of thunderstorms.",
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    filled: true,
                    fillColor: themeProvider.isDarkMode
                        ? const Color(0xFF2C2C44)
                        : Colors.grey.shade100,
                    contentPadding: const EdgeInsets.all(16),
                  ),
                  style: TextStyle(
                    color: themeProvider.isDarkMode
                        ? Colors.white
                        : Colors.black87,
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              _buildLengthCounter(themeProvider),
              if (provider.hasPendingSync) ...[
                const SizedBox(height: 4),
                Text(
                  "Not sent to Smarty yet — it'll go automatically when "
                  "Smarty is nearby.",
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.amber.shade700,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (provider.isBusy || !_dirty || _overLimit)
                      ? null
                      : _handleSave,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: provider.state == ContextSyncState.saving
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Save'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // Rebuilds on every keystroke via the controller, without rebuilding the
  // whole page.
  Widget _buildLengthCounter(ThemeProvider themeProvider) {
    return UserContextLengthCounter(
      controller: _controller,
      notice: _tooLongNotice,
      maxBytes: _bleManager.userContextMaxBytes,
      maxChars: maxChars,
      mutedColor: themeProvider.isDarkMode ? Colors.white54 : Colors.black54,
    );
  }

  Widget _buildStatusRow(
    UserContextProvider provider,
    bool connected,
    ThemeProvider themeProvider,
  ) {
    IconData icon;
    Color color;
    String label;

    if (!connected) {
      icon = Icons.bluetooth_disabled;
      color = Colors.blueGrey;
      label = UserContextProvider.offlineMessage;
    } else {
      switch (provider.state) {
        case ContextSyncState.loadingLocal:
          icon = Icons.sync;
          color = Colors.blue;
          label = 'Loading…';
          break;
        case ContextSyncState.fetchingFromDevice:
          icon = Icons.sync;
          color = Colors.blue;
          label = 'Getting the latest from Smarty…';
          break;
        case ContextSyncState.saving:
          icon = Icons.sync;
          color = Colors.blue;
          label = 'Sending to Smarty…';
          break;
        case ContextSyncState.error:
          icon = Icons.error_outline;
          color = Colors.red;
          label =
              provider.errorMessage ?? 'Something went wrong. Please try again.';
          break;
        case ContextSyncState.idle:
          if (_dirty) {
            icon = Icons.edit;
            color = Colors.amber.shade700;
            label = 'Unsaved changes';
          } else if (provider.lastSyncedAt != null) {
            icon = Icons.check_circle;
            color = Colors.green;
            label = 'Smarty has the latest version.';
          } else {
            icon = Icons.info_outline;
            color = Colors.grey;
            label = 'Ready';
          }
          break;
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: themeProvider.isDarkMode
            ? const Color(0xFF2C2C44)
            : color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: themeProvider.isDarkMode ? Colors.white70 : color,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

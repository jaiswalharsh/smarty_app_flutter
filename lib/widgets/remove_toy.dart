import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../services/known_toys_service.dart';

/// The link that starts it (Home's "Reconnect your Smarty", the setup page
/// while reconnecting).
const String noLongerHaveToyLabel = "I don't have this Smarty any more";

/// Home's ⋯ menu: the two ways to let go of a toy, and what each one means.
const String forgetToyLabel = 'Forget this Smarty';
const String forgetToySubtitle =
    'This phone forgets it; your account still has it.';
const String removeToyLabel = 'Remove from my account';
const String removeToySubtitle =
    'Unlinks it from your account; frees it for another family.';

/// The sheet's text.
const String removeToyBody =
    'This Smarty will stop being linked to you. Someone else can then set it '
    'up on their account.';
const String keepConversationsLabel =
    'Keep its conversations in my Conversations tab (for 90 days)';

/// Before the toy changes hands: its own settings (Wi-Fi, the link key) are
/// erased on the toy itself, never from the app or the cloud.
const String eraseToyNote =
    'Before handing Smarty to someone else, hold + and – on it for 10 '
    'seconds to erase your settings.';

/// iPhone only, after [eraseToyNote].
const String eraseToyNoteIOS = 'Then forget Smarty in Settings → Bluetooth.';

/// The sheet's title for the toy called [bleName] ("Smarty-B11E"), or "this
/// Smarty" when its name isn't known. Pure.
String removeToyTitle(String? bleName) =>
    'Remove ${normalizeBleName(bleName) ?? 'this Smarty'} from your account?';

/// The note once it's done. Pure.
String toyRemovedMessage(String? bleName) =>
    '${normalizeBleName(bleName) ?? 'Smarty'} was removed from your account.';

/// Asks "Remove Smarty-B11E from your account?" in a bottom sheet, with
/// "Keep its conversations in my Conversations tab (for 90 days)" — off
/// unless the parent turns it on (it's a child's chats: nothing is kept by
/// default) — and a note on erasing the toy before handing it on (+ forget
/// it in Settings → Bluetooth on iPhone: [isIOS], default this phone).
/// Remove runs [remove] with that choice while its button spins; a
/// [RemoveToyException] (or any error) is shown in the sheet, which stays
/// open so the parent can try again. On success the sheet closes, the note
/// "Smarty-B11E was removed from your account." shows, and this returns
/// true; Cancel returns false.
Future<bool> confirmAndRemoveToy(
  BuildContext context, {
  required String? bleName,
  required Future<void> Function(bool keepHistory) remove,
  bool? isIOS,
}) async {
  final bool ios = isIOS ?? Platform.isIOS;
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  final bool? removed = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    // Only Cancel / Remove close it, so a removal in flight can't be
    // dismissed half-way (see PopScope in the sheet).
    enableDrag: false,
    builder:
        (_) => RemoveToySheet(bleName: bleName, remove: remove, isIOS: ios),
  );
  if (removed != true) return false;
  messenger?.showSnackBar(SnackBar(content: Text(toyRemovedMessage(bleName))));
  return true;
}

/// The sheet [confirmAndRemoveToy] shows. Pops `true` once [remove] has
/// succeeded, `false` on Cancel.
class RemoveToySheet extends StatefulWidget {
  const RemoveToySheet({
    super.key,
    required this.bleName,
    required this.remove,
    this.isIOS = false,
  });

  final String? bleName;
  final Future<void> Function(bool keepHistory) remove;

  /// Adds [eraseToyNoteIOS].
  final bool isIOS;

  @override
  State<RemoveToySheet> createState() => _RemoveToySheetState();
}

class _RemoveToySheetState extends State<RemoveToySheet> {
  bool _keepHistory = false;
  bool _busy = false;
  String? _error;

  Future<void> _onRemove() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.remove(_keepHistory);
      if (mounted) Navigator.of(context).pop(true);
    } on RemoveToyException catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e.message;
        });
      }
    } catch (e) {
      debugPrint('RemoveToySheet: removal failed: $e');
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Something went wrong. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color secondary = scheme.onSurface.withValues(alpha: 0.7);
    final Color danger = Colors.red.shade600;
    return PopScope(
      canPop: !_busy,
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                removeToyTitle(widget.bleName),
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                removeToyBody,
                style: TextStyle(fontSize: 16, height: 1.35, color: secondary),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _keepHistory,
                onChanged:
                    _busy ? null : (v) => setState(() => _keepHistory = v),
                title: const Text(keepConversationsLabel),
              ),
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.info_outline, size: 18, color: secondary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.isIOS
                          ? '$eraseToyNote $eraseToyNoteIOS'
                          : eraseToyNote,
                      style: TextStyle(fontSize: 14, color: secondary),
                    ),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(fontSize: 15, color: danger)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: danger,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: danger.withValues(alpha: 0.6),
                  minimumSize: const Size.fromHeight(48),
                ),
                onPressed: _busy ? null : _onRemove,
                child:
                    _busy
                        ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                        : const Text(
                          'Remove',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
              ),
              const SizedBox(height: 8),
              TextButton(
                style: TextButton.styleFrom(
                  minimumSize: const Size.fromHeight(44),
                ),
                onPressed:
                    _busy ? null : () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

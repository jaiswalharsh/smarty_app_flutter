import 'package:flutter/material.dart';

import '../../app_info.dart';
import '../../main.dart' show SplashScreen;
import '../../services/account_service.dart';
import 'account_helpers.dart';

/// Parent's initials in a circle (person icon when there are none). Used by
/// the Settings "Your account" card and at the top of [YourAccountPage].
class AccountInitials extends StatelessWidget {
  const AccountInitials({
    super.key,
    required this.initials,
    required this.color,
    this.size = 30,
  });

  final String initials;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Center(
        child: initials.isEmpty
            ? Icon(Icons.person_outline, color: color, size: size)
            : Text(
                initials,
                maxLines: 1,
                style: TextStyle(
                  fontSize: size * 0.5,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
      ),
    );
  }
}

/// Default "leave the signed-in app" route: back to the splash screen, which
/// sends a signed-out parent to the login page (same as sign-out always did).
void returnToStart(BuildContext context) {
  Navigator.of(context).pushAndRemoveUntil(
    MaterialPageRoute(builder: (_) => SplashScreen()),
    (route) => false,
  );
}

/// "Your account": name, email, change password, sign out, delete account.
class YourAccountPage extends StatefulWidget {
  YourAccountPage({super.key, AccountService? account, this.onSignedOut})
      : account = account ?? FirebaseAccountService();

  final AccountService account;

  /// Called after signing out or deleting the account. Defaults to
  /// [returnToStart].
  final void Function(BuildContext context)? onSignedOut;

  @override
  State<YourAccountPage> createState() => _YourAccountPageState();
}

class _YourAccountPageState extends State<YourAccountPage> {
  bool _sendingReset = false;

  AccountService get _account => widget.account;

  bool get _dark => Theme.of(context).brightness == Brightness.dark;
  Color get _accent => _dark ? const Color(0xFF00FFCC) : Colors.indigo;
  Color get _cardColor =>
      _dark ? const Color(0xFF2C2C44) : Colors.indigo.shade50;
  Color get _textColor => _dark ? Colors.white : Colors.black87;
  Color get _mutedColor => _dark ? Colors.white70 : Colors.black54;

  String? get _name {
    final n = _account.displayName?.trim();
    return (n == null || n.isEmpty) ? null : n;
  }

  void _leave() {
    if (!mounted) return;
    (widget.onSignedOut ?? returnToStart)(context);
  }

  void _showMessage(String text) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  // --- Name -----------------------------------------------------------------

  Future<void> _editName() async {
    final bool? saved = await showDialog<bool>(
      context: context,
      builder: (_) => _NameDialog(
        initialName: _name ?? '',
        onSave: (name) async {
          try {
            await _account.updateDisplayName(name);
            return null;
          } on AccountException catch (e) {
            return e.problem == AccountProblem.other
                ? "Couldn't save your name. Please try again."
                : accountProblemMessage(e.problem);
          } catch (_) {
            return "Couldn't save your name. Please try again.";
          }
        },
      ),
    );
    if (saved == true && mounted) {
      setState(() {});
      _showMessage('Name saved');
    }
  }

  // --- Password -------------------------------------------------------------

  Future<void> _sendPasswordReset() async {
    if (_sendingReset) return;
    setState(() => _sendingReset = true);
    String message;
    try {
      await _account.sendPasswordReset();
      message = 'Check your email — we sent you a link to set a new password.';
    } on AccountException catch (e) {
      message = accountProblemMessage(e.problem);
    } catch (_) {
      message = accountProblemMessage(AccountProblem.other);
    }
    if (!mounted) return;
    setState(() => _sendingReset = false);
    _showMessage(message);
  }

  // --- Sign out -------------------------------------------------------------

  Future<void> _confirmSignOut() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'You can sign back in any time with your email and password.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Sign out'),
          ),
        ],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
    );
    if (confirmed != true) return;
    try {
      await _account.signOut();
    } catch (_) {
      if (mounted) {
        _showMessage(accountProblemMessage(AccountProblem.other));
      }
      return;
    }
    _leave();
  }

  // --- Delete account -------------------------------------------------------

  Future<void> _confirmDelete() async {
    final bool? deleted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _DeleteAccountDialog(
        onDelete: (password) async {
          try {
            await _account.deleteAccount(password);
            return null;
          } on AccountException catch (e) {
            return accountProblemMessage(e.problem);
          } catch (_) {
            return accountProblemMessage(AccountProblem.other);
          }
        },
      ),
    );
    if (deleted == true) _leave();
  }

  // --- Layout ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final String? name = _name;
    final String email = _account.email ?? '';

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Your account',
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
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _buildHeader(name, email),
            const SizedBox(height: 24),
            _buildCard([
              _AccountRow(
                icon: Icons.badge_outlined,
                label: 'Name',
                detail: name ?? 'Add your name',
                onTap: _editName,
                trailingIcon: Icons.edit_outlined,
              ),
              _AccountRow(
                icon: Icons.email_outlined,
                label: 'Email',
                detail: email.isEmpty ? '—' : email,
              ),
              _AccountRow(
                icon: Icons.lock_reset,
                label: 'Change password',
                detail: "We'll email you a link to set a new password.",
                onTap: _sendingReset ? null : _sendPasswordReset,
                busy: _sendingReset,
              ),
              _AccountRow(
                icon: Icons.logout,
                label: 'Sign out',
                onTap: _confirmSignOut,
              ),
            ]),
            const SizedBox(height: 32),
            _buildCard([
              _AccountRow(
                icon: Icons.delete_outline,
                label: 'Delete account',
                detail: 'Remove your Smarty account for good',
                onTap: _confirmDelete,
                destructive: true,
              ),
            ]),
            const SizedBox(height: 32),
            Center(
              child: Text(
                'Version $appVersion',
                style: TextStyle(fontSize: 12, color: _mutedColor),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(String? name, String email) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: _dark ? const Color(0xFF3A3A5A) : Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: _accent.withValues(alpha: 0.2),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: AccountInitials(
            initials: initialsFor(displayName: name, email: email),
            color: _accent,
            size: 48,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          name ?? 'Your account',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.bold,
            color: _textColor,
          ),
        ),
        if (email.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            email,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: _mutedColor),
          ),
        ],
      ],
    );
  }

  Widget _buildCard(List<Widget> rows) {
    return Card(
      elevation: 4,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        color: _cardColor,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      ),
    );
  }
}

/// One tappable line in an account card (styled like the "My Smarty" rows).
class _AccountRow extends StatelessWidget {
  const _AccountRow({
    required this.icon,
    required this.label,
    this.detail,
    this.onTap,
    this.destructive = false,
    this.busy = false,
    this.trailingIcon,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final VoidCallback? onTap;
  final bool destructive;
  final bool busy;
  final IconData? trailingIcon;

  @override
  Widget build(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final Color fg = destructive
        ? Colors.red.shade400
        : (dark ? Colors.white : Colors.black87);
    final Color muted = dark ? Colors.white70 : Colors.black54;

    Widget? trailing;
    if (busy) {
      trailing = const SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (onTap != null && !destructive) {
      trailing = Icon(
        trailingIcon ?? Icons.arrow_forward_ios,
        color: dark ? Colors.white54 : Colors.black45,
        size: trailingIcon == null ? 16 : 20,
      );
    }

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const SizedBox(width: 8),
            Icon(icon, color: fg, size: 22),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: fg,
                    ),
                  ),
                  if (detail != null) ...[
                    const SizedBox(height: 2),
                    Text(detail!, style: TextStyle(fontSize: 13, color: muted)),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing],
          ],
        ),
      ),
    );
  }
}

/// Edit-name dialog. [onSave] gets the cleaned-up name and returns an error
/// message, or null on success (the dialog then pops `true`).
class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.initialName, required this.onSave});

  final String initialName;
  final Future<String?> Function(String name) onSave;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialName);
  String? _error;
  bool _saving = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final String? problem = validateDisplayName(_controller.text);
    if (problem != null) {
      setState(() => _error = problem);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final String? error =
        await widget.onSave(normalizeDisplayName(_controller.text));
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Your name'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        enabled: !_saving,
        maxLength: maxDisplayNameLength,
        textCapitalization: TextCapitalization.words,
        textInputAction: TextInputAction.done,
        onSubmitted: (_) => _save(),
        onChanged: (_) {
          if (_error != null) setState(() => _error = null);
        },
        decoration: InputDecoration(
          hintText: 'e.g. Anna',
          errorText: _error,
          errorMaxLines: 3,
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Save'),
        ),
      ],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    );
  }
}

/// Delete-account confirmation. The parent must type their password.
/// [onDelete] returns an error message, or null once the account is deleted
/// (the dialog then pops `true`).
class _DeleteAccountDialog extends StatefulWidget {
  const _DeleteAccountDialog({required this.onDelete});

  final Future<String?> Function(String password) onDelete;

  @override
  State<_DeleteAccountDialog> createState() => _DeleteAccountDialogState();
}

class _DeleteAccountDialogState extends State<_DeleteAccountDialog> {
  final TextEditingController _password = TextEditingController();
  String? _error;
  bool _deleting = false;

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _delete() async {
    if (_deleting) return;
    if (_password.text.isEmpty) {
      setState(() => _error = 'Please type your password.');
      return;
    }
    setState(() {
      _deleting = true;
      _error = null;
    });
    final String? error = await widget.onDelete(_password.text);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _deleting = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
      title: const Text('Delete your account?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "This deletes your Smarty account, your saved chats and your "
            "toy's registration, and signs you out. "
            'This phone will also forget your Smarty toy.',
          ),
          const SizedBox(height: 12),
          const Text(
            "This can't be undone.",
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          const Text('To confirm, type your password.'),
          const SizedBox(height: 8),
          TextField(
            controller: _password,
            obscureText: true,
            enabled: !_deleting,
            autocorrect: false,
            enableSuggestions: false,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _delete(),
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
            decoration: InputDecoration(
              labelText: 'Password',
              errorText: _error,
              errorMaxLines: 3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Forgot it? Use "Change password" to get a link by email.',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.white70
                  : Colors.black54,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _deleting ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _deleting ? null : _delete,
          style: TextButton.styleFrom(foregroundColor: Colors.red),
          child: _deleting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Delete account'),
        ),
      ],
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    );
  }
}

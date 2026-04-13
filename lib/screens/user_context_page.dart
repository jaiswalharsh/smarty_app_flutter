import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/user_context_provider.dart';
import '../services/ble_manager.dart';
import '../utils/theme_provider.dart';

class UserContextPage extends StatefulWidget {
  const UserContextPage({super.key});

  @override
  State<UserContextPage> createState() => _UserContextPageState();
}

class _UserContextPageState extends State<UserContextPage> {
  final TextEditingController _controller = TextEditingController();
  final BleManager _bleManager = BleManager();
  StreamSubscription? _connectionSub;
  bool _dirty = false;
  bool _bootstrapped = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);

    // Kick off initial fetch from device after first frame so the provider
    // is available via context.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      final provider = context.read<UserContextProvider>();
      _controller.text = provider.context;
      _dirty = false;
      if (_bleManager.isConnected) {
        await provider.refreshFromDevice();
        if (!mounted) return;
        if (!_dirty) {
          _controller.text = provider.context;
        }
      }
      setState(() => _bootstrapped = true);
    });

    // React to BLE connection state changes so we can surface a warning if the
    // device drops mid-edit.
    _connectionSub = _bleManager.wifiStatusStream.listen((_) {
      if (mounted) setState(() {});
    });
  }

  void _onTextChanged() {
    final provider = context.read<UserContextProvider>();
    final nowDirty = _controller.text != provider.context;
    if (nowDirty != _dirty) {
      setState(() => _dirty = nowDirty);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _connectionSub?.cancel();
    super.dispose();
  }

  Future<void> _handleReload() async {
    if (!_bleManager.isConnected) {
      _showSnack('Smarty is not connected.', isError: true);
      return;
    }
    final provider = context.read<UserContextProvider>();
    await provider.refreshFromDevice();
    if (!mounted) return;
    _controller.text = provider.context;
    _dirty = false;
    if (provider.state == ContextSyncState.error) {
      _showSnack(provider.errorMessage ?? 'Failed to reload.', isError: true);
    } else {
      _showSnack('Reloaded from Smarty.');
    }
  }

  Future<void> _handleSave() async {
    final provider = context.read<UserContextProvider>();
    final newText = _controller.text;
    final ok = await provider.save(newText);
    if (!mounted) return;
    if (ok) {
      _dirty = false;
      _showSnack('Saved to Smarty.');
    } else {
      _showSnack(provider.errorMessage ?? 'Failed to save.', isError: true);
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
          'User Context',
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
                "This text is sent directly to Smarty and used to personalize "
                "its responses. You can edit it anytime.",
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
                  maxLength: 500,
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
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: (provider.isBusy || !connected)
                          ? null
                          : _handleReload,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reload from Smarty'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: (provider.isBusy || !_dirty)
                          ? null
                          : _handleSave,
                      icon: provider.state == ContextSyncState.saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                          : const Icon(Icons.cloud_upload),
                      label: const Text('Save to Smarty'),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
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
      color = Colors.orange;
      label = 'Smarty not connected — showing last saved copy';
    } else {
      switch (provider.state) {
        case ContextSyncState.loadingLocal:
          icon = Icons.sync;
          color = Colors.blue;
          label = 'Loading…';
          break;
        case ContextSyncState.fetchingFromDevice:
          icon = Icons.cloud_download;
          color = Colors.blue;
          label = 'Fetching from Smarty…';
          break;
        case ContextSyncState.saving:
          icon = Icons.cloud_upload;
          color = Colors.blue;
          label = 'Saving to Smarty…';
          break;
        case ContextSyncState.error:
          icon = Icons.error_outline;
          color = Colors.red;
          label = provider.errorMessage ?? 'Error';
          break;
        case ContextSyncState.idle:
          if (_dirty) {
            icon = Icons.edit;
            color = Colors.amber.shade700;
            label = 'Unsaved changes';
          } else if (provider.lastSyncedAt != null) {
            icon = Icons.check_circle;
            color = Colors.green;
            label = 'Synced with Smarty';
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
            : color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.5)),
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

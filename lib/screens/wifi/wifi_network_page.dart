import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/ble_manager.dart';
import '../../utils/wifi_utils.dart';

// Banner intent, so colour/emphasis is driven by state instead of sniffing the
// message text for words like "Failed" (which broke as soon as copy changed).
enum _BannerSeverity { info, progress, success, error }

class WifiNetworkPage extends StatefulWidget {
  const WifiNetworkPage({super.key});

  @override
  State<WifiNetworkPage> createState() => _WifiNetworkPageState();
}

class _WifiNetworkPageState extends State<WifiNetworkPage> {
  final BleManager _bleManager = BleManager();
  List<WifiNetwork> _wifiNetworks = [];
  bool _isScanningWifi = true;
  // In-flight lock: while provisioning, the list, refresh and hidden-network
  // actions are disabled so a parent can't launch a second concurrent attempt.
  bool _isProvisioning = false;
  String? _provisioningSsid;
  // Set ONLY on timeout, so a late terminal status for that SSID can still
  // correct the banner after we've stopped awaiting.
  String? _lastAttemptSsid;
  String _bannerMessage = 'Scanning for WiFi networks...';
  _BannerSeverity _severity = _BannerSeverity.progress;
  StreamSubscription<String>? _statusSub;

  @override
  void initState() {
    super.initState();
    // Late-result recovery: after a timeout we stop awaiting, but the toy may
    // still emit the real verdict for the last attempt — surface it here so the
    // banner corrects itself instead of leaving a stale "taking longer" message.
    _statusSub = _bleManager.wifiStatusStream.listen(_handleLateStatus);
    _scanWifiNetworks();
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    super.dispose();
  }

  void _handleLateStatus(String status) {
    if (!mounted) return;
    if (_isProvisioning) return; // an active await already owns the result
    final String? attempt = _lastAttemptSsid;
    if (attempt == null) return;

    final String s = status.trim();
    if (s == 'Auth Failed') {
      _lastAttemptSsid = null;
      setState(() {
        _bannerMessage =
            'Incorrect Wi-Fi password for $attempt. Please try again.';
        _severity = _BannerSeverity.error;
      });
    } else if (s == 'Connection Failed') {
      _lastAttemptSsid = null;
      setState(() {
        _bannerMessage =
            "Couldn't connect to $attempt. Check that the network is working and try again.";
        _severity = _BannerSeverity.error;
      });
    } else if (s == attempt ||
        (attempt.length > 31 && s == attempt.substring(0, 31))) {
      // Deployed firmware truncates the reported SSID to 31 chars.
      _lastAttemptSsid = null;
      setState(() {
        _bannerMessage = 'Connected to $attempt!';
        _severity = _BannerSeverity.success;
      });
      Future.delayed(const Duration(milliseconds: 1200), () {
        if (mounted) Navigator.pop(context, true);
      });
    }
  }

  Future<void> _scanWifiNetworks() async {
    setState(() {
      _isScanningWifi = true;
      _wifiNetworks = [];
      _bannerMessage = 'Scanning for WiFi networks...';
      _severity = _BannerSeverity.progress;
    });

    try {
      // Already deduped and sorted strongest-first by the parser.
      final networks = await _bleManager.scanWifiNetworks();
      if (!mounted) return;
      setState(() {
        _wifiNetworks = networks;
        _isScanningWifi = false;
        _bannerMessage = _wifiNetworks.isEmpty
            ? 'No Wi-Fi networks found.'
            : 'Found ${_wifiNetworks.length} Wi-Fi networks';
        _severity = _BannerSeverity.info;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isScanningWifi = false;
        _bannerMessage = 'WiFi scan failed: $e';
        _severity = _BannerSeverity.error;
      });
    }
  }

  Future<void> _onNetworkSelected(WifiNetwork network) async {
    final String ssid = network.ssid;

    // Honest, immediate failure: firmware splits "<ssid>,<password>" on the
    // FIRST comma, so a comma in the SSID would corrupt the credentials on the
    // wire. A clear message now beats a mysterious wrong-password error later.
    if (ssid.contains(',')) {
      setState(() {
        _bannerMessage =
            "This network's name contains a comma, which Smarty can't join yet. Please use a different network or rename it.";
        _severity = _BannerSeverity.error;
      });
      return;
    }

    if (network.isOpen) {
      // Open network — no dialog, provision with an empty password.
      await _provision(ssid, '');
      return;
    }

    final String? password = await WifiUtils.showPasswordDialog(context, ssid);
    if (!mounted) return;
    if (password == null) return; // cancelled
    await _provision(ssid, password);
  }

  Future<void> _provision(String ssid, String password) async {
    setState(() {
      _isProvisioning = true;
      _provisioningSsid = ssid;
      // A fresh attempt supersedes any prior timed-out one still being watched.
      _lastAttemptSsid = null;
      _bannerMessage = 'Connecting Smarty to $ssid…';
      _severity = _BannerSeverity.progress;
    });

    // Wait for the toy's REAL join result, not the bare BLE write ack.
    final WifiProvisionResult result =
        await _bleManager.connectToWifiAndAwait(ssid, password);
    if (!mounted) return;

    switch (result) {
      case WifiProvisionResult.connected:
        setState(() {
          _isProvisioning = false;
          _provisioningSsid = null;
          _bannerMessage = 'Connected to $ssid!';
          _severity = _BannerSeverity.success;
        });
        // The `true` result is a contract: a follow-up screen celebrates it.
        // Short delay so the parent sees the success banner before we pop.
        Future.delayed(const Duration(milliseconds: 1200), () {
          if (mounted) Navigator.pop(context, true);
        });
        break;
      case WifiProvisionResult.wrongPassword:
        setState(() {
          _isProvisioning = false;
          _provisioningSsid = null;
          _bannerMessage =
              'Incorrect Wi-Fi password for $ssid. Please try again.';
          _severity = _BannerSeverity.error;
        });
        break;
      case WifiProvisionResult.failed:
        setState(() {
          _isProvisioning = false;
          _provisioningSsid = null;
          _bannerMessage =
              "Couldn't connect to $ssid. Check that the network is working and try again.";
          _severity = _BannerSeverity.error;
        });
        break;
      case WifiProvisionResult.bleDisconnected:
        setState(() {
          _isProvisioning = false;
          _provisioningSsid = null;
          _bannerMessage =
              "Lost connection to Smarty. Make sure it's turned on and nearby, then reconnect and try again.";
          _severity = _BannerSeverity.error;
        });
        break;
      case WifiProvisionResult.timeout:
        setState(() {
          _isProvisioning = false;
          _provisioningSsid = null;
          // Remember the attempt so a late terminal status can still correct
          // this over-optimistic banner (see _handleLateStatus).
          _lastAttemptSsid = ssid;
          _bannerMessage =
              'This is taking longer than expected — Smarty may still be joining $ssid. If nothing changes in a minute, try again.';
          _severity = _BannerSeverity.info;
        });
        break;
      case WifiProvisionResult.writeError:
        setState(() {
          _isProvisioning = false;
          _provisioningSsid = null;
          _bannerMessage =
              "Couldn't send Wi-Fi details to Smarty. Reconnect and try again.";
          _severity = _BannerSeverity.error;
        });
        break;
    }
  }

  // Manual entry for hidden APs (not in the scan) and for open hidden networks
  // (empty password allowed). Same comma limitation as a listed network.
  Future<void> _showHiddenNetworkDialog() async {
    final TextEditingController ssidController = TextEditingController();
    final TextEditingController passwordController = TextEditingController();
    bool obscure = true;
    String? ssidError;

    final bool? submitted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            void submit() {
              final String ssid = ssidController.text.trim();
              if (ssid.isEmpty) {
                setLocalState(
                    () => ssidError = 'Please enter the network name');
                return;
              }
              if (ssid.contains(',')) {
                setLocalState(
                    () => ssidError = "Names with a comma aren't supported yet");
                return;
              }
              Navigator.of(dialogContext).pop(true);
            }

            return AlertDialog(
              title: const Text('Join a hidden network'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: ssidController,
                      decoration: InputDecoration(
                        labelText: 'Network name (SSID)',
                        border: const OutlineInputBorder(),
                        errorText: ssidError,
                      ),
                      autofocus: true,
                      onChanged: (_) {
                        if (ssidError != null) {
                          setLocalState(() => ssidError = null);
                        }
                      },
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: passwordController,
                      decoration: InputDecoration(
                        labelText: 'Password (leave empty if none)',
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          icon: Icon(obscure
                              ? Icons.visibility_off
                              : Icons.visibility),
                          tooltip:
                              obscure ? 'Show password' : 'Hide password',
                          onPressed: () =>
                              setLocalState(() => obscure = !obscure),
                        ),
                      ),
                      obscureText: obscure,
                      onSubmitted: (_) => submit(),
                    ),
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  child: const Text('Cancel'),
                  onPressed: () => Navigator.of(dialogContext).pop(false),
                ),
                TextButton(
                  onPressed: submit,
                  child: const Text('Join'),
                ),
              ],
            );
          },
        );
      },
    );

    final String ssid = ssidController.text.trim();
    final String password = passwordController.text;
    ssidController.dispose();
    passwordController.dispose();

    if (submitted != true) return;
    if (!mounted) return;
    await _provision(ssid, password);
  }

  Color _severityColor(_BannerSeverity severity) {
    switch (severity) {
      case _BannerSeverity.error:
        return Colors.red;
      case _BannerSeverity.progress:
        return Colors.blue;
      case _BannerSeverity.success:
        return Colors.green;
      case _BannerSeverity.info:
        return Colors.blueGrey;
    }
  }

  IconData _signalIcon(WifiNetwork network) {
    // Old-format fallback lines carry rssi 0 (unknown); 0 >= -60 lands in the
    // strongest bucket and shows the plain wifi glyph — the intended "unknown".
    final int rssi = network.rssi;
    if (rssi >= -60) return Icons.wifi;
    if (rssi >= -75) return Icons.wifi_2_bar;
    return Icons.wifi_1_bar;
  }

  Widget _buildBanner() {
    final Color color = _severityColor(_severity);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color),
      ),
      child: Text(
        _bannerMessage,
        style: TextStyle(color: color, fontWeight: FontWeight.bold),
        textAlign: TextAlign.center,
      ),
    );
  }

  Widget _buildTile(WifiNetwork network) {
    final bool disabled = _isProvisioning || _isScanningWifi;
    final bool isThisProvisioning = _provisioningSsid == network.ssid;

    Widget? trailing;
    if (isThisProvisioning) {
      trailing = const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    } else if (!network.isOpen) {
      trailing = const Icon(Icons.lock_outline);
    }

    return ListTile(
      enabled: !disabled,
      leading: Icon(_signalIcon(network)),
      title: Text(network.ssid),
      subtitle: network.isOpen ? const Text('Open network') : null,
      trailing: trailing,
      onTap: disabled ? null : () => _onNetworkSelected(network),
    );
  }

  Widget _buildHiddenNetworkButton() {
    final bool disabled = _isProvisioning || _isScanningWifi;
    return TextButton.icon(
      onPressed: disabled ? null : _showHiddenNetworkDialog,
      icon: const Icon(Icons.wifi_find),
      label: const Text('Join a hidden network'),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'No Wi-Fi networks found.',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Smarty can only see 2.4 GHz networks. If yours is missing, make sure it broadcasts on 2.4 GHz (many routers have separate 2.4 GHz and 5 GHz names).',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _isProvisioning ? null : _scanWifiNetworks,
              icon: const Icon(Icons.refresh),
              label: const Text('Rescan'),
            ),
            const SizedBox(height: 8),
            _buildHiddenNetworkButton(),
          ],
        ),
      ),
    );
  }

  Widget _buildNetworkList() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Available WiFi Networks:',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        SizedBox(height: 4),
        Text(
          'Smarty uses 2.4 GHz networks only.',
          style: TextStyle(fontSize: 13, color: Colors.grey),
        ),
        SizedBox(height: 8),
        Expanded(
          child: ListView.builder(
            itemCount: _wifiNetworks.length,
            itemBuilder: (context, index) => _buildTile(_wifiNetworks[index]),
          ),
        ),
        _buildHiddenNetworkButton(),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool busy = _isScanningWifi || _isProvisioning;
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('WiFi Networks'),
          actions: [
            IconButton(
              icon: const Icon(Icons.wifi_find),
              onPressed: busy ? null : _showHiddenNetworkDialog,
              tooltip: 'Join hidden network',
            ),
            IconButton(
              icon: Icon(Icons.refresh),
              onPressed: busy ? null : _scanWifiNetworks,
              tooltip: 'Refresh WiFi Networks',
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildBanner(),
              if (_isScanningWifi)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Scanning for WiFi networks...'),
                      ],
                    ),
                  ),
                )
              else if (_wifiNetworks.isEmpty)
                Expanded(child: _buildEmptyState())
              else
                Expanded(child: _buildNetworkList()),
            ],
          ),
        ),
      ),
    );
  }
}

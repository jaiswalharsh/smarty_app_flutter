import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/ble_manager.dart';
import '../../utils/wifi_utils.dart';

// Banner intent, so colour/emphasis is driven by state instead of sniffing the
// message text for words like "Failed" (which broke as soon as copy changed).
enum _BannerSeverity { info, progress, success, error }

/// Shown on the Wi-Fi pages while the Bluetooth link to Smarty is down.
/// BleManager reconnects by itself, so the page stays put and its actions
/// come back once [ToyPhase.connected] returns.
class LostTouchBanner extends StatelessWidget {
  const LostTouchBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.orange),
      ),
      child: Row(
        children: [
          Icon(Icons.bluetooth_searching, color: Colors.orange.shade800),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              "Lost touch with Smarty — keep it close to your phone. "
              "We'll reconnect automatically.",
              style: TextStyle(
                color: Colors.orange.shade900,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
  String _bannerMessage = 'Smarty is looking for Wi-Fi networks…';
  _BannerSeverity _severity = _BannerSeverity.progress;
  StreamSubscription<String>? _statusSub;
  // Link to Smarty is up. While it's down the page stays, with a banner and
  // its actions disabled, instead of closing itself.
  bool _linkUp = BleManager().phase.value == ToyPhase.connected;
  // The link dropped while a Wi-Fi scan was running: that scan's list is
  // empty or partial, so look again once the link is back.
  bool _droppedDuringScan = false;

  @override
  void initState() {
    super.initState();
    _bleManager.phase.addListener(_onPhaseChanged);
    // Late-result recovery: after a timeout we stop awaiting, but the toy may
    // still emit the real verdict for the last attempt — surface it here so the
    // banner corrects itself instead of leaving a stale "taking longer" message.
    _statusSub = _bleManager.wifiStatusStream.listen(_handleLateStatus);
    _scanWifiNetworks();
  }

  @override
  void dispose() {
    _bleManager.phase.removeListener(_onPhaseChanged);
    _statusSub?.cancel();
    super.dispose();
  }

  void _onPhaseChanged() {
    if (!mounted) return;
    final bool up = _bleManager.phase.value == ToyPhase.connected;
    if (up == _linkUp) return;
    setState(() => _linkUp = up);
    if (!up && _isScanningWifi) _droppedDuringScan = true;
    // Back from a drop with nothing (or only a partial list) to show: look
    // again by ourselves. A scan still running from before the drop rescans
    // when it ends (see _rescanIfDropped).
    if (up &&
        !_isScanningWifi &&
        !_isProvisioning &&
        (_wifiNetworks.isEmpty || _droppedDuringScan)) {
      _scanWifiNetworks();
    }
  }

  // Called when a scan ends: if the link dropped during it and is back now,
  // scan once more (the quick drop may be over before the scan even ends).
  void _rescanIfDropped() {
    if (!mounted || !_droppedDuringScan) return;
    if (!_linkUp || _isProvisioning) return; // _onPhaseChanged picks it up
    _scanWifiNetworks();
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
        _popThisPage(true);
      });
    }
  }

  // Delayed success pop: close THIS page even if a dialog was opened on top in
  // the meantime (a bare Navigator.pop would close that dialog instead).
  void _popThisPage(bool result) {
    if (!mounted) return;
    final route = ModalRoute.of(context);
    if (route == null || !route.isActive) return;
    final navigator = Navigator.of(context);
    if (!route.isCurrent) {
      navigator.popUntil((r) => r == route);
    }
    navigator.pop(result);
  }

  Future<void> _scanWifiNetworks() async {
    // A scan started while the link is down can't succeed — let the
    // reconnect trigger another one.
    _droppedDuringScan = !_linkUp;
    setState(() {
      _isScanningWifi = true;
      _wifiNetworks = [];
      _bannerMessage = 'Smarty is looking for Wi-Fi networks…';
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
            : 'Choose your home Wi-Fi';
        _severity = _BannerSeverity.info;
      });
      _rescanIfDropped();
    } catch (e) {
      debugPrint("WifiNetworkPage: Wi-Fi scan failed: $e");
      if (!mounted) return;
      setState(() {
        _isScanningWifi = false;
        _bannerMessage =
            "Couldn't scan for Wi-Fi networks. Make sure Smarty is nearby and try again.";
        _severity = _BannerSeverity.error;
      });
      _rescanIfDropped();
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
          _popThisPage(true);
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
          // The lost-touch banner explains the drop; once Smarty is back the
          // parent just picks the network again.
          _bannerMessage =
              "Smarty didn't finish joining $ssid. Pick it again once Smarty is back.";
          _severity = _BannerSeverity.info;
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
              "Couldn't send the Wi-Fi details to Smarty. Please try again.";
          _severity = _BannerSeverity.error;
        });
        break;
    }
  }

  // Manual entry for hidden APs (not in the scan) and for open hidden networks
  // (empty password allowed). Same comma limitation as a listed network.
  Future<void> _showHiddenNetworkDialog() async {
    final (String, String)? result = await showDialog<(String, String)>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _HiddenNetworkDialog(),
    );
    if (result == null) return; // cancelled
    if (!mounted) return;
    final (String ssid, String password) = result;
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
    final bool disabled = _isProvisioning || _isScanningWifi || !_linkUp;
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
    final bool disabled = _isProvisioning || _isScanningWifi || !_linkUp;
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
              onPressed:
                  _isProvisioning || !_linkUp ? null : _scanWifiNetworks,
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
          'Available Wi-Fi networks',
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
    final bool busy = _isScanningWifi || _isProvisioning || !_linkUp;
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Wi-Fi Networks'),
          actions: [
            IconButton(
              icon: const Icon(Icons.wifi_find),
              onPressed: busy ? null : _showHiddenNetworkDialog,
              tooltip: 'Join hidden network',
            ),
            IconButton(
              icon: Icon(Icons.refresh),
              onPressed: busy ? null : _scanWifiNetworks,
              tooltip: 'Refresh Wi-Fi networks',
            ),
          ],
        ),
        body: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!_linkUp) const LostTouchBanner(),
              _buildBanner(),
              if (_isScanningWifi)
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        CircularProgressIndicator(),
                        SizedBox(height: 16),
                        Text('Smarty is looking for Wi-Fi networks…'),
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

// Extracted into its own widget so its State owns the TextEditingControllers and
// disposes them in dispose(), which Flutter runs only after the dialog route has
// fully left the tree. Disposing them right after `await showDialog` returned
// instead crashed with "used after being disposed": the route keeps rebuilding
// during its exit transition as the keyboard dismisses (animating
// MediaQuery.viewInsets), re-subscribing the TextField to a freed controller.
// Owning them here keeps the APP-9 leak fixed without that race. On success we
// pop the entered values so the caller never touches the controllers.
class _HiddenNetworkDialog extends StatefulWidget {
  const _HiddenNetworkDialog();

  @override
  State<_HiddenNetworkDialog> createState() => _HiddenNetworkDialogState();
}

class _HiddenNetworkDialogState extends State<_HiddenNetworkDialog> {
  final TextEditingController ssidController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();
  bool obscure = true;
  String? ssidError;

  @override
  void dispose() {
    ssidController.dispose();
    passwordController.dispose();
    super.dispose();
  }

  void _submit() {
    final String ssid = ssidController.text.trim();
    if (ssid.isEmpty) {
      setState(() => ssidError = 'Please enter the network name');
      return;
    }
    if (ssid.contains(',')) {
      setState(() => ssidError = "Names with a comma aren't supported yet");
      return;
    }
    Navigator.of(context).pop((ssid, passwordController.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Join a hidden network'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ssidController,
              decoration: InputDecoration(
                labelText: 'Network name',
                border: const OutlineInputBorder(),
                errorText: ssidError,
              ),
              autofocus: true,
              onChanged: (_) {
                if (ssidError != null) {
                  setState(() => ssidError = null);
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
                  icon: Icon(
                      obscure ? Icons.visibility_off : Icons.visibility),
                  tooltip: obscure ? 'Show password' : 'Hide password',
                  onPressed: () => setState(() => obscure = !obscure),
                ),
              ),
              obscureText: obscure,
              onSubmitted: (_) => _submit(),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          child: const Text('Cancel'),
          onPressed: () => Navigator.of(context).pop(),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Join'),
        ),
      ],
    );
  }
}

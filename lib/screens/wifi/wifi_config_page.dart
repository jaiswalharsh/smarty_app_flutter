import 'dart:async';
import 'package:flutter/material.dart';
import '../../services/ble_manager.dart';
import 'wifi_network_page.dart';

/// "Smarty's Wi-Fi" (from Home / Settings): shows the toy's network and lets
/// the parent change or forget it. Setup goes to [WifiNetworkPage] directly.
class WifiConfigPage extends StatefulWidget {
  const WifiConfigPage({super.key});

  @override
  WifiConfigPageState createState() => WifiConfigPageState();
}

class WifiConfigPageState extends State<WifiConfigPage> {
  // BLE manager
  final BleManager _bleManager = BleManager();

  // Current Wi-Fi information
  String _currentWifiName = "Unknown";
  bool _isLoading = true;
  // In-flight lock for "Forget Wi-Fi Network" (blocks double taps).
  bool _isForgettingWifi = false;
  // Link to Smarty is up. While it's down the page stays, with a banner and
  // its actions disabled, instead of closing itself.
  bool _linkUp = BleManager().phase.value == ToyPhase.connected;

  // Stream subscriptions
  StreamSubscription? _wifiStatusSubscription;

  @override
  void initState() {
    super.initState();
    _bleManager.phase.addListener(_onPhaseChanged);
    _initializeWifiConfig();

    // Listen for Wi-Fi status updates
    _wifiStatusSubscription = _bleManager.wifiStatusStream.listen((wifiName) {
      if (!mounted) return;
      setState(() {
        _currentWifiName = wifiName;
      });
    });

    // BLE snackbars are shown app-wide by the single listener in main.dart.
  }

  @override
  void dispose() {
    _bleManager.phase.removeListener(_onPhaseChanged);
    _wifiStatusSubscription?.cancel();
    super.dispose();
  }

  void _onPhaseChanged() {
    if (!mounted) return;
    final bool up = _bleManager.phase.value == ToyPhase.connected;
    if (up == _linkUp) return;
    setState(() => _linkUp = up);
    // Back after a drop: refresh what we show.
    if (up) _initializeWifiConfig();
  }

  // Load the toy's current Wi-Fi status.
  Future<void> _initializeWifiConfig() async {
    if (!_bleManager.isConnected) {
      // Not reachable right now: the lost-touch banner explains, and
      // _onPhaseChanged reloads once the link is back.
      setState(() {
        _isLoading = false;
        _currentWifiName = _bleManager.connectedWifi;
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    // Request a status update to get the latest Wi-Fi information
    try {
      await _bleManager.readStatusUpdate();
      
      // Short delay to allow status to update
      await Future.delayed(Duration(milliseconds: 1000));
    } catch (e) {
      debugPrint("Error getting status update: $e");
    }

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      _currentWifiName = _bleManager.connectedWifi;
    });
  }

  // Open the network list.
  Future<void> _navigateToWifiNetworkPage() async {
    // Buttons are disabled while the link is down; this is just a guard.
    if (!_bleManager.isConnected) return;
    // WifiNetworkPage pops `true` once the toy has actually joined a network.
    final ok = await Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => WifiNetworkPage()),
    );
    if (!mounted) return;
    if (ok == true) {
      // Stay here and refresh the displayed Wi-Fi status.
      await _bleManager.readStatusUpdate();
      if (!mounted) return;
      setState(() {
        _currentWifiName = _bleManager.connectedWifi;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Smarty is connected to Wi-Fi!'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  // Reset Wi-Fi connection (after the parent confirms).
  Future<void> _resetWifiConnection() async {
    if (_isForgettingWifi) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Forget Wi-Fi network?'),
        content: Text(
          "Smarty will disconnect from its Wi-Fi network and won't be able to "
          "talk until you set up Wi-Fi again.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || _isForgettingWifi) return;

    setState(() {
      _isForgettingWifi = true;
    });
    try {
      bool success = await _bleManager.resetWifiConnection();
      if (!mounted) return;

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Smarty forgot its Wi-Fi network'))
        );
        // Wait for device to process reset, then refresh status
        await Future.delayed(Duration(milliseconds: 500));
        await _bleManager.readStatusUpdate();
        if (mounted) {
          setState(() {
            _currentWifiName = _bleManager.connectedWifi;
          });
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't forget the Wi-Fi network. Please try again."))
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isForgettingWifi = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: GestureDetector(
        // Dismiss keyboard when tapping outside of text fields
        onTap: () {
          FocusScope.of(context).unfocus();
        },
        child: Scaffold(
          appBar: AppBar(
            title: Text(
              "Smarty's Wi-Fi",
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
            elevation: 2,
            backgroundColor: Theme.of(context).primaryColor,
            foregroundColor: Colors.white,
            leading: IconButton(
              icon: Icon(Icons.arrow_back),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
          body: _isLoading
              ? _buildLoadingView()
              : _buildContentView(),
        ),
      ),
    );
  }

  // Loading view
  Widget _buildLoadingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: const [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text("Checking Smarty's Wi-Fi…"),
        ],
      ),
    );
  }

  // Main content view based on Wi-Fi connection state
  Widget _buildContentView() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (!_linkUp) const LostTouchBanner(),
          // Content based on Wi-Fi connection state
          if (!_bleManager.isWifiConnected)
            _buildWifiNotConnectedView()
          else
            _buildWifiConnectedView(),
        ],
      ),
    );
  }

  // View when not connected to Wi-Fi
  Widget _buildWifiNotConnectedView() {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Status card
          Card(
            elevation: 4,
            margin: EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.wifi_off, color: Colors.orange),
                      SizedBox(width: 8),
                      Text(
                        'Not on Wi-Fi',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Smarty needs Wi-Fi to talk.',
                    style: TextStyle(
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Configure Wi-Fi button
          ElevatedButton.icon(
            icon: Icon(Icons.wifi),
            label: Text('Set Up Wi-Fi'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: _linkUp ? _navigateToWifiNetworkPage : null,
          ),
          
          // Space at the bottom for future elements
          Spacer(),
        ],
      ),
    );
  }

  // View when connected to Wi-Fi
  Widget _buildWifiConnectedView() {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Wi-Fi status card
          Card(
            elevation: 4,
            margin: EdgeInsets.only(bottom: 16),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.wifi, color: Colors.green),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Connected to Wi-Fi',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 8),
                  Text(
                    _currentWifiName.isEmpty
                    ? 'Connected'
                    : 'Network: $_currentWifiName',
                    style: TextStyle(
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
          
          // Buttons
          ElevatedButton.icon(
            icon: Icon(Icons.refresh),
            label: Text('Change Wi-Fi Network'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed: _linkUp ? _navigateToWifiNetworkPage : null,
          ),
          
          SizedBox(height: 12),
          
          OutlinedButton.icon(
            icon: _isForgettingWifi
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(Icons.power_off),
            label: Text('Forget Wi-Fi Network'),
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            onPressed:
                _isForgettingWifi || !_linkUp ? null : _resetWifiConnection,
          ),
          
          // Space at the bottom for future elements
          Spacer(),
        ],
      ),
    );
  }
}


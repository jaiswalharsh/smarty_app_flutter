import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'services/ble_manager.dart';
import 'services/ble_service.dart';
import 'screens/devices/smarty_connection_page.dart';
import 'screens/wifi/wifi_config_page.dart';

class HomeTab extends StatefulWidget {
  const HomeTab({super.key});

  @override
  State<HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<HomeTab> with SingleTickerProviderStateMixin {
  final BleManager _bleManager = BleManager();
  late AnimationController _animationController;
  bool _showSuccessState = false;
  String _connectedWifi = "Unknown";
  String _batteryLevel = "Unknown";
  StreamSubscription? _wifiStatusSubscription;
  StreamSubscription? _batteryStatusSubscription;
  StreamSubscription? _showSnackBarSubscription;
  bool _isConnectingDevice = false;
  // True when a uid-scoped toy is saved for auto-reconnect. Lets the
  // disconnected view tell "toy is off/out of range" apart from "never paired".
  bool _hasSavedDevice = false;
  // Watchdog for a status read that never lands: if we stay on "Unknown" while
  // BLE-connected past the timeout, surface a manual refresh instead of spinning
  // "Checking WiFi..." forever.
  Timer? _wifiStallTimer;
  bool _wifiStatusStalled = false;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialDeviceCheck();
    });

    _wifiStatusSubscription = _bleManager.wifiStatusStream.listen((wifiName) {
      if (!mounted) return;
      // A status event just proved the link is alive — stand down the stall watch.
      _wifiStallTimer?.cancel();
      setState(() {
        _connectedWifi = wifiName;
        _wifiStatusStalled = false;
      });
      // The toy dropping (or being forgotten in Settings) surfaces as
      // "NotConnected" — re-check whether a saved toy still exists so the
      // disconnected view offers the right recovery path.
      if (wifiName == "NotConnected") {
        _refreshSavedDeviceFlag();
      }
    });

    _batteryStatusSubscription = _bleManager.batteryStatusStream.listen((batteryLevel) {
      if (!mounted) return;
      setState(() {
        _batteryLevel = batteryLevel.toString();
      });
    });

    _showSnackBarSubscription = _bleManager.showSnackBarStream.listen((message) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    });

    _animationController = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 800),
    )..addListener(() {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _wifiStatusSubscription?.cancel();
    _batteryStatusSubscription?.cancel();
    _showSnackBarSubscription?.cancel();
    _wifiStallTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  void _initialDeviceCheck() async {
    if (_bleManager.isConnected) {
      // Device already connected via BLE manager
      setState(() {
        _connectedWifi = _bleManager.connectedWifi;
        _batteryLevel = _bleManager.batteryLevel.toString();
        _isConnectingDevice = false;
      });
      // Fetch status updates in background if needed
      if (_connectedWifi == "Unknown" || _batteryLevel == "Unknown") {
        _fetchStatusInBackground();
      }
      _armWifiStallTimer();
    } else {
      // Check for connected devices without assuming connection attempt
      await _checkForConnectedDevices();
    }
  }

  Future<void> _checkForConnectedDevices() async {
    if (!mounted) return;

    try {
      // Do not set _isConnectingDevice = true here to avoid reconnecting view
      List<BluetoothDevice> connectedDevices = await BleService.getConnectedDevices();

      if (!mounted) return;

      if (connectedDevices.isNotEmpty) {
        for (BluetoothDevice device in connectedDevices) {
          if (device.platformName.toLowerCase().contains("smarty")) {
            await _bleManager.initialize(device);
            if (!mounted) return;
            setState(() {
              _isConnectingDevice = false;
            });
            _fetchStatusInBackground();
            _armWifiStallTimer();
            return;
          }
        }
      }

      // Try auto-reconnect to saved device (ESP32 should be advertising in reconnect mode)
      String? savedDeviceId = await _bleManager.getSavedDeviceId();
      if (savedDeviceId != null) {
        if (mounted) {
          setState(() {
            _hasSavedDevice = true;
            _isConnectingDevice = true;
          });
        }
        bool autoReconnected = await _bleManager.autoReconnectToSavedDevice();
        if (autoReconnected && _bleManager.connectedDevice != null) {
          if (!mounted) return;
          setState(() {
            _connectedWifi = _bleManager.connectedWifi;
            _batteryLevel = _bleManager.batteryLevel.toString();
            _isConnectingDevice = false;
          });
          _fetchStatusInBackground();
          _armWifiStallTimer();
          return;
        }
      } else if (mounted && _hasSavedDevice) {
        // A previously-saved toy was forgotten elsewhere — fall back to the
        // never-paired copy in the disconnected view.
        setState(() {
          _hasSavedDevice = false;
        });
      }

      // Fall back to restoring connection (e.g., after hot restart)
      bool restored = await _bleManager.restoreConnectionsAfterHotRestart();

      if (!mounted) return;

      if (restored) {
        setState(() {
          _connectedWifi = _bleManager.connectedWifi;
          _batteryLevel = _bleManager.batteryLevel.toString();
          _isConnectingDevice = false;
        });
        // Fetch status updates in background if needed
        if (_connectedWifi == "Unknown" || _batteryLevel == "Unknown") {
          _fetchStatusInBackground();
        }
        _armWifiStallTimer();
      } else {
        // No device found, show disconnected view immediately
        setState(() {
          _isConnectingDevice = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnectingDevice = false;
        });
      }
    }
  }

  // Owns the "you're done!" celebration: flip the flag AND kick off the
  // animation here (not in build) so triggering it stays a deliberate action
  // rather than a build side-effect. The success view only renders while the
  // device is connected (see the build ternary).
  void _activateSuccessCelebration() {
    if (!mounted) return;
    setState(() {
      _showSuccessState = true;
    });
    _animationController.forward(from: 0);
  }

  Future<void> _fetchStatusInBackground() async {
    try {
      // Skip if we already have valid status data
      if (_connectedWifi != "Unknown" && _batteryLevel != "Unknown") {
        return;
      }

      await Future.delayed(Duration(milliseconds: 500)); // Brief delay to prioritize UI

      if (!mounted) return;

      await _bleManager.readStatusUpdate();

      if (!mounted) return;

      setState(() {
        _connectedWifi = _bleManager.connectedWifi;
        _batteryLevel = _bleManager.batteryLevel.toString();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectedWifi = "Error";
          _batteryLevel = "Error";
        });
      }
    }
  }

  // Re-read whether a uid-scoped toy is still saved, repainting only if the
  // answer changed — keeps the disconnected view honest after a "forget device".
  Future<void> _refreshSavedDeviceFlag() async {
    final bool hasSaved = (await _bleManager.getSavedDeviceId()) != null;
    if (!mounted || hasSaved == _hasSavedDevice) return;
    setState(() {
      _hasSavedDevice = hasSaved;
    });
  }

  // Manual status refresh (pull-to-refresh, or the "couldn't check" retry): a
  // fresh GATT read of the status characteristic, then re-arm the stall watch if
  // we're still waiting on a first value.
  Future<void> _refreshStatus() async {
    try {
      await _bleManager.readStatusUpdate();
      if (!mounted) return;
      setState(() {
        _connectedWifi = _bleManager.connectedWifi;
        _batteryLevel = _bleManager.batteryLevel.toString();
        _wifiStatusStalled = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connectedWifi = "Error";
        _batteryLevel = "Error";
        _wifiStatusStalled = false;
      });
    }
    // Empty read (still "Unknown")? Re-arm the watchdog. Also cancels any prior timer.
    _armWifiStallTimer();
  }

  // (Re)start the stall watchdog. Only arms while stuck on "Unknown" AND
  // BLE-connected; a landed status (via wifiStatusStream) cancels it. Never call
  // from build() — this schedules a timer.
  void _armWifiStallTimer() {
    _wifiStallTimer?.cancel();
    if (_connectedWifi == "Unknown" && _bleManager.isConnected) {
      _wifiStallTimer = Timer(const Duration(seconds: 12), () {
        if (!mounted) return;
        setState(() {
          _wifiStatusStalled = true;
        });
      });
    }
  }

  // Opens the pair/setup flow. Shared by the never-paired "Connect" button and
  // the "Set up a different Smarty" fallback so the success-celebration and
  // re-check handling lives in exactly one place.
  void _openConnectionPage() {
    setState(() {
      _isConnectingDevice = true; // Show reconnecting view during user-initiated connection
    });
    Navigator.push<bool>(
      context,
      MaterialPageRoute(builder: (context) => SmartyConnectionPage()),
    ).then((result) {
      // `true` means WiFi was just set up — celebrate. Reconnecting an
      // already-online toy pops with no result, so no confetti then.
      if (result == true) {
        _activateSuccessCelebration();
      }
      _checkForConnectedDevices();
    });
  }

  @override
  Widget build(BuildContext context) {
    bool isDeviceConnected = _bleManager.isConnected;

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(20.0),
            child: isDeviceConnected
                ? _showSuccessState
                    ? _buildSuccessView()
                    : _buildConnectedView()
                : _buildDeviceNotConnectedView(),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceNotConnectedView() {
    return _isConnectingDevice ? _buildReconnectingView() : _buildDisconnectedView();
  }

  // A saved-but-unreachable toy gets a recovery path; a phone that has never
  // paired gets the original invite. _hasSavedDevice is kept fresh by
  // _checkForConnectedDevices and the wifiStatusStream listener.
  Widget _buildDisconnectedView() {
    return _hasSavedDevice ? _buildCantFindDeviceView() : _buildNeverPairedView();
  }

  Widget _buildNeverPairedView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset(
            'assets/images/icon.png',
            width: 80,
            height: 80,
          ),
          SizedBox(height: 20),
          Text(
            'No Device Connected',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800,
            ),
          ),
          SizedBox(height: 12),
          Text(
            'Pair your Smarty to start the fun!',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade600,
            ),
          ),
          SizedBox(height: 24),
          AnimatedScaleButton(
            onPressed: _openConnectionPage,
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.blue.shade600,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.shade200.withOpacity(0.4),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.bluetooth, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Connect',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // Shown when a toy is saved but the reconnect attempt failed — most likely the
  // toy is off or out of range, not that setup never happened.
  Widget _buildCantFindDeviceView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Image.asset(
            'assets/images/icon.png',
            width: 80,
            height: 80,
          ),
          SizedBox(height: 20),
          Text(
            "Can't find your Smarty",
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800,
            ),
          ),
          SizedBox(height: 12),
          Text(
            'It might be turned off or out of range. Turn it on, then try again.',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade600,
            ),
          ),
          SizedBox(height: 24),
          AnimatedScaleButton(
            onPressed: () {
              _checkForConnectedDevices();
            },
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.blue.shade600,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.shade200.withOpacity(0.4),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.refresh, color: Colors.white, size: 20),
                  SizedBox(width: 8),
                  Text(
                    'Try Again',
                    style: TextStyle(
                      fontSize: 16,
                      color: Colors.white,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: 12),
          TextButton(
            onPressed: _openConnectionPage,
            child: Text(
              'Set up a different Smarty',
              style: TextStyle(
                fontSize: 14,
                color: Colors.blue.shade600,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectedView() {
    return RefreshIndicator(
      onRefresh: _refreshStatus,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              padding: EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.blue.shade50,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                children: [
                  Container(
                    padding: EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade100,
                      shape: BoxShape.circle,
                    ),
                    child: Image.asset(
                      'assets/images/icon.png',
                      width: 24,
                      height: 24,
                    ),
                  ),
                  SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Smarty Connected',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: Colors.blue.shade900,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        _connectedSubtitle(),
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.blue.shade700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            SizedBox(height: 20),
            _buildWifiStatusCard(),
            // NOTE: battery status card intentionally omitted — the device has no
            // battery sensing yet (firmware returns a fixed placeholder), so showing
            // a precise "%" would mislead parents (APP-7 / FW-21). Restore this card
            // once real battery telemetry exists.
          ],
        ),
      ),
    );
  }

  // Honest one-liner under "Smarty Connected". Order matters: an errored/stalled
  // read must not read as "Ready to play", and a stalled read is still literally
  // "Unknown", so it's checked before the loading case.
  String _connectedSubtitle() {
    if (_connectedWifi == "Error" || _wifiStatusStalled) return 'Status unavailable';
    if (_connectedWifi == "Unknown") return 'Fetching status...';
    if (_bleManager.isWifiConnected) return 'Ready to play';
    return 'WiFi setup needed';
  }

  // Four states: couldn't-check (stalled/errored, offers retry), still-loading,
  // connected, and BLE-up-but-WiFi-down (offers a setup shortcut).
  Widget _buildWifiStatusCard() {
    if (_wifiStatusStalled || _connectedWifi == "Error") {
      return _buildStatusCard(
        icon: Icons.wifi_find,
        color: Colors.orange,
        title: "Couldn't check WiFi status",
        isLoading: false,
        trailing: IconButton(
          icon: Icon(Icons.refresh, color: Colors.orange.shade700),
          tooltip: 'Refresh',
          onPressed: () {
            setState(() {
              _wifiStatusStalled = false;
              _connectedWifi = "Unknown"; // show the spinner again while we retry
            });
            _refreshStatus();
          },
        ),
      );
    }

    if (_connectedWifi == "Unknown") {
      return _buildStatusCard(
        icon: null,
        color: Colors.orange,
        title: 'Checking WiFi...',
        isLoading: true,
      );
    }

    if (_bleManager.isWifiConnected) {
      return _buildStatusCard(
        icon: Icons.wifi,
        color: Colors.green,
        title: 'WiFi: $_connectedWifi',
        isLoading: false,
      );
    }

    return _buildStatusCard(
      icon: Icons.wifi_off,
      color: Colors.orange,
      title: 'WiFi: Not connected',
      isLoading: false,
      trailing: TextButton(
        onPressed: () async {
          await Navigator.push(
            context,
            MaterialPageRoute(builder: (context) => WifiConfigPage()),
          );
          await _refreshStatus();
        },
        child: Text(
          'Set up',
          style: TextStyle(
            color: Colors.orange.shade700,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildStatusCard({
    IconData? icon,
    required Color color,
    required String title,
    required bool isLoading,
    Widget? trailing,
  }) {
    return Container(
      padding: EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.grey.shade200,
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          isLoading
              ? SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                )
              : Icon(icon, color: color, size: 20),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 14,
                color: Colors.grey.shade800,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  Widget _buildSuccessView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _animationController,
            builder: (context, child) {
              return Transform.scale(
                scale: 0.8 + (_animationController.value * 0.2),
                child: Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: Colors.green.shade100,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.check,
                    size: 60,
                    color: Colors.green.shade600,
                  ),
                ),
              );
            },
          ),
          SizedBox(height: 20),
          Text(
            'Connected!',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800,
            ),
          ),
          SizedBox(height: 12),
          Text(
            'Your Smarty is ready.',
            style: TextStyle(
              fontSize: 16,
              color: Colors.grey.shade600,
            ),
          ),
          SizedBox(height: 24),
          AnimatedScaleButton(
            onPressed: () {
              setState(() {
                _showSuccessState = false;
                _animationController.reset();
              });
            },
            child: Container(
              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              decoration: BoxDecoration(
                color: Colors.blue.shade600,
                borderRadius: BorderRadius.circular(12),
                boxShadow: [
                  BoxShadow(
                    color: Colors.blue.shade200.withOpacity(0.4),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                'Continue',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
          AnimatedBuilder(
            animation: _animationController,
            builder: (context, child) {
              return _animationController.value > 0
                  ? CustomPaint(
                      painter: ConfettiPainter(progress: _animationController.value),
                      size: Size.infinite,
                    )
                  : SizedBox.shrink();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildReconnectingView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(
            color: Colors.blue.shade600,
            strokeWidth: 3,
          ),
          SizedBox(height: 16),
          Text(
            'Connecting...',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Please wait a moment',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade600,
            ),
          ),
        ],
      ),
    );
  }

}

class ConfettiPainter extends CustomPainter {
  final double progress;
  final Random random = Random();

  ConfettiPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    final confettiCount = 50;

    for (int i = 0; i < confettiCount; i++) {
      final x = random.nextDouble() * size.width;
      final y = size.height * (0.3 + 0.7 * progress) - random.nextDouble() * size.height * progress;
      final colors = [
        Colors.blue.shade400,
        Colors.green.shade400,
        Colors.yellow.shade400,
        Colors.red.shade400,
      ];
      paint.color = colors[random.nextInt(colors.length)];
      final confettiSize = 4 + random.nextDouble() * 4;

      canvas.drawCircle(Offset(x, y), confettiSize / 2, paint);
    }
  }

  @override
  bool shouldRepaint(ConfettiPainter oldDelegate) => oldDelegate.progress != progress;
}

class AnimatedScaleButton extends StatefulWidget {
  final VoidCallback onPressed;
  final Widget child;

  const AnimatedScaleButton({required this.onPressed, required this.child, super.key});

  @override
  _AnimatedScaleButtonState createState() => _AnimatedScaleButtonState();
}

class _AnimatedScaleButtonState extends State<AnimatedScaleButton> with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: 100),
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => _controller.forward(),
      onTapUp: (_) {
        _controller.reverse();
        widget.onPressed();
      },
      onTapCancel: () => _controller.reverse(),
      child: AnimatedBuilder(
        animation: _scaleAnimation,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: widget.child,
          );
        },
      ),
    );
  }
}
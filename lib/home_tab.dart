import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'services/ble_manager.dart';
import 'services/ble_service.dart';
import 'screens/devices/smarty_connection_page.dart';

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
  BluetoothDevice? _connectedDevice;

  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialDeviceCheck();
    });

    _wifiStatusSubscription = _bleManager.wifiStatusStream.listen((wifiName) {
      if (!mounted) return;
      setState(() {
        _connectedWifi = wifiName;
        if (wifiName == "NotConnected") {
          _connectedDevice = null;
        }
      });
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
    _animationController.dispose();
    super.dispose();
  }

  void _initialDeviceCheck() async {
    if (_bleManager.isConnected) {
      // Device already connected via BLE manager
      setState(() {
        _connectedDevice = _bleManager.connectedDevice;
        _connectedWifi = _bleManager.connectedWifi;
        _batteryLevel = _bleManager.batteryLevel.toString();
        _isConnectingDevice = false;
      });
      // Fetch status updates in background if needed
      if (_connectedWifi == "Unknown" || _batteryLevel == "Unknown") {
        _fetchStatusInBackground(_bleManager.connectedDevice!);
      }
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
            _bleManager.initialize(device);
            setState(() {
              _connectedDevice = device;
              _isConnectingDevice = false;
            });
            _fetchStatusInBackground(device);
            return;
          }
        }
      }

      // Try restoring connection only if there's a reasonable chance (e.g., after hot restart)
      bool restored = await _bleManager.restoreConnectionsAfterHotRestart();

      if (!mounted) return;

      if (restored) {
        setState(() {
          _connectedDevice = _bleManager.connectedDevice;
          _connectedWifi = _bleManager.connectedWifi;
          _batteryLevel = _bleManager.batteryLevel.toString();
          _isConnectingDevice = false;
        });
        // Fetch status updates in background if needed
        if (_connectedWifi == "Unknown" || _batteryLevel == "Unknown") {
          _fetchStatusInBackground(_bleManager.connectedDevice!);
        }
      } else {
        // No device found, show disconnected view immediately
        setState(() {
          _connectedDevice = null;
          _isConnectingDevice = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectedDevice = null;
          _isConnectingDevice = false;
        });
      }
    }
  }

  Future<void> _fetchStatusInBackground(BluetoothDevice device) async {
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

  @override
  Widget build(BuildContext context) {
    bool isDeviceConnected = _bleManager.isConnected || _connectedDevice != null;

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

  Widget _buildDisconnectedView() {
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
            onPressed: () {
              setState(() {
                _isConnectingDevice = true; // Show reconnecting view during user-initiated connection
              });
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => SmartyConnectionPage()),
              ).then((_) {
                _checkForConnectedDevices();
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

  Widget _buildConnectedView() {
    bool isWifiLoading = _connectedWifi == "Unknown";
    bool isBatteryLoading = _batteryLevel == "Unknown";

    return SingleChildScrollView(
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
                      (isWifiLoading || isBatteryLoading) ? 'Fetching status...' : 'Ready to play',
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
          _buildStatusCard(
            icon: isWifiLoading ? null : _bleManager.isWifiConnected ? Icons.wifi : Icons.wifi_off,
            color: _bleManager.isWifiConnected ? Colors.green : Colors.orange,
            title: isWifiLoading ? 'Checking WiFi...' : _bleManager.isWifiConnected ? 'WiFi: $_connectedWifi' : 'WiFi: Not connected',
            isLoading: isWifiLoading,
          ),
          SizedBox(height: 12),
          _buildStatusCard(
            icon: isBatteryLoading ? null : _getBatteryIcon(),
            color: _getBatteryColor(),
            title: isBatteryLoading ? 'Checking battery...' : 'Battery: $_batteryLevel%',
            isLoading: isBatteryLoading,
          ),
        ],
      ),
    );
  }

  Widget _buildStatusCard({
    IconData? icon,
    required Color color,
    required String title,
    required bool isLoading,
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
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey.shade800,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSuccessView() {
    _animationController.forward();

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

  IconData _getBatteryIcon() {
    int level = int.tryParse(_batteryLevel) ?? 0;
    if (level >= 90) return Icons.battery_full;
    if (level >= 70) return Icons.battery_6_bar;
    if (level >= 50) return Icons.battery_4_bar;
    if (level >= 30) return Icons.battery_3_bar;
    if (level >= 20) return Icons.battery_2_bar;
    if (level >= 10) return Icons.battery_1_bar;
    return Icons.battery_0_bar;
  }

  Color _getBatteryColor() {
    int level = int.tryParse(_batteryLevel) ?? 0;
    if (level >= 50) return Colors.green;
    if (level >= 20) return Colors.orange;
    return Colors.red;
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
import 'package:flutter/material.dart';
import '../../services/device_registration_service.dart';

class DeviceRegistrationPage extends StatefulWidget {
  const DeviceRegistrationPage({super.key});

  @override
  State<DeviceRegistrationPage> createState() => _DeviceRegistrationPageState();
}

class _DeviceRegistrationPageState extends State<DeviceRegistrationPage> {
  final DeviceRegistrationService _registrationService = DeviceRegistrationService();

  String _status = 'Preparing registration...';
  int _currentStep = 0; // 0=reading, 1=registering, 2=writing, 3=done, -1=error
  String? _errorMessage;
  bool _isRegistering = false;

  @override
  void initState() {
    super.initState();
    _startRegistration();
  }

  Future<void> _startRegistration() async {
    if (_isRegistering) return;
    _isRegistering = true;

    try {
      // Step 1: Read device_id
      if (!mounted) return;
      setState(() {
        _currentStep = 0;
        _status = 'Reading device ID...';
      });

      final deviceId = await _registrationService.readDeviceId();
      if (!mounted) return;
      if (deviceId == null || deviceId.isEmpty || deviceId == '{}') {
        setState(() {
          _currentStep = -1;
          _errorMessage = 'Could not read device ID. Make sure the device is connected.';
        });
        return;
      }

      // Step 2: Register with Cloud Function
      setState(() {
        _currentStep = 1;
        _status = 'Registering device...';
      });

      final secret = await _registrationService.registerDevice(deviceId);
      if (!mounted) return;
      if (secret == null) {
        setState(() {
          _currentStep = -1;
          _errorMessage = 'Device registration failed. Please check your internet connection and try again.';
        });
        return;
      }

      // Step 3: Write secret to device
      setState(() {
        _currentStep = 2;
        _status = 'Saving to device...';
      });

      final written = await _registrationService.writeSecretToDevice(secret);
      if (!mounted) return;
      if (!written) {
        setState(() {
          _currentStep = -1;
          _errorMessage = 'Failed to save registration to device. Please try again.';
        });
        return;
      }

      // Done
      setState(() {
        _currentStep = 3;
        _status = 'Registration complete!';
      });

      // Auto-close after brief delay
      await Future.delayed(const Duration(seconds: 2));
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } finally {
      _isRegistering = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Device Registration'),
        backgroundColor: Theme.of(context).primaryColor,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (_currentStep >= 0 && _currentStep < 3) ...[
              CircularProgressIndicator(color: Colors.blue.shade600),
              SizedBox(height: 24),
              Text(
                _status,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w500),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 32),
              _buildStepIndicator(),
            ] else if (_currentStep == 3) ...[
              Icon(Icons.check_circle, color: Colors.green, size: 64),
              SizedBox(height: 16),
              Text(
                'Registration Complete!',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: Colors.green.shade700,
                ),
              ),
              SizedBox(height: 8),
              Text(
                'Your Smarty is ready to use.',
                style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
              ),
            ] else ...[
              Icon(Icons.error_outline, color: Colors.red, size: 64),
              SizedBox(height: 16),
              Text(
                'Registration Failed',
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w600,
                  color: Colors.red.shade700,
                ),
              ),
              SizedBox(height: 8),
              Text(
                _errorMessage ?? 'An unknown error occurred.',
                style: TextStyle(fontSize: 16, color: Colors.grey.shade600),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: () {
                  setState(() {
                    _errorMessage = null;
                  });
                  _startRegistration();
                },
                icon: Icon(Icons.refresh),
                label: Text('Retry'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.blue.shade600,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStepIndicator() {
    final steps = ['Read ID', 'Register', 'Save'];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(steps.length, (index) {
        final isActive = index == _currentStep;
        final isDone = index < _currentStep;
        return Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isDone
                    ? Colors.green
                    : isActive
                        ? Colors.blue.shade600
                        : Colors.grey.shade300,
              ),
              child: Center(
                child: isDone
                    ? Icon(Icons.check, color: Colors.white, size: 18)
                    : Text(
                        '${index + 1}',
                        style: TextStyle(
                          color: isActive ? Colors.white : Colors.grey.shade600,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
              ),
            ),
            SizedBox(width: 4),
            Text(
              steps[index],
              style: TextStyle(
                fontSize: 12,
                color: isActive ? Colors.blue.shade600 : Colors.grey.shade500,
                fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            if (index < steps.length - 1)
              Container(
                width: 24,
                height: 2,
                margin: EdgeInsets.symmetric(horizontal: 8),
                color: isDone ? Colors.green : Colors.grey.shade300,
              ),
          ],
        );
      }),
    );
  }
}

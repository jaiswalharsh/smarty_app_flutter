import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/ble_manager.dart';
import '../utils/theme_provider.dart';

class UserPreferencesPage extends StatefulWidget {
  const UserPreferencesPage({super.key});

  @override
  _UserPreferencesPageState createState() => _UserPreferencesPageState();
}

class _UserPreferencesPageState extends State<UserPreferencesPage> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _ageController = TextEditingController();
  final _hobbyController = TextEditingController();
  final BleManager _bleManager = BleManager();
  bool _isSending = false;
  int _currentStep = 0;

  final List<String> _smartyQuestions = [
    "Hi there! I'm Smarty, your new friend. What's your name?",
    "Nice to meet you! How old are you? I'm curious!",
    "Awesome! What's your favorite thing to do? I love learning about hobbies!",
  ];

  @override
  void dispose() {
    _nameController.dispose();
    _ageController.dispose();
    _hobbyController.dispose();
    super.dispose();
  }

  Future<void> _sendProfileData() async {
    if (!_formKey.currentState!.validate()) return;

    if (!_bleManager.isConnected) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('No Smarty device connected'),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() {
      _isSending = true;
    });

    try {
      final success = await _bleManager.sendUserData(
        _nameController.text.trim(),
        _ageController.text.trim(),
        _hobbyController.text.trim(),
      );

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Thanks, ${_nameController.text.trim()}! I can’t wait to play with you!',
            ),
            backgroundColor: Colors.green,
          ),
        );

        // Navigate back to SettingsTab
        Navigator.of(context).pop();
      } else {
        throw Exception('Failed to write to userDataCharacteristic');
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to send profile: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      setState(() {
        _isSending = false;
      });
    }
  }

  void _nextStep() {
    if (_currentStep < 2) {
      setState(() {
        _currentStep++;
      });
    } else {
      _sendProfileData();
    }
  }

  @override
  Widget build(BuildContext context) {
    final themeProvider = Provider.of<ThemeProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          'Meet Smarty!',
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
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Smarty's question with icon
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Image.asset(
                      'assets/images/icon.png',
                      width: 40,
                      height: 40,
                      color:
                          themeProvider.isDarkMode
                              ? Color(0xFFFF6EC7)
                              : Colors.blue.shade600,
                    ),
                    SizedBox(width: 10),
                    Expanded(
                      child: Container(
                        padding: EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color:
                              themeProvider.isDarkMode
                                  ? Color(0xFF2C2C44)
                                  : Colors.blue.shade50,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          _smartyQuestions[_currentStep],
                          style: TextStyle(
                            fontSize: 16,
                            color:
                                themeProvider.isDarkMode
                                    ? Colors.white
                                    : Colors.blue.shade800,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                SizedBox(height: 20),
                // Input field based on current step
                if (_currentStep == 0)
                  _buildTextField(
                    controller: _nameController,
                    label: 'Your name',
                    hint: 'e.g., Emma',
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter a name';
                      }
                      return null;
                    },
                    themeProvider: themeProvider,
                  )
                else if (_currentStep == 1)
                  _buildTextField(
                    controller: _ageController,
                    label: 'Your age',
                    hint: 'e.g., 7',
                    keyboardType: TextInputType.number,
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter an age';
                      }
                      final age = int.tryParse(value.trim());
                      if (age == null || age < 2 || age > 12) {
                        return 'Please enter an age between 2 and 12';
                      }
                      return null;
                    },
                    themeProvider: themeProvider,
                  )
                else if (_currentStep == 2)
                  _buildTextField(
                    controller: _hobbyController,
                    label: 'Your favorite hobby',
                    hint: 'e.g., Playing soccer',
                    validator: (value) {
                      if (value == null || value.trim().isEmpty) {
                        return 'Please enter a hobby';
                      }
                      return null;
                    },
                    themeProvider: themeProvider,
                  ),
                SizedBox(height: 20),
                // Next or Send button
                Center(
                  child: ElevatedButton(
                    onPressed: _isSending ? null : _nextStep,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blue.shade600,
                      foregroundColor: Colors.white,
                      padding: EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 4,
                    ),
                    child:
                        _isSending
                            ? SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                color: Colors.white,
                                strokeWidth: 2,
                              ),
                            )
                            : Text(
                              _currentStep < 2 ? 'Next' : 'Send to Smarty',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required String label,
    required String hint,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    required ThemeProvider themeProvider,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
        filled: true,
        fillColor:
            themeProvider.isDarkMode ? Color(0xFF2C2C44) : Colors.grey.shade100,
        labelStyle: TextStyle(
          color: themeProvider.isDarkMode ? Colors.white70 : Colors.black54,
        ),
      ),
      style: TextStyle(
        color: themeProvider.isDarkMode ? Colors.white : Colors.black87,
      ),
      validator: validator,
    );
  }
}

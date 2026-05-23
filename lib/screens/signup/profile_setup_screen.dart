import 'package:flutter/material.dart';
import 'package:Ratedly/resources/auth_methods.dart';
import 'package:Ratedly/responsive/mobile_screen_layout.dart';
import 'package:Ratedly/responsive/responsive_layout.dart';
import 'package:Ratedly/utils/utils.dart';
import 'package:Ratedly/widgets/text_filed_input.dart';

class ProfileSetupScreen extends StatefulWidget {
  final DateTime dateOfBirth;
  final VoidCallback onComplete;

  const ProfileSetupScreen({
    Key? key,
    required this.dateOfBirth,
    required this.onComplete,
  }) : super(key: key);

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
  final TextEditingController _usernameController = TextEditingController();
  bool _isLoading = false;
  String? _selectedGender;
  String? _usernameError;
  int _usernameLength = 0;

  final List<String> _genders = ['Male', 'Female'];

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_validateUsername);
  }

  String? _validateUsernameText(String username) {
    if (username.isEmpty) return null;

    if (username.length > 20) {
      return "Username must be 20 characters or fewer";
    }

    if (!RegExp(r'^[a-z0-9_.]+$').hasMatch(username)) {
      return "Only lowercase letters, numbers, . and _ allowed";
    }

    if (username.startsWith('.') ||
        username.startsWith('_') ||
        username.endsWith('.') ||
        username.endsWith('_')) {
      return "Cannot start or end with . or _";
    }

    if (username.contains('..') ||
        username.contains('__') ||
        username.contains('._') ||
        username.contains('_.')) {
      return "Cannot have consecutive . or _ characters";
    }

    return null;
  }

  void _validateUsername() {
    final username = _usernameController.text;
    setState(() {
      _usernameLength = username.length;
      _usernameError = _validateUsernameText(username);
    });
  }

  Future<void> completeProfile() async {
    final usernameError = _validateUsernameText(_usernameController.text);
    if (usernameError != null) {
      setState(() => _usernameError = usernameError);
      showSnackBar(context, usernameError);
      return;
    }

    if (_selectedGender == null) {
      showSnackBar(context, "Please select your gender");
      return;
    }

    setState(() => _isLoading = true);

    // Call Supabase-only completion method
    final res = await AuthMethods().completeProfileSupabase(
      username: _usernameController.text.trim(),
      bio: "",
      file: null,
      dateOfBirth: widget.dateOfBirth,
      gender: _selectedGender!,
    );

    if (res == "success") {
      // Notify completion
      widget.onComplete();

      // Navigate to home
      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(
            builder: (context) => const ResponsiveLayout(
              mobileScreenLayout: MobileScreenLayout(),
            ),
          ),
          (route) => false,
        );
      }
    } else {
      if (mounted) showSnackBar(context, res);
    }

    if (mounted) setState(() => _isLoading = false);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _usernameController.removeListener(_validateUsername);
    super.dispose();
  }

  bool get _isFormValid {
    return _validateUsernameText(_usernameController.text) == null &&
        _selectedGender != null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 60),
                const Text(
                  'Profile Setup',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    fontFamily: 'Montserrat',
                    height: 1.3,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 40),

                // Username Section
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Create your username',
                      style: TextStyle(
                        color: Color(0xFFd9d9d9),
                        fontSize: 14,
                        fontFamily: 'Inter',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFieldInput(
                      hintText: 'username',
                      textInputType: TextInputType.text,
                      textEditingController: _usernameController,
                      fillColor: const Color(0xFF333333),
                      hintStyle: TextStyle(
                        color: Colors.grey[400],
                        fontFamily: 'Inter',
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          if (_usernameError != null)
                            Expanded(
                              child: Text(
                                _usernameError!,
                                style: const TextStyle(
                                  color: Colors.red,
                                  fontSize: 12,
                                ),
                              ),
                            )
                          else
                            const SizedBox.shrink(),
                          Text(
                            '$_usernameLength/20',
                            style: TextStyle(
                              color: _usernameLength > 20
                                  ? Colors.red
                                  : Colors.grey,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 24),

                // Gender Section
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Select your gender',
                      style: TextStyle(
                        color: Color(0xFFd9d9d9),
                        fontSize: 14,
                        fontFamily: 'Inter',
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF333333),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: DropdownButtonFormField<String>(
                          dropdownColor: const Color(0xFF333333),
                          value: _selectedGender,
                          decoration: const InputDecoration(
                            border: InputBorder.none,
                          ),
                          items: _genders.map((String value) {
                            return DropdownMenuItem<String>(
                              value: value,
                              child: Text(
                                value,
                                style: const TextStyle(
                                  color: Color(0xFFd9d9d9),
                                  fontFamily: 'Inter',
                                ),
                              ),
                            );
                          }).toList(),
                          onChanged: (value) =>
                              setState(() => _selectedGender = value),
                          icon: const Icon(Icons.arrow_drop_down,
                              color: Color(0xFFd9d9d9)),
                          style: const TextStyle(
                            color: Color(0xFFd9d9d9),
                            fontFamily: 'Inter',
                          ),
                          hint: const Text(
                            'Choose gender',
                            style: TextStyle(
                              color: Color(0xFFd9d9d9),
                              fontFamily: 'Inter',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 40),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _isFormValid
                        ? const Color(0xFF333333)
                        : const Color(0xFF222222),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    minimumSize: const Size(double.infinity, 50),
                  ),
                  onPressed:
                      _isFormValid && !_isLoading ? completeProfile : null,
                  child: _isLoading
                      ? const CircularProgressIndicator(
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        )
                      : Text(
                          'Complete Profile',
                          style: TextStyle(
                            color:
                                _isFormValid ? Colors.white : Colors.grey[600],
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            fontFamily: 'Inter',
                          ),
                        ),
                ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

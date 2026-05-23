import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/resources/auth_methods.dart';
import 'package:Ratedly/screens/signup/signup_screen.dart';
import 'package:Ratedly/widgets/text_filed_input.dart';
import 'package:Ratedly/responsive/mobile_screen_layout.dart';
import 'package:Ratedly/responsive/responsive_layout.dart';
import 'package:Ratedly/screens/terms_of_service_screen.dart';
import 'package:Ratedly/screens/privacy_policy_screen.dart';
import 'package:Ratedly/screens/signup/auth_wrapper.dart';
import 'package:flutter/foundation.dart';
import 'package:Ratedly/providers/user_provider.dart';

class LoginScreen extends StatefulWidget {
  final String? migrationEmail; // kept for backward compatibility, not used
  final String? migrationUid; // kept for backward compatibility, not used

  const LoginScreen({
    Key? key,
    this.migrationEmail,
    this.migrationUid,
  }) : super(key: key);

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _isLoading = false;
  String _errorMessage = '';
  final SupabaseClient _supabase = Supabase.instance.client;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  void _showSnackBarSafe(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.red : Colors.green,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  Future<void> loginUser() async {
    if (!mounted) return;

    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final String res = await AuthMethods().loginUser(
        email: _emailController.text.trim(),
        password: _passwordController.text,
      );

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (res == 'success' || res == "onboarding_required") {
        final user = await AuthMethods().getUserDetails();
        if (user != null) {
          final userProvider =
              Provider.of<UserProvider>(context, listen: false);
          userProvider.setUser(user);
        }

        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(
            builder: (context) => const ResponsiveLayout(
              mobileScreenLayout: MobileScreenLayout(),
            ),
          ),
          (route) => false,
        );
      } else if (res == "needs_migration") {
        await _migrateWithGoogle();
      } else {
        _showSnackBarSafe(res, isError: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnackBarSafe('An error occurred: $e', isError: true);
      }
    }
  }

  // Common migration method for all users (Google or email/password)
  Future<void> _migrateWithGoogle() async {
    setState(() => _isLoading = true);
    final result = await AuthMethods().migrateGoogleUserNative();
    setState(() => _isLoading = false);

    if (result == "success" || result == "onboarding_required") {
      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => const AuthWrapper()),
        );
      }
    } else if (result == "cancelled") {
      _showSnackBarSafe('Google sign-in cancelled', isError: true);
    } else {
      _showSnackBarSafe(result, isError: true);
    }
  }

  Future<void> loginWithGoogle() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final String res = await AuthMethods().signInWithGoogle();

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (res == "success" || res == "onboarding_required") {
        final user = await AuthMethods().getUserDetails();
        if (user != null) {
          final userProvider =
              Provider.of<UserProvider>(context, listen: false);
          userProvider.setUser(user);
        }

        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (context) => const AuthWrapper()),
          (route) => false,
        );
      } else if (res == "needs_migration") {
        await _migrateWithGoogle();
      } else if (res == "cancelled") {
        _showSnackBarSafe('Google sign-in cancelled', isError: true);
      } else {
        _showSnackBarSafe(res, isError: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Google sign-in failed: $e';
        });
      }
    }
  }

  // 🍎 NATIVE Apple Sign‑in
  Future<void> loginWithAppleNative() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _errorMessage = '';
    });

    try {
      final String res = await AuthMethods().signInWithAppleNative();

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (res == "success" || res == "onboarding_required") {
        if (mounted) {
          Navigator.pushReplacement(
            context,
            MaterialPageRoute(builder: (_) => const AuthWrapper()),
          );
        }
      } else if (res == "needs_migration") {
        await _migrateWithGoogle();
      } else if (res == "cancelled") {
        _showSnackBarSafe('Apple sign-in cancelled', isError: true);
      } else {
        _showSnackBarSafe(res, isError: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = 'Apple sign-in failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24.0),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: MediaQuery.of(context).size.height -
                  MediaQuery.of(context).padding.top,
            ),
            child: IntrinsicHeight(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(flex: 1),
                  Image.asset(
                    'assets/logo/22.png',
                    width: 100,
                    height: 100,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Log In',
                    style: TextStyle(
                      color: Color(0xFFd9d9d9),
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'Montserrat',
                      height: 1.3,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 40),

                  // Email
                  TextFieldInput(
                    hintText: 'Enter your email',
                    textInputType: TextInputType.emailAddress,
                    textEditingController: _emailController,
                    hintStyle: TextStyle(
                      color: Colors.grey[400],
                      fontFamily: 'Inter',
                    ),
                    fillColor: const Color(0xFF333333),
                  ),
                  const SizedBox(height: 24),

                  // Password
                  TextFieldInput(
                    hintText: 'Enter your password',
                    textInputType: TextInputType.text,
                    textEditingController: _passwordController,
                    isPass: true,
                    hintStyle: TextStyle(
                      color: Colors.grey[400],
                      fontFamily: 'Inter',
                    ),
                    fillColor: const Color(0xFF333333),
                  ),
                  const SizedBox(height: 24),

                  // Terms
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16.0),
                    child: RichText(
                      textAlign: TextAlign.center,
                      text: TextSpan(
                        style: TextStyle(
                          color: Colors.grey[400],
                          fontFamily: 'Inter',
                          fontSize: 14,
                        ),
                        children: [
                          const TextSpan(
                              text: 'By logging in, you agree to our '),
                          TextSpan(
                            text: 'Terms of Service',
                            style: const TextStyle(
                              color: Colors.blue,
                              decoration: TextDecoration.underline,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        const TermsOfServiceScreen(),
                                  ),
                                );
                              },
                          ),
                          const TextSpan(text: ' and '),
                          TextSpan(
                            text: 'Privacy Policy',
                            style: const TextStyle(
                              color: Colors.blue,
                              decoration: TextDecoration.underline,
                            ),
                            recognizer: TapGestureRecognizer()
                              ..onTap = () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) =>
                                        const PrivacyPolicyScreen(),
                                  ),
                                );
                              },
                          ),
                        ],
                      ),
                    ),
                  ),

                  // Login Button
                  ElevatedButton(
                    onPressed: _isLoading ? null : loginUser,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF333333),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: _isLoading
                        ? const CircularProgressIndicator(
                            valueColor:
                                AlwaysStoppedAnimation<Color>(Colors.white),
                          )
                        : const Text(
                            'Log In',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              fontFamily: 'Inter',
                            ),
                          ),
                  ),
                  const SizedBox(height: 24),

                  // OR divider
                  Row(
                    children: [
                      const Expanded(
                        child: Divider(
                          color: Colors.grey,
                          thickness: 1,
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8.0),
                        child: Text(
                          'OR',
                          style: TextStyle(
                            color: Colors.grey[400],
                            fontFamily: 'Inter',
                          ),
                        ),
                      ),
                      const Expanded(
                        child: Divider(
                          color: Colors.grey,
                          thickness: 1,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),

                  // Google Sign-in
                  ElevatedButton.icon(
                    onPressed: _isLoading ? null : loginWithGoogle,
                    icon: Image.asset(
                      'assets/logo/google-logo.png',
                      width: 24,
                      height: 24,
                      fit: BoxFit.contain,
                    ),
                    label: _isLoading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor:
                                  AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          )
                        : const Text(
                            'Log in with Google',
                            style: TextStyle(
                              fontFamily: 'Inter',
                              fontWeight: FontWeight.w500,
                              fontSize: 16,
                            ),
                          ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF333333),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 56),
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Apple Sign-in (native)
                  if (!isAndroid || kIsWeb)
                    ElevatedButton.icon(
                      onPressed: _isLoading ? null : loginWithAppleNative,
                      icon: Image.asset(
                        'assets/logo/apple-logo.png',
                        width: 24,
                        height: 24,
                        fit: BoxFit.contain,
                        color: Colors.white,
                      ),
                      label: _isLoading
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor:
                                    AlwaysStoppedAnimation<Color>(Colors.white),
                              ),
                            )
                          : const Text(
                              'Log in with Apple',
                              style: TextStyle(
                                fontFamily: 'Inter',
                                fontWeight: FontWeight.w500,
                                fontSize: 16,
                              ),
                            ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF333333),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(double.infinity, 56),
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    ),
                  if (!isAndroid || kIsWeb) const SizedBox(height: 16),

                  // Signup link
                  TextButton(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (context) => const SignupScreen()),
                    ),
                    child: const Text(
                      'Don\'t have an account? Signup',
                      style: TextStyle(
                        color: Color(0xFFd9d9d9),
                        fontFamily: 'Inter',
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const Spacer(flex: 2),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

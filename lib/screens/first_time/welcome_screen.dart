import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:Ratedly/resources/auth_methods.dart';
import 'package:Ratedly/screens/signup/auth_wrapper.dart';
import 'package:Ratedly/screens/terms_of_service_screen.dart';
import 'package:Ratedly/screens/privacy_policy_screen.dart';
import 'package:Ratedly/services/analytics_service.dart';
import 'package:Ratedly/services/debug_logger.dart';
import 'package:Ratedly/services/device_session.dart';

import '../first_time/falling_number_painter.dart';
import '../first_time/number_particle.dart';

// Helper to log to login_logs table (mirrors the old GetStartedPage/LoginScreen logging)
Future<void> _logLoginEvent({
  required String eventType,
  String? firebaseUid,
  String? supabaseUid,
  String? email,
  bool? hasSupabaseSession,
  String? errorDetails,
  Map<String, dynamic>? additionalData,
}) async {
  try {
    await Supabase.instance.client.from('login_logs').insert({
      'event_type': eventType,
      'firebase_uid': firebaseUid,
      'supabase_uid': supabaseUid,
      'email': email,
      'has_supabase_session': hasSupabaseSession,
      'error_details': errorDetails,
      'additional_data': additionalData,
    });
  } catch (e) {
    // Don't let logging failures break the app
    // ignore: avoid_print
    print('Failed to log to login_logs: $e');
  }
}

/// Single entry point for both new and returning users.
///
/// Replaces GetStartedPage, SignupScreen, and LoginScreen. There is no
/// email/password path anymore — Google and Apple are the only ways in.
/// Account migration (the old "needs_migration" flow) still happens, but
/// silently: if a Google/Apple attempt comes back as needing migration,
/// we just re-run the migration call in the background instead of routing
/// to a separate screen.
///
/// [isMigration]/[migrationEmail]/[migrationUid] are kept only so
/// AuthWrapper can still redirect an already-signed-in-but-unmigrated user
/// here and show a short explanatory message. They are optional and the
/// screen works fine without them.
class WelcomeScreen extends StatefulWidget {
  final bool isMigration;
  final String? migrationEmail;
  final String? migrationUid;

  const WelcomeScreen({
    Key? key,
    this.isMigration = false,
    this.migrationEmail,
    this.migrationUid,
  }) : super(key: key);

  @override
  State<WelcomeScreen> createState() => _WelcomeScreenState();
}

class _WelcomeScreenState extends State<WelcomeScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  final List<NumberParticle> _particles = [];
  final Random _random = Random();
  double _screenHeight = 0;
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _initializeParticles(25);
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..repeat();

    AnalyticsService.screenEnter('welcome');

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final session = _supabase.auth.currentSession;
      final deviceId = await DeviceSession.id;

      DebugLogger.logEvent('SCREEN_ENTERED', 'welcome deviceId=$deviceId');

      _logLoginEvent(
        eventType: 'WELCOME_SCREEN_SHOWN',
        supabaseUid: session?.user.id,
        firebaseUid: deviceId,
        email: session?.user.email,
        hasSupabaseSession: session != null,
        additionalData: {
          'timestamp': DateTime.now().toIso8601String(),
          'isMigration': widget.isMigration,
        },
      );
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _screenHeight = MediaQuery.of(context).size.height;
  }

  void _initializeParticles(int count) {
    _particles.addAll(List.generate(
        count,
        (_) => NumberParticle(
              x: _random.nextDouble(),
              y: -_random.nextDouble() * 0.5,
              speed: 0.5 + _random.nextDouble() * 0.5,
              rotation: _random.nextDouble() * 2 * pi,
              rotationSpeed: _random.nextDouble() * 0.005,
              opacity: 0.5 + _random.nextDouble() * 0.4,
              number: _random.nextInt(10) + 1,
              fontSize: 20 + _random.nextDouble() * 15,
              sway: 0.0,
              swaySpeed: _random.nextDouble() * 0.005,
              color: Colors.white,
            )));
  }

  void _updateParticles() {
    for (final particle in _particles) {
      particle.y += particle.speed * 0.015;
      particle.rotation += particle.rotationSpeed;
      particle.sway += particle.swaySpeed;

      if (particle.y * _screenHeight > _screenHeight * 1.2) {
        particle.y = -_random.nextDouble() * 0.5;
        particle.x = _random.nextDouble();
      }
    }
  }

  @override
  void dispose() {
    final deviceId = DeviceSession.idSync ?? 'anonymous';
    AnalyticsService.screenExit(screenName: 'welcome', uid: deviceId);
    _controller.dispose();
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

  // Silent migration: no separate screen, just re-runs the Google-linked
  // migration call in the background and routes on success/failure exactly
  // like a normal sign-in attempt would.
  Future<void> _migrateWithGoogle() async {
    setState(() => _isLoading = true);
    final result = await AuthMethods().migrateGoogleUserNative();
    if (!mounted) return;
    setState(() => _isLoading = false);

    if (result == 'success' || result == 'onboarding_required') {
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const AuthWrapper()),
        (route) => false,
      );
    } else if (result == 'cancelled') {
      _showSnackBarSafe('Google sign-in cancelled', isError: true);
    } else {
      _showSnackBarSafe(result, isError: true);
    }
  }

  Future<void> _continueWithGoogle() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      // NOTE: verify against your AuthMethods implementation — signup used
      // signInWithGoogleNative() while login used signInWithGoogle(). This
      // unified screen uses the native variant; if it does not surface
      // "needs_migration" for existing unmigrated accounts the way the old
      // LoginScreen's signInWithGoogle() did, route that check through
      // signInWithGoogle() instead (or have AuthMethods normalize both).
      final String result = await AuthMethods().signInWithGoogleNative();

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (result == 'success' || result == 'onboarding_required') {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AuthWrapper()),
          (route) => false,
        );
      } else if (result == 'needs_migration') {
        await _migrateWithGoogle();
      } else if (result == 'cancelled') {
        _showSnackBarSafe('Google sign-in cancelled', isError: true);
      } else {
        _showSnackBarSafe(result, isError: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnackBarSafe('Google sign-in failed: $e', isError: true);
      }
    }
  }

  Future<void> _continueWithApple() async {
    if (!mounted) return;
    setState(() => _isLoading = true);

    try {
      final String result = await AuthMethods().signInWithAppleNative();

      if (!mounted) return;
      setState(() => _isLoading = false);

      if (result == 'success' || result == 'onboarding_required') {
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AuthWrapper()),
          (route) => false,
        );
      } else if (result == 'needs_migration') {
        await _migrateWithGoogle();
      } else if (result == 'cancelled') {
        _showSnackBarSafe('Apple sign-in cancelled', isError: true);
      } else {
        _showSnackBarSafe(result, isError: true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnackBarSafe('Apple sign-in failed: $e', isError: true);
      }
    }
  }

  bool get _shouldShowAppleButton {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          _updateParticles();
          return Stack(
            children: [
              CustomPaint(
                painter: FallingNumbersPainter(
                  particles: _particles,
                  repaint: _controller,
                ),
                size: Size.infinite,
              ),
              SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: 24.0),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: MediaQuery.of(context).size.height -
                          MediaQuery.of(context).padding.top -
                          MediaQuery.of(context).padding.bottom,
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
                          Text(
                            widget.isMigration
                                ? 'Please continue to keep\nusing your account'
                                : 'Discover Your Rating',
                            style: const TextStyle(
                              color: Color(0xFFd9d9d9),
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'Montserrat',
                              height: 1.3,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 40),

                          // Google
                          ElevatedButton.icon(
                            onPressed: _isLoading ? null : _continueWithGoogle,
                            icon: Image.asset(
                              'assets/logo/google-logo.png',
                              width: 24,
                              height: 24,
                              fit: BoxFit.contain,
                            ),
                            label: _isLoading
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                          Colors.white),
                                    ),
                                  )
                                : const Text(
                                    'Continue with Google',
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

                          // Apple
                          if (_shouldShowAppleButton) ...[
                            const SizedBox(height: 16),
                            ElevatedButton.icon(
                              onPressed: _isLoading ? null : _continueWithApple,
                              icon: Image.asset(
                                'assets/logo/apple-logo.png',
                                width: 24,
                                height: 24,
                                fit: BoxFit.contain,
                                color: Colors.white,
                              ),
                              label: _isLoading
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor:
                                            AlwaysStoppedAnimation<Color>(
                                                Colors.white),
                                      ),
                                    )
                                  : const Text(
                                      'Continue with Apple',
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
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 16),
                                shape: RoundedRectangleBorder(
                                  borderRadius: BorderRadius.circular(12),
                                ),
                              ),
                            ),
                          ],

                          const SizedBox(height: 32),

                          // Terms and Privacy Policy
                          RichText(
                            textAlign: TextAlign.center,
                            text: TextSpan(
                              style: TextStyle(
                                color: Colors.grey[400],
                                fontFamily: 'Inter',
                                fontSize: 14,
                              ),
                              children: [
                                const TextSpan(
                                    text: 'By continuing, you agree to our '),
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
                                const TextSpan(text: '.'),
                              ],
                            ),
                          ),
                          const Spacer(flex: 2),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

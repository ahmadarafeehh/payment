import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/screens/login.dart';
import 'package:Ratedly/screens/signup/age_screen.dart';
import 'package:Ratedly/screens/signup/profile_setup_screen.dart';
import 'package:Ratedly/responsive/mobile_screen_layout.dart';
import 'package:Ratedly/responsive/responsive_layout.dart';
import 'package:Ratedly/services/debug_logger.dart';

// ─────────────────────────────────────────────
// Logs to Supabase ONLY on real errors.
// Abandonment / step timing is local only.
// ─────────────────────────────────────────────
Future<void> _logError({
  required String eventType,
  String? userId,
  String? errorDetails,
  String? stackTrace,
  Map<String, dynamic>? additionalData,
}) async {
  try {
    await Supabase.instance.client.from('login_logs').insert({
      'event_type': eventType,
      'firebase_uid': userId,
      'error_details': errorDetails,
      'stack_trace': stackTrace,
      'additional_data': additionalData,
    });
  } catch (_) {}
}

class OnboardingFlow extends StatefulWidget {
  final VoidCallback onComplete;
  final Function(dynamic) onError;

  const OnboardingFlow({
    Key? key,
    required this.onComplete,
    required this.onError,
  }) : super(key: key);

  @override
  State<OnboardingFlow> createState() => _OnboardingFlowState();
}

class _OnboardingFlowState extends State<OnboardingFlow>
    with WidgetsBindingObserver {
  final _supabase = Supabase.instance.client;
  final _auth = firebase_auth.FirebaseAuth.instance;

  Map<String, dynamic>? _userData;

  // No longer starts as true — we show the age screen immediately
  bool _isLoading = false;
  bool _hasRequiredFields = false;

  // Tracks whether the background check has finished
  bool _backgroundCheckDone = false;

  String? _userId;

  // Step timing — local only, never hits Supabase
  DateTime _flowStart = DateTime.now();
  String _currentStep = 'init';
  DateTime _stepStart = DateTime.now();

  void _advanceStep(String newStep) {
    final elapsed = DateTime.now().difference(_stepStart).inSeconds;
    DebugLogger.logEvent(
        'ONBOARDING_FLOW [$_userId] $_currentStep → $newStep (${elapsed}s)');
    _currentStep = newStep;
    _stepStart = DateTime.now();
  }

  int get _totalElapsed => DateTime.now().difference(_flowStart).inSeconds;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _flowStart = DateTime.now();

    // Fire the DB check in the background immediately — don't await it
    _checkUserStatusInBackground();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (!_hasRequiredFields && _userId != null) {
      DebugLogger.logEvent(
          'ONBOARDING_FLOW_DISPOSE [$_userId] at step=$_currentStep after ${_totalElapsed}s — '
          'intentional drop-off or screen replaced (NOT logged to DB)');
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !_hasRequiredFields) {
      DebugLogger.logEvent(
          'ONBOARDING_FLOW_BACKGROUNDED [$_userId] step=$_currentStep elapsed=${_totalElapsed}s '
          '— user sent app to background (NOT an error, NOT logged to DB)');
    }
    if (state == AppLifecycleState.resumed && !_hasRequiredFields) {
      DebugLogger.logEvent(
          'ONBOARDING_FLOW_RESUMED [$_userId] step=$_currentStep — user came back');
    }
  }

  /// Runs the DB check entirely in the background.
  /// The age screen is already visible while this executes.
  Future<void> _checkUserStatusInBackground() async {
    try {
      _advanceStep('resolving_user');

      final firebaseUser = _auth.currentUser;
      final supabaseSession = _supabase.auth.currentSession;

      if (firebaseUser != null) {
        _userId = firebaseUser.uid;
      } else if (supabaseSession != null) {
        _userId = supabaseSession.user.id;
      } else {
        DebugLogger.logEvent(
            'ONBOARDING_FLOW: no user found — will redirect to login');
        if (mounted) setState(() => _backgroundCheckDone = true);
        return;
      }

      DebugLogger.logEvent(
          'ONBOARDING_FLOW: background checking status for userId=$_userId');
      _advanceStep('db_fetch');

      final response = await _supabase
          .from('users')
          .select('username, dateOfBirth, gender, onboardingComplete, photoUrl')
          .eq('uid', _userId!)
          .maybeSingle();

      if (!mounted) return;

      final alreadyComplete =
          response != null && _hasCompletedOnboarding(response);

      setState(() {
        _userData = response;
        _backgroundCheckDone = true;
        _hasRequiredFields = alreadyComplete;
      });

      if (alreadyComplete) {
        DebugLogger.logEvent(
            'ONBOARDING_FLOW [$_userId]: already complete (background check) — '
            'waiting briefly before redirecting home');
        _advanceStep('completed');

        // Small delay so the age screen doesn't flash jarringly
        // before we redirect a returning user who completed onboarding
        await Future.delayed(const Duration(milliseconds: 150));

        if (mounted) widget.onComplete();
      } else {
        _advanceStep('age_screen');
        DebugLogger.logEvent(
            'ONBOARDING_FLOW [$_userId]: incomplete (background check) — '
            'staying on age screen. '
            'username=${response?['username']} dob=${response?['dateOfBirth']} gender=${response?['gender']}');
      }
    } catch (e, stack) {
      DebugLogger.logError('ONBOARDING_CHECK', e);

      // PGRST116 = no row found — expected for brand new users, NOT an error
      if (e is PostgrestException && e.code == 'PGRST116') {
        DebugLogger.logEvent(
            'ONBOARDING_FLOW [$_userId]: no user record (PGRST116) — '
            'new user, staying on age screen');
        if (mounted) {
          setState(() {
            _userData = null;
            _hasRequiredFields = false;
            _backgroundCheckDone = true;
          });
        }
        _advanceStep('age_screen_new_user');
      } else {
        // Any other DB error IS worth logging
        await _logError(
          eventType: 'ONBOARDING_STATUS_CHECK_ERROR',
          userId: _userId,
          errorDetails: e.toString(),
          stackTrace: stack.toString(),
          additionalData: {
            'step': _currentStep,
            'elapsed_seconds': _totalElapsed,
          },
        );
        // Even on error we keep the age screen visible — don't crash the user
        if (mounted) setState(() => _backgroundCheckDone = true);
        widget.onError(e);
      }
    }
  }

  bool _hasCompletedOnboarding(Map<String, dynamic> userData) {
    return userData['onboardingComplete'] == true ||
        (userData['username'] != null &&
            userData['username']!.toString().isNotEmpty &&
            userData['dateOfBirth'] != null &&
            userData['gender'] != null &&
            userData['gender']!.toString().isNotEmpty);
  }

  void _handleAgeVerificationComplete(DateTime dateOfBirth) {
    _advanceStep('profile_setup');
    DebugLogger.logEvent(
        'ONBOARDING_FLOW [$_userId]: age verified — moving to profile setup');

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (context) => ProfileSetupScreen(
          dateOfBirth: dateOfBirth,
          onComplete: () {
            _advanceStep('completed');
            DebugLogger.logEvent(
                'ONBOARDING_FLOW [$_userId]: profile setup complete — totalTime=${_totalElapsed}s');
            widget.onComplete();
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final firebaseUser = _auth.currentUser;
    final supabaseSession = _supabase.auth.currentSession;

    // No auth session at all — send to login
    if (firebaseUser == null &&
        supabaseSession == null &&
        _backgroundCheckDone) {
      DebugLogger.logEvent(
          'ONBOARDING_FLOW: build() — no auth session, redirecting to LoginScreen');
      return const LoginScreen();
    }

    // Background check confirmed onboarding is done — show home
    // (the widget.onComplete() call handles navigation, but this
    // acts as a safety net in case build fires before the callback)
    if (_hasRequiredFields) {
      return const ResponsiveLayout(
        mobileScreenLayout: MobileScreenLayout(),
      );
    }

    // Show the age screen immediately — background check runs in parallel
    return AgeVerificationScreen(
      onComplete: _handleAgeVerificationComplete,
    );
  }
}

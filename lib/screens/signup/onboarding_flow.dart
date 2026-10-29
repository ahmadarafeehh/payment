import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/screens/first_time/welcome_screen.dart';
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

  bool _isLoading = false;
  bool _hasRequiredFields = false;

  // Tracks whether the background DB check has finished
  bool _backgroundCheckDone = false;

  // NEW (flash fix): true once the LOCAL saved-progress lookup has finished.
  // Until then build() shows a blank dark scaffold instead of guessing the
  // age screen — that guess is what used to flash on resume. The lookup is a
  // local SharedPreferences read (a few ms), and it no longer waits on the
  // DB round-trip.
  bool _progressResolved = false;

  // Which step to show. Replaces the old Navigator.pushReplacement from age →
  // profile: both the "resumed on cold start" and the "just finished age
  // screen" cases now go through the same in-tree switch, so this widget
  // never touches the root navigator for step changes.
  bool _showProfileSetup = false;
  DateTime? _profileDateOfBirth;

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

  // ── Step-progress persistence ───────────────────────────────────────────
  // Keyed by the real userId, NOT DeviceSession.id, so a second account on
  // the same device never inherits another account's saved DOB.
  // Separate from ProfileSetupScreen's own `profile_setup_draft_v1_*` keys
  // (form input) — this one stores which *screen* to land on.
  static String _progressKey(String userId) => 'onboarding_progress_v1_$userId';

  Future<void> _saveProgress(String step, {DateTime? dateOfBirth}) async {
    if (_userId == null) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _progressKey(_userId!),
        jsonEncode({
          'step': step,
          'dateOfBirth': dateOfBirth?.toIso8601String(),
        }),
      );
      DebugLogger.logEvent('ONBOARDING_PROGRESS_SAVED [$_userId] step=$step');
    } catch (e) {
      // Best-effort — never let progress persistence crash onboarding.
      DebugLogger.logError('ONBOARDING_PROGRESS_SAVE', e);
    }
  }

  Future<Map<String, dynamic>?> _loadProgress(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_progressKey(userId));
      if (raw == null) return null;
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (e) {
      DebugLogger.logError('ONBOARDING_PROGRESS_LOAD', e);
      return null;
    }
  }

  Future<void> _clearProgress(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_progressKey(userId));
    } catch (_) {
      // Non-fatal — a stale leftover key just gets overwritten next time.
    }
  }
  // ─────────────────────────────────────────────────────────────────────────

  String? _resolveUserId() {
    final firebaseUser = _auth.currentUser;
    if (firebaseUser != null) return firebaseUser.uid;
    final session = _supabase.auth.currentSession;
    if (session != null) return session.user.id;
    return null;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _flowStart = DateTime.now();

    // NEW: resolve which step to show from LOCAL storage first, so the very
    // first real screen we build is already the right one.
    _resolveInitialStep();

    // DB check still runs in parallel, as before — it only decides
    // "already complete → go home" and error handling now.
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

  /// Local-only lookup of the saved step. Needs no network: the userId comes
  /// from the already-persisted auth session and the progress marker lives in
  /// SharedPreferences.
  Future<void> _resolveInitialStep() async {
    final userId = _resolveUserId();

    if (userId == null) {
      // No session. Leave _progressResolved false; the background check will
      // set _backgroundCheckDone and build() redirects to WelcomeScreen.
      return;
    }
    _userId = userId;

    final saved = await _loadProgress(userId);
    final dob = saved != null &&
            saved['step'] == 'profile_setup' &&
            saved['dateOfBirth'] != null
        ? DateTime.tryParse(saved['dateOfBirth'] as String)
        : null;

    if (!mounted) return;

    setState(() {
      if (dob != null) {
        _showProfileSetup = true;
        _profileDateOfBirth = dob;
      }
      _progressResolved = true;
    });

    if (dob != null) {
      _advanceStep('profile_setup_resumed');
      DebugLogger.logEvent(
          'ONBOARDING_FLOW [$userId]: resuming at profile_setup — '
          'saved progress found (dateOfBirth=$dob), skipping age_verification');
    } else {
      _advanceStep('age_screen');
    }
  }

  /// Runs the DB check entirely in the background.
  Future<void> _checkUserStatusInBackground() async {
    try {
      _advanceStep('resolving_user');

      final userId = _resolveUserId();
      if (userId == null) {
        DebugLogger.logEvent(
            'ONBOARDING_FLOW: no user found — will redirect to WelcomeScreen');
        if (mounted) setState(() => _backgroundCheckDone = true);
        return;
      }
      _userId = userId;

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

      if (alreadyComplete) {
        // Onboarding is done some other way (e.g. another device) — the local
        // marker is stale, clear it.
        await _clearProgress(_userId!);
      }

      if (!mounted) return;

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

        await Future.delayed(const Duration(milliseconds: 150));

        if (mounted) widget.onComplete();
      } else {
        DebugLogger.logEvent(
            'ONBOARDING_FLOW [$_userId]: incomplete (background check) — '
            'showProfileSetup=$_showProfileSetup '
            'username=${response?['username']} dob=${response?['dateOfBirth']} gender=${response?['gender']}');
      }
    } catch (e, stack) {
      DebugLogger.logError('ONBOARDING_CHECK', e);

      // PGRST116 = no row found — expected for brand new users, NOT an error
      if (e is PostgrestException && e.code == 'PGRST116') {
        DebugLogger.logEvent(
            'ONBOARDING_FLOW [$_userId]: no user record (PGRST116) — new user');
        if (mounted) {
          setState(() {
            _userData = null;
            _hasRequiredFields = false;
            _backgroundCheckDone = true;
          });
        }
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
        // Even on error we keep the current step visible — don't crash the user
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

    // Persist that this user reached profile_setup, so a relaunch resumes here.
    _saveProgress('profile_setup', dateOfBirth: dateOfBirth);

    // In-tree step switch (was Navigator.pushReplacement on the root navigator).
    if (!mounted) return;
    setState(() {
      _profileDateOfBirth = dateOfBirth;
      _showProfileSetup = true;
    });
  }

  Widget _buildProfileSetup(DateTime dateOfBirth) {
    return ProfileSetupScreen(
      dateOfBirth: dateOfBirth,
      onComplete: () {
        _advanceStep('completed');
        DebugLogger.logEvent(
            'ONBOARDING_FLOW [$_userId]: profile setup complete — totalTime=${_totalElapsed}s');
        if (_userId != null) _clearProgress(_userId!);
        widget.onComplete();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final firebaseUser = _auth.currentUser;
    final supabaseSession = _supabase.auth.currentSession;

    // No auth session at all — send to the single Google/Apple entry screen
    if (firebaseUser == null &&
        supabaseSession == null &&
        _backgroundCheckDone) {
      DebugLogger.logEvent(
          'ONBOARDING_FLOW: build() — no auth session, redirecting to WelcomeScreen');
      return const WelcomeScreen();
    }

    // Background check confirmed onboarding is done — show home
    // (safety net in case build fires before widget.onComplete() navigates)
    if (_hasRequiredFields) {
      return const ResponsiveLayout(
        mobileScreenLayout: MobileScreenLayout(),
      );
    }

    // NEW: don't guess a step before the local progress lookup finishes.
    // Same background color as the real screens, so there is no visible
    // change when the real screen appears a few ms later.
    if (!_progressResolved) {
      return const Scaffold(backgroundColor: Color(0xFF121212));
    }

    if (_showProfileSetup && _profileDateOfBirth != null) {
      return _buildProfileSetup(_profileDateOfBirth!);
    }

    return AgeVerificationScreen(
      onComplete: _handleAgeVerificationComplete,
    );
  }
}

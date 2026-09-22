import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:Ratedly/responsive/mobile_screen_layout.dart';
import 'package:Ratedly/responsive/responsive_layout.dart';
import 'package:Ratedly/screens/first_time/welcome_screen.dart';
import 'package:Ratedly/screens/signup/onboarding_flow.dart';
import 'package:Ratedly/services/country_service.dart';
import 'package:Ratedly/resources/auth_methods.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/services/debug_logger.dart';
import 'package:Ratedly/services/device_session.dart';
import 'package:Ratedly/screens/feed/feed_skeleton.dart';
import 'package:Ratedly/services/feed_cache_service.dart';
import 'package:Ratedly/services/platform_service.dart';

Future<void> _logError({
  required String eventType,
  String? supabaseUid,
  String? email,
  String? errorDetails,
  String? stackTrace,
  Map<String, dynamic>? additionalData,
}) async {
  try {
    await Supabase.instance.client.from('login_logs').insert({
      'event_type': eventType,
      'supabase_uid': supabaseUid,
      'email': email,
      'error_details': errorDetails,
      'stack_trace': stackTrace,
      'additional_data': additionalData,
    });
  } catch (_) {}
}

class _OnboardingTracker {
  final String userId;
  final DateTime sessionStart = DateTime.now();
  String currentStep = 'init';
  DateTime stepStartTime = DateTime.now();

  _OnboardingTracker(this.userId);

  void step(String stepName) {
    final elapsed = DateTime.now().difference(stepStartTime).inSeconds;
    DebugLogger.logEvent(
        'ONBOARDING_STEP [$userId] $currentStep → $stepName (${elapsed}s on previous step)');
    currentStep = stepName;
    stepStartTime = DateTime.now();
  }

  int get totalElapsedSeconds =>
      DateTime.now().difference(sessionStart).inSeconds;
}

/// Tracks what the most recently completed _initializeAuth() call actually
/// resolved, so a second caller arriving mid-flight can decide whether to
/// skip (a session was already resolved) or re-run (the first call found no
/// session, but this caller knows — because it's the signedIn event — that
/// a session now genuinely exists).
enum _InitOutcome { resolvedWithSession, resolvedNoSession }

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({Key? key}) : super(key: key);

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  final CountryService _countryService = CountryService();
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _isLoading = true;

  // --- Guarded-init state ---
  bool _initLock = false;
  _InitOutcome? _lastInitOutcome;
  // Completer that resolves when the in-flight _initializeAuth() call
  // finishes. A second caller arriving while _initLock is true awaits this
  // instead of polling, then inspects _lastInitOutcome to decide whether to
  // skip or re-run.
  Completer<void>? _initCompleter;

  // FIX-BOUNCE: Once the user has been handed off to OnboardingFlow, a
  // later signedIn event firing must NOT re-run _initializeAuth() and
  // rebuild a fresh OnboardingFlow. See original comments in git history —
  // unchanged from before this refactor.
  bool _onboardingHandedOff = false;

  // NOTE: this field name is kept only because the database's primary-key
  // column on `users` is still named `uid` for legacy schema reasons. It is
  // always populated from session.user.id (the Supabase auth id) now —
  // there is no more Firebase uid anywhere in this flow.
  String? _supabaseUid;
  String? _userEmail;
  String? _userName;
  String? _photoUrl;
  bool _onboardingComplete = false;

  _OnboardingTracker? _tracker;

  static SharedPreferences? _prefs;
  static Future<SharedPreferences> get prefsInstance async {
    _prefs ??= await SharedPreferences.getInstance();
    return _prefs!;
  }

  late final StreamSubscription<AuthState> _authSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    DebugLogger.logEvent('AUTH_WRAPPER_INIT_STARTED');

    _guardedInitializeAuth(isFromAuthEvent: false);

    _authSubscription = _supabase.auth.onAuthStateChange.listen((data) async {
      if (data.event == AuthChangeEvent.signedIn) {
        DebugLogger.logEvent('AUTH_EVENT: signedIn — triggering init');
        await _guardedInitializeAuth(isFromAuthEvent: true);
      } else if (data.event == AuthChangeEvent.tokenRefreshed) {
        DebugLogger.logEvent(
            'AUTH_EVENT: tokenRefreshed — intentionally ignored');
      } else if (data.event == AuthChangeEvent.signedOut && mounted) {
        DebugLogger.logEvent('AUTH_EVENT: signedOut — clearing state');
        setState(() {
          _supabaseUid = null;
          _isLoading = false;
          _onboardingComplete = false;
          _onboardingHandedOff = false;
        });
      }
    });
  }

  Future<void> _guardedInitializeAuth({required bool isFromAuthEvent}) async {
    if (_onboardingHandedOff && isFromAuthEvent) {
      DebugLogger.logEvent(
          'INIT_AUTH: skipped — onboarding already handed off, ignoring redundant signedIn');
      return;
    }

    if (_initLock) {
      if (!isFromAuthEvent) {
        DebugLogger.logEvent(
            'INIT_AUTH: skipped — already running (duplicate call site)');
        return;
      }

      DebugLogger.logEvent(
          'INIT_AUTH: signedIn arrived mid-flight — waiting for in-flight call to finish');
      final pending = _initCompleter?.future;
      if (pending != null) {
        await pending;
      }

      if (_lastInitOutcome == _InitOutcome.resolvedWithSession) {
        DebugLogger.logEvent(
            'INIT_AUTH: in-flight call already resolved a session — skipping duplicate signedIn');
        return;
      }

      DebugLogger.logEvent(
          'INIT_AUTH: in-flight call found no session, but signedIn confirms one exists — re-running');
    }

    _initLock = true;
    _initCompleter = Completer<void>();
    try {
      await _initializeAuth();
    } finally {
      _initLock = false;
      _initCompleter?.complete();
      _initCompleter = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _authSubscription.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused &&
        _supabaseUid != null &&
        !_onboardingComplete) {
      final userId = _supabaseUid ?? 'unknown';
      final step = _tracker?.currentStep ?? 'unknown';
      final elapsed = _tracker?.totalElapsedSeconds ?? 0;
      DebugLogger.logEvent(
          'ONBOARDING_APP_BACKGROUNDED [$userId] at step=$step after ${elapsed}s — possible abandon');
    }
    if (state == AppLifecycleState.resumed &&
        _supabaseUid != null &&
        !_onboardingComplete) {
      final userId = _supabaseUid ?? 'unknown';
      final step = _tracker?.currentStep ?? 'unknown';
      DebugLogger.logEvent(
          'ONBOARDING_APP_RESUMED [$userId] at step=$step — user came back');
    }
  }

  Future<void> _initializeAuth() async {
    final userProvider = Provider.of<UserProvider>(context, listen: false);

    final supabaseSession = _supabase.auth.currentSession;

    DebugLogger.logEvent(
        'INIT_AUTH: hasSupabase=${supabaseSession != null}');

    if (supabaseSession != null) {
      _lastInitOutcome = _InitOutcome.resolvedWithSession;
      await _handleSupabaseSession(supabaseSession, userProvider);
      return;
    }

    _lastInitOutcome = _InitOutcome.resolvedNoSession;
    DebugLogger.logEvent(
        'INIT_AUTH: no session found — showing WelcomeScreen');
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _handleSupabaseSession(
      Session session, UserProvider userProvider) async {
    String? recordSource;
    bool found = false;
    Map<String, dynamic>? userData;

    DebugLogger.logEvent(
        'HANDLE_SUPABASE_SESSION_STARTED', 'supabaseUid=${session.user.id}');

    try {
      // --- STEP 1: Find by supabase_uid (returning user) ---
      final records = await _supabase
          .from('users')
          .select()
          .eq('supabase_uid', session.user.id);

      if (records.isNotEmpty) {
        found = true;
        recordSource = 'supabase_uid';
        DebugLogger.logEvent(
            'SUPABASE_SESSION: ${records.length} record(s) found via supabase_uid=${session.user.id}');

        if (records.length > 1) {
          await _logError(
            eventType: 'DUPLICATE_USER_RECORDS',
            supabaseUid: session.user.id,
            errorDetails:
                'Found ${records.length} records for supabase_uid — deduplicating',
            additionalData: {
              'record_uids': records.map((r) => r['uid']).toList()
            },
          );

          Map<String, dynamic>? bestRecord;
          List<Map<String, dynamic>> others = [];
          for (var rec in records) {
            final hasData = rec['username'] != null &&
                rec['username'].toString().isNotEmpty &&
                rec['dateOfBirth'] != null;
            if (hasData) {
              bestRecord = rec;
            } else {
              others.add(rec);
            }
          }
          if (bestRecord == null) {
            bestRecord = records.first;
            others = records.sublist(1);
          }
          userData = bestRecord;
          for (var rec in others) {
            await _supabase.from('users').delete().eq('uid', rec['uid']);
          }
        } else {
          userData = records.first as Map<String, dynamic>;
        }
      }

      // --- STEP 2: No record found — create new user ---
      if (!found) {
        recordSource = 'none_created_new';
        DebugLogger.logEvent(
            'SUPABASE_SESSION: no record found — creating new user for supabase_uid=${session.user.id}');

        final newUser = {
          'uid': session.user.id,
          'email': session.user.email,
          'username': '',
          'bio': '',
          'photoUrl': 'default',
          'isPrivate': false,
          'onboardingComplete': false,
          'createdAt': DateTime.now().toIso8601String(),
          'dateOfBirth': null,
          'gender': null,
          'isVerified': false,
          'blockedUsers': <dynamic>[],
          'country': null,
          'migrated': true,
          'supabase_uid': session.user.id,
          'test': Random().nextBool(),
        };
        await _supabase.from('users').upsert(newUser, onConflict: 'uid');
        userData = newUser;

        try {
          final deviceId = DeviceSession.idSync ?? await DeviceSession.id;
          if (deviceId != session.user.id) {
            await _supabase
                .from('login_logs')
                .update({'supabase_uid': session.user.id})
                .eq('firebase_uid', deviceId);
            await _supabase
                .from('signup_debug_logs')
                .update({'supabase_uid': session.user.id})
                .eq('firebase_uid', deviceId);
            await _supabase
                .from('screen_time')
                .update({'uid': session.user.id})
                .eq('uid', deviceId);
            DebugLogger.logEvent('DEVICE_LOGS_LINKED_IN_AUTH_WRAPPER',
                'deviceId=$deviceId realUid=${session.user.id}');
          }
        } catch (e) {
          DebugLogger.logError('DEVICE_LOGS_LINK_IN_AUTH_WRAPPER', e);
        }
      }

      _supabaseUid = session.user.id;
      _userEmail = userData!['email'] as String? ?? session.user.email;
      _userName = userData['username'] as String?;
      _photoUrl = userData['photoUrl'] as String?;

      _tracker = _OnboardingTracker(_supabaseUid ?? 'unknown');
      _tracker!.step('provider_init');

      try {
        userProvider.initializeUser({
          'uid': userData['uid'],
          'supabase_uid': _supabaseUid,
          ...userData,
        });
      } catch (e, stack) {
        await _logError(
          eventType: 'USER_PROVIDER_INIT_ERROR',
          supabaseUid: _supabaseUid,
          email: _userEmail,
          errorDetails: e.toString(),
          stackTrace: stack.toString(),
        );
        rethrow;
      }

      _tracker!.step('onboarding_check');
      final hasCompletedOnboarding =
          await _checkOnboardingStatus(_supabaseUid!);

      if (!hasCompletedOnboarding) {
        _onboardingHandedOff = true;
      }

      DebugLogger.logEvent(
          'REACHED_SETSTATE_CHECK [${_supabaseUid}] mounted=$mounted hasCompletedOnboarding=$hasCompletedOnboarding');

      if (mounted) {
        setState(() {
          if (!_onboardingComplete) {
            _onboardingComplete = hasCompletedOnboarding;
          }
          _isLoading = false;
        });
        DebugLogger.logEvent(
            'LOADING_COMPLETE [${_supabaseUid}] isLoading=false onboardingComplete=$_onboardingComplete');
      } else {
        DebugLogger.logEvent(
            'LOADING_SKIPPED_UNMOUNTED [${_supabaseUid}] — widget was disposed before setState could run');
      }

      if (!hasCompletedOnboarding) {
        _tracker!.step('onboarding_screen_shown');
        DebugLogger.logEvent(
            'ONBOARDING: user ${_supabaseUid} sent to onboarding (recordSource=$recordSource)');
      } else {
        _tracker!.step('home_screen');
        DebugLogger.logEvent(
            'ONBOARDING: user ${_supabaseUid} onboarding complete — going home');
      }

      _updateAuthCache(hasCompletedOnboarding);
      _runBackgroundTasks(_supabaseUid!);
    } catch (e, stack) {
      await _logError(
        eventType: 'ERROR_SUPABASE_SESSION_HANDLING',
        supabaseUid: session.user.id,
        email: session.user.email,
        errorDetails: e.toString(),
        stackTrace: stack.toString(),
      );
      DebugLogger.logError('SUPABASE_SESSION_HANDLING', e);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<bool> _checkOnboardingStatus(String uid) async {
    try {
      final response = await _supabase
          .from('users')
          .select('username, dateOfBirth, gender, onboardingComplete')
          .eq('supabase_uid', uid)
          .maybeSingle();

      if (response == null) {
        DebugLogger.logEvent('CHECK_ONBOARDING: no record for uid=$uid');
        return false;
      }

      final data = response as Map<String, dynamic>;
      final complete = data['onboardingComplete'] == true ||
          (data['dateOfBirth'] != null &&
              data['username'] != null &&
              data['username'].toString().isNotEmpty &&
              data['gender'] != null &&
              data['gender'].toString().isNotEmpty);

      DebugLogger.logEvent('CHECK_ONBOARDING: uid=$uid complete=$complete '
          'username=${data['username']} dob=${data['dateOfBirth']} gender=${data['gender']}');
      return complete;
    } catch (e, stack) {
      await _logError(
        eventType: 'CHECK_ONBOARDING_STATUS_ERROR',
        supabaseUid: uid,
        errorDetails: e.toString(),
        stackTrace: stack.toString(),
      );
      DebugLogger.logError('CHECK_ONBOARDING_STATUS', e);
      return false;
    }
  }

  void _runBackgroundTasks(String uid) {
    PlatformService.saveOnce(uid);
    PlatformService.saveNotificationStatus(uid);

    Future.delayed(const Duration(seconds: 3), () {
      _countryService.checkAndBackfillCountryForExistingUsers();
    });
    Future.delayed(const Duration(seconds: 5), () {
      _countryService.checkAndUpdateCountryIfNeeded();
    });
  }

  Future<void> _updateAuthCache(bool onboardingComplete) async {
    try {
      if (_supabaseUid == null) return;
      final prefs = await prefsInstance;
      await prefs.setString(
        'auth_cache_v4_$_supabaseUid',
        jsonEncode({
          'onboardingComplete': onboardingComplete,
          'lastUpdated': DateTime.now().millisecondsSinceEpoch,
          'userId': _supabaseUid,
        }),
      );
      DebugLogger.logEvent(
          'AUTH_CACHE: updated for $_supabaseUid onboardingComplete=$onboardingComplete');
    } catch (e) {
      DebugLogger.logError('UPDATE_AUTH_CACHE', e);
    }
  }

  void _handleOnboardingComplete() {
    final elapsed = _tracker?.totalElapsedSeconds ?? 0;
    DebugLogger.logEvent(
        'ONBOARDING_COMPLETE: uid=${_supabaseUid} totalTime=${elapsed}s');
    _tracker?.step('completed');
    _onboardingHandedOff = false;
    if (mounted) setState(() => _onboardingComplete = true);
    _updateAuthCache(true);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _buildLoadingScreen();

    final bool hasUser = _supabaseUid != null;

    if (hasUser && _onboardingComplete) {
      return const ResponsiveLayout(mobileScreenLayout: MobileScreenLayout());
    }

    if (hasUser) {
      return OnboardingFlow(
        key: ValueKey(_supabaseUid),
        onComplete: _handleOnboardingComplete,
        onError: (error) async {
          await _logError(
            eventType: 'ONBOARDING_FLOW_CRASH',
            supabaseUid: _supabaseUid,
            errorDetails: error.toString(),
            additionalData: {
              'step': _tracker?.currentStep,
              'elapsed_seconds': _tracker?.totalElapsedSeconds,
            },
          );
          DebugLogger.logError('ONBOARDING_FLOW_ERROR', error);
        },
      );
    }

    return const WelcomeScreen();
  }

  Widget _buildLoadingScreen() {
    final hasPersistedUser =
        FeedCacheService.getLastUserIdSync()?.isNotEmpty == true;

    DebugLogger.logEvent(
        'LOADING_SCREEN_SHOWN supabaseUid=$_supabaseUid hasPersistedUser=$hasPersistedUser');

    if (hasPersistedUser) {
      return const FeedSkeleton(isDark: true);
    }

    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset('assets/logo/22.png', width: 100, height: 100),
            const SizedBox(height: 20),
            const CircularProgressIndicator(
              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ],
        ),
      ),
    );
  }
}

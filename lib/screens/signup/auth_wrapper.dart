import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:Ratedly/responsive/mobile_screen_layout.dart';
import 'package:Ratedly/responsive/responsive_layout.dart';
import 'package:Ratedly/screens/first_time/get_started_page.dart';
import 'package:Ratedly/screens/signup/onboarding_flow.dart';
import 'package:Ratedly/services/country_service.dart';
import 'package:Ratedly/resources/auth_methods.dart';
import 'package:Ratedly/screens/login.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/services/debug_logger.dart';
import 'package:Ratedly/services/device_session.dart';
import 'package:Ratedly/screens/feed/feed_skeleton.dart';
import 'package:Ratedly/services/feed_cache_service.dart';
import 'package:Ratedly/services/platform_service.dart';

Future<void> _logError({
  required String eventType,
  String? firebaseUid,
  String? supabaseUid,
  String? email,
  String? errorDetails,
  String? stackTrace,
  Map<String, dynamic>? additionalData,
}) async {
  try {
    await Supabase.instance.client.from('login_logs').insert({
      'event_type': eventType,
      'firebase_uid': firebaseUid,
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
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final CountryService _countryService = CountryService();
  final AuthMethods _authMethods = AuthMethods();
  final SupabaseClient _supabase = Supabase.instance.client;

  bool _isLoading = true;
  bool _usingCachedData = false;
  bool _needsMigration = false;
  bool _checkingMigration = false;

  // --- Guarded-init state ---
  bool _initLock = false;
  _InitOutcome? _lastInitOutcome;
  // Completer that resolves when the in-flight _initializeAuth() call
  // finishes. A second caller arriving while _initLock is true awaits this
  // instead of polling, then inspects _lastInitOutcome to decide whether to
  // skip or re-run.
  Completer<void>? _initCompleter;

  // FIX-BOUNCE: Once the user has been handed off to OnboardingFlow, a
  // later signedIn event firing (confirmed in production logs happening
  // repeatedly, ~30-90s apart, on some Android sessions even though
  // AuthWrapper never remounts and _authSubscription is never cancelled)
  // must NOT re-run _initializeAuth() and rebuild a fresh OnboardingFlow.
  // Doing so was the confirmed root cause of users being silently bounced
  // from profile_setup back to age_verification, losing in-progress state
  // — ONBOARDING_FLOW_DISPOSE logs showed the old OnboardingFlow (with
  // step=profile_setup) being torn down and replaced by a brand new one
  // every time this fired. The session is already resolved once onboarding
  // has started; there is nothing left to (re)do.
  bool _onboardingHandedOff = false;

  String? _firebaseUid;
  String? _supabaseUid;
  String? _userEmail;
  String? _userName;
  String? _photoUrl;
  bool _isMigrated = false;
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

    // NEW: crash-proof marker — AuthWrapper itself started initializing.
    DebugLogger.logEvent('AUTH_WRAPPER_INIT_STARTED');

    // FIX: previously this called _initializeAuth() directly, unguarded,
    // while the onAuthStateChange listener below guarded ITS OWN call with
    // _initLock. That meant a fresh signup — where initState() runs
    // immediately AND the auth listener fires `signedIn` moments later once
    // the sign-in actually completes — could trigger _handleSupabaseSession()
    // TWICE, concurrently. Confirmed in production logs: two
    // HANDLE_SUPABASE_SESSION_STARTED events 13ms apart for the same user,
    // duplicate device-log linking, duplicate onboarding checks, and two
    // separate OnboardingFlow/AgeVerificationScreen builds. Routing both
    // call sites through the same guarded helper closes that race.
    //
    // isFromAuthEvent: false — this call site has no independent knowledge
    // that a session exists; it's just the app starting up.
    _guardedInitializeAuth(isFromAuthEvent: false);

    _authSubscription = _supabase.auth.onAuthStateChange.listen((data) async {
      if (data.event == AuthChangeEvent.signedIn) {
        DebugLogger.logEvent('AUTH_EVENT: signedIn — triggering init');
        // isFromAuthEvent: true — this call site DOES know a session now
        // genuinely exists (Supabase just told us so). If it arrives while
        // initState()'s call is still in flight, it must not be silently
        // dropped in case that first call resolves "no session" and would
        // otherwise leave the user permanently stuck on GetStartedPage.
        await _guardedInitializeAuth(isFromAuthEvent: true);
      } else if (data.event == AuthChangeEvent.tokenRefreshed) {
        DebugLogger.logEvent(
            'AUTH_EVENT: tokenRefreshed — intentionally ignored');
      } else if (data.event == AuthChangeEvent.signedOut && mounted) {
        DebugLogger.logEvent('AUTH_EVENT: signedOut — clearing state');
        setState(() {
          _firebaseUid = null;
          _supabaseUid = null;
          _isLoading = false;
          _onboardingComplete = false;
          _onboardingHandedOff = false; // FIX-BOUNCE: allow a real future sign-in to proceed normally
        });
      }
    });
  }

  /// Serializes every call to _initializeAuth() behind a single lock,
  /// regardless of which call site triggers it (initState()'s direct call,
  /// or the onAuthStateChange listener's signedIn event).
  ///
  /// Outcome-aware behavior:
  /// - If no call is in flight, this runs _initializeAuth() normally.
  /// - If a call IS in flight and this caller has no special knowledge
  ///   (isFromAuthEvent=false), it skips immediately — same as before.
  /// - If a call IS in flight and this caller is the signedIn listener
  ///   (isFromAuthEvent=true), it waits for the in-flight call to finish,
  ///   then checks what that call resolved:
  ///     - resolvedWithSession  -> the work is already done; skip.
  ///     - resolvedNoSession    -> the first call ran before the session
  ///       existed and bailed out early. Since we now KNOW a session
  ///       exists, re-run _initializeAuth() for real instead of leaving
  ///       the user stuck.
  ///
  /// The lock is always released in `finally`, including on normal
  /// completion, so this can never deadlock — a later, genuinely new
  /// signedIn event (e.g. after a sign-out/sign-in cycle) always gets a
  /// fresh attempt once the current call exits.
  Future<void> _guardedInitializeAuth({required bool isFromAuthEvent}) async {
    // FIX-BOUNCE: if onboarding is already underway, a redundant signedIn
    // event must not re-run _initializeAuth() and rebuild OnboardingFlow
    // from scratch. This is the primary fix — see field doc comment above.
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
      // Fall through and run it for real below.
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
        (_firebaseUid != null || _supabaseUid != null) &&
        !_onboardingComplete) {
      final userId = _firebaseUid ?? _supabaseUid ?? 'unknown';
      final step = _tracker?.currentStep ?? 'unknown';
      final elapsed = _tracker?.totalElapsedSeconds ?? 0;
      DebugLogger.logEvent(
          'ONBOARDING_APP_BACKGROUNDED [$userId] at step=$step after ${elapsed}s — possible abandon');
    }
    // NEW: also capture resume, so we can tell "backgrounded and came back"
    // apart from "backgrounded and never returned".
    if (state == AppLifecycleState.resumed &&
        (_firebaseUid != null || _supabaseUid != null) &&
        !_onboardingComplete) {
      final userId = _firebaseUid ?? _supabaseUid ?? 'unknown';
      final step = _tracker?.currentStep ?? 'unknown';
      DebugLogger.logEvent(
          'ONBOARDING_APP_RESUMED [$userId] at step=$step — user came back');
    }
  }

  Future<void> _initializeAuth() async {
    final userProvider = Provider.of<UserProvider>(context, listen: false);

    final supabaseSession = _supabase.auth.currentSession;
    final firebaseUser = _auth.currentUser;

    DebugLogger.logEvent(
        'INIT_AUTH: hasSupabase=${supabaseSession != null} hasFirebase=${firebaseUser != null}');

    if (supabaseSession != null) {
      _lastInitOutcome = _InitOutcome.resolvedWithSession;
      await _handleSupabaseSession(supabaseSession, userProvider);
      return;
    }

    if (firebaseUser != null) {
      _lastInitOutcome = _InitOutcome.resolvedWithSession;
      await _handleFirebaseUser(firebaseUser, userProvider);
      return;
    }

    _lastInitOutcome = _InitOutcome.resolvedNoSession;
    DebugLogger.logEvent(
        'INIT_AUTH: no session found — showing GetStartedPage');
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _handleSupabaseSession(
      Session session, UserProvider userProvider) async {
    String? recordSource;
    bool found = false;
    Map<String, dynamic>? userData;
    final firebaseUser = _auth.currentUser;

    // NEW: crash-proof marker at the very start of this function — the
    // single most important line we added. This is the function our 5
    // stuck users entered but never finished; now we know for certain
    // whether they got this far.
    DebugLogger.logEvent(
        'HANDLE_SUPABASE_SESSION_STARTED', 'supabaseUid=${session.user.id}');

    try {
      // --- STEP 1: Find by Firebase UID (migration path) ---
      if (firebaseUser != null) {
        userData = await _supabase
            .from('users')
            .select()
            .eq('uid', firebaseUser.uid)
            .maybeSingle();

        if (userData != null) {
          found = true;
          recordSource = 'firebase_uid';
          DebugLogger.logEvent(
              'SUPABASE_SESSION: record found via firebase_uid=${firebaseUser.uid}');

          await _supabase.from('users').update({
            'supabase_uid': session.user.id,
            'migrated': true,
          }).eq('uid', firebaseUser.uid);

          await _supabase
              .from('users')
              .delete()
              .eq('supabase_uid', session.user.id)
              .neq('uid', firebaseUser.uid);

          userData = await _supabase
              .from('users')
              .select()
              .eq('uid', firebaseUser.uid)
              .maybeSingle();
        }
      }

      // --- STEP 2: Find by email (unmigrated user) ---
      if (!found && session.user.email != null) {
        final userByEmail = await _supabase
            .from('users')
            .select()
            .eq('email', session.user.email!)
            .eq('migrated', false)
            .maybeSingle();

        if (userByEmail != null) {
          found = true;
          recordSource = 'email_migration';
          userData = userByEmail;
          DebugLogger.logEvent(
              'SUPABASE_SESSION: record found via email migration email=${session.user.email}');

          await _supabase.from('users').update({
            'supabase_uid': session.user.id,
            'migrated': true,
          }).eq('uid', userData!['uid']);

          await _supabase
              .from('users')
              .delete()
              .eq('supabase_uid', session.user.id)
              .neq('uid', userData!['uid']);

          userData = await _supabase
              .from('users')
              .select()
              .eq('uid', userData!['uid'])
              .maybeSingle();
        }
      }

      // --- STEP 3: Find by supabase_uid (returning Supabase user) ---
      if (!found) {
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
      }

      // --- STEP 4: No record found — create new user ---
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

        // NEW: link this device's anonymous pre-signup logs (GetStartedPage,
        // SignupScreen, etc.) to the real uid, now that it exists.
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
      _firebaseUid = userData!['uid'] as String?;
      _userEmail = userData['email'] as String? ?? session.user.email;
      _userName = userData['username'] as String?;
      _photoUrl = userData['photoUrl'] as String?;
      _isMigrated = userData['migrated'] == true;

      _tracker = _OnboardingTracker(_firebaseUid ?? _supabaseUid ?? 'unknown');
      _tracker!.step('provider_init');

      try {
        userProvider.initializeUser({
          'uid': _firebaseUid,
          'supabase_uid': _supabaseUid,
          'migrated': _isMigrated,
          ...userData,
        });
      } catch (e, stack) {
        await _logError(
          eventType: 'USER_PROVIDER_INIT_ERROR',
          firebaseUid: _firebaseUid,
          supabaseUid: _supabaseUid,
          email: _userEmail,
          errorDetails: e.toString(),
          stackTrace: stack.toString(),
        );
        rethrow;
      }

      _tracker!.step('onboarding_check');
      final hasCompletedOnboarding =
          await _checkOnboardingStatus(_firebaseUid!);

      // NEW: crash-proof marker right before the mounted check, which is
      // exactly the line most likely to silently skip if the widget has
      // been disposed while we were awaiting the DB call above.
      DebugLogger.logEvent(
          'REACHED_SETSTATE_CHECK [${_firebaseUid}] mounted=$mounted hasCompletedOnboarding=$hasCompletedOnboarding');

      if (mounted) {
        setState(() {
          if (!_onboardingComplete) {
            _onboardingComplete = hasCompletedOnboarding;
          }
          _isLoading = false;
        });
        // NEW: confirms the loading screen has actually been dismissed.
        DebugLogger.logEvent(
            'LOADING_COMPLETE [${_firebaseUid}] isLoading=false onboardingComplete=$_onboardingComplete');
      } else {
        // NEW: this is the single most important new log line in the whole
        // fix. If this ever fires, it proves definitively that a user got
        // stuck because the widget was disposed mid-flow — not because of
        // a thrown error, a network failure, or abandonment.
        DebugLogger.logEvent(
            'LOADING_SKIPPED_UNMOUNTED [${_firebaseUid}] — widget was disposed before setState could run');
      }

      if (!hasCompletedOnboarding) {
        _tracker!.step('onboarding_screen_shown');
        DebugLogger.logEvent(
            'ONBOARDING: user ${_firebaseUid} sent to onboarding (recordSource=$recordSource)');
      } else {
        _tracker!.step('home_screen');
        DebugLogger.logEvent(
            'ONBOARDING: user ${_firebaseUid} onboarding complete — going home');
      }

      _updateAuthCache(hasCompletedOnboarding);
      _runBackgroundTasks(_firebaseUid!);
    } catch (e, stack) {
      await _logError(
        eventType: 'ERROR_SUPABASE_SESSION_HANDLING',
        firebaseUid: firebaseUser?.uid,
        supabaseUid: session.user.id,
        email: session.user.email,
        errorDetails: e.toString(),
        stackTrace: stack.toString(),
      );
      DebugLogger.logError('SUPABASE_SESSION_HANDLING', e);
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _handleFirebaseUser(
      firebase_auth.User firebaseUser, UserProvider userProvider) async {
    _firebaseUid = firebaseUser.uid;
    _userEmail = firebaseUser.email;
    _userName = firebaseUser.displayName;
    _photoUrl = firebaseUser.photoURL;
    _isMigrated = false;

    _tracker = _OnboardingTracker(_firebaseUid!);
    _tracker!.step('cache_check');

    final cachedData = await _loadCachedAuthDataInstantly();

    if (cachedData != null && mounted) {
      DebugLogger.logEvent(
          'FIREBASE_USER: using cached onboarding state for ${_firebaseUid}');
      setState(() {
        _onboardingComplete = cachedData['onboardingComplete'] ?? false;
        _usingCachedData = true;
        _isLoading = false;
      });

      await _initializeUserProvider(userProvider);
      _verifyOnboardingInBackground();
    } else {
      DebugLogger.logEvent(
          'FIREBASE_USER: no cache — fetching from DB for ${_firebaseUid}');
      if (mounted) setState(() => _isLoading = false);
      await _checkOnboardingFromDatabase(userProvider);
    }

    _checkMigrationInBackground();
    _runBackgroundTasks(_firebaseUid!);
  }

  Future<void> _initializeUserProvider(UserProvider userProvider) async {
    try {
      final userData = await _supabase
          .from('users')
          .select()
          .eq('uid', _firebaseUid!)
          .maybeSingle();

      if (userData != null) {
        userProvider.initializeUser(userData as Map<String, dynamic>);
      } else {
        DebugLogger.logEvent(
            'INIT_USER_PROVIDER: no record found for uid=$_firebaseUid (may be new user)');
      }
    } catch (e, stack) {
      await _logError(
        eventType: 'INIT_USER_PROVIDER_ERROR',
        firebaseUid: _firebaseUid,
        errorDetails: e.toString(),
        stackTrace: stack.toString(),
      );
      DebugLogger.logError('INIT_USER_PROVIDER', e);
    }
  }

  Future<Map<String, dynamic>?> _loadCachedAuthDataInstantly() async {
    try {
      if (_firebaseUid == null) return null;
      final prefs = await prefsInstance;
      final cachedData = prefs.getString('auth_cache_v4_$_firebaseUid');
      if (cachedData != null) {
        final data = jsonDecode(cachedData);
        final lastUpdated = data['lastUpdated'] ?? 0;
        final cacheAge = DateTime.now().millisecondsSinceEpoch - lastUpdated;
        final cacheAgeHours = (cacheAge / 3600000).toStringAsFixed(1);
        if (cacheAge < 24 * 60 * 60 * 1000) {
          DebugLogger.logEvent(
              'AUTH_CACHE: hit for $_firebaseUid (age=${cacheAgeHours}h)');
          return {
            'onboardingComplete': data['onboardingComplete'] ?? false,
            'lastUpdated': lastUpdated,
          };
        } else {
          DebugLogger.logEvent(
              'AUTH_CACHE: expired for $_firebaseUid (age=${cacheAgeHours}h) — fetching fresh');
        }
      } else {
        DebugLogger.logEvent(
            'AUTH_CACHE: miss for $_firebaseUid — no cache found');
      }
    } catch (e) {
      DebugLogger.logError('LOAD_CACHED_AUTH', e);
    }
    return null;
  }

  Future<void> _verifyOnboardingInBackground() async {
    if (_firebaseUid == null || !_usingCachedData) return;
    try {
      final hasCompletedOnboarding =
          await _checkOnboardingStatus(_firebaseUid!);

      if (hasCompletedOnboarding != _onboardingComplete) {
        DebugLogger.logEvent(
            'ONBOARDING_BG_VERIFY: cache mismatch for $_firebaseUid — cache=$_onboardingComplete DB=$hasCompletedOnboarding');
        if (mounted) {
          setState(() {
            if (!_onboardingComplete && hasCompletedOnboarding) {
              _onboardingComplete = true;
            }
          });
          _updateAuthCache(_onboardingComplete);
        }
      } else {
        DebugLogger.logEvent(
            'ONBOARDING_BG_VERIFY: cache matches DB for $_firebaseUid — onboardingComplete=$hasCompletedOnboarding');
      }
    } catch (e, stack) {
      await _logError(
        eventType: 'BG_ONBOARDING_VERIFY_ERROR',
        firebaseUid: _firebaseUid,
        errorDetails: e.toString(),
        stackTrace: stack.toString(),
      );
      DebugLogger.logError('VERIFY_ONBOARDING_BG', e);
    }
  }

  Future<bool> _checkOnboardingStatus(String uid) async {
    try {
      final response = await _supabase
          .from('users')
          .select('username, dateOfBirth, gender, onboardingComplete')
          .eq('uid', uid)
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
        firebaseUid: uid,
        errorDetails: e.toString(),
        stackTrace: stack.toString(),
      );
      DebugLogger.logError('CHECK_ONBOARDING_STATUS', e);
      return false;
    }
  }

  Future<void> _checkOnboardingFromDatabase(UserProvider userProvider) async {
    if (_firebaseUid == null) return;
    try {
      _tracker?.step('db_fetch');
      await _initializeUserProvider(userProvider);
      final hasCompletedOnboarding =
          await _checkOnboardingStatus(_firebaseUid!);
      if (mounted) {
        setState(() {
          if (!_onboardingComplete) {
            _onboardingComplete = hasCompletedOnboarding;
          }
        });
      }
      _updateAuthCache(hasCompletedOnboarding);
    } catch (e, stack) {
      await _logError(
        eventType: 'CHECK_ONBOARDING_DB_ERROR',
        firebaseUid: _firebaseUid,
        errorDetails: e.toString(),
        stackTrace: stack.toString(),
      );
      DebugLogger.logError('CHECK_ONBOARDING_DB', e);
    }
  }

  Future<void> _checkMigrationInBackground() async {
    if (_firebaseUid == null || _checkingMigration) return;
    _checkingMigration = true;
    try {
      final migrationStatus =
          await _authMethods.getCurrentUserMigrationStatus();
      final needsMigration = migrationStatus['needs_migration'] == true;
      DebugLogger.logEvent(
          'MIGRATION_CHECK: uid=$_firebaseUid needsMigration=$needsMigration reason=${migrationStatus['reason']}');

      if (mounted) {
        setState(() => _needsMigration = needsMigration);
        if (_needsMigration) {
          await Future.delayed(const Duration(milliseconds: 500));
          if (mounted) _showMigrationScreen();
        }
      }
    } catch (e, stack) {
      await _logError(
        eventType: 'MIGRATION_CHECK_ERROR',
        firebaseUid: _firebaseUid,
        errorDetails: e.toString(),
        stackTrace: stack.toString(),
      );
      DebugLogger.logError('CHECK_MIGRATION', e);
    } finally {
      _checkingMigration = false;
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
      if (_firebaseUid == null) return;
      final prefs = await prefsInstance;
      await prefs.setString(
        'auth_cache_v4_$_firebaseUid',
        jsonEncode({
          'onboardingComplete': onboardingComplete,
          'lastUpdated': DateTime.now().millisecondsSinceEpoch,
          'userId': _firebaseUid,
        }),
      );
      DebugLogger.logEvent(
          'AUTH_CACHE: updated for $_firebaseUid onboardingComplete=$onboardingComplete');
    } catch (e) {
      DebugLogger.logError('UPDATE_AUTH_CACHE', e);
    }
  }

  void _showMigrationScreen() {
    if (_firebaseUid == null) return;
    DebugLogger.logEvent(
        'MIGRATION: redirecting uid=$_firebaseUid to migration screen');
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => LoginScreen(
          migrationEmail: _userEmail ?? '',
          migrationUid: _firebaseUid!,
        ),
      ),
    );
  }

  void _handleOnboardingComplete() {
    final elapsed = _tracker?.totalElapsedSeconds ?? 0;
    DebugLogger.logEvent(
        'ONBOARDING_COMPLETE: uid=${_firebaseUid ?? _supabaseUid} totalTime=${elapsed}s');
    _tracker?.step('completed');
    _onboardingHandedOff = false; // FIX-BOUNCE: onboarding is done, not "in progress" anymore
    if (mounted) setState(() => _onboardingComplete = true);
    _updateAuthCache(true);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return _buildLoadingScreen();

    final bool hasUser = _firebaseUid != null || _supabaseUid != null;

    if (hasUser && _onboardingComplete && !_needsMigration) {
      return const ResponsiveLayout(mobileScreenLayout: MobileScreenLayout());
    }

    if (hasUser) {
      _onboardingHandedOff = true; // FIX-BOUNCE: mark onboarding as in-progress
      return OnboardingFlow(
        // FIX-BOUNCE: stable key so Flutter treats this as the SAME widget
        // instance across any AuthWrapper rebuild, instead of tearing down
        // and recreating OnboardingFlow (and losing its internal state /
        // the pushed ProfileSetupScreen route) every time. This is a
        // defensive second layer — the _onboardingHandedOff guard above is
        // the primary fix, since it stops the wasteful rebuild from
        // happening in the first place.
        key: ValueKey(_supabaseUid ?? _firebaseUid),
        onComplete: _handleOnboardingComplete,
        onError: (error) async {
          await _logError(
            eventType: 'ONBOARDING_FLOW_CRASH',
            firebaseUid: _firebaseUid,
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

    return const GetStartedPage();
  }

  Widget _buildLoadingScreen() {
    final hasPersistedUser =
        FeedCacheService.getLastUserIdSync()?.isNotEmpty == true;

    // NEW: this screen previously had zero logging at all. This is the
    // exact screen our 5 stuck users were frozen on, with no way to tell.
    // Fire-and-forget is intentional here — build() must stay synchronous.
    DebugLogger.logEvent(
        'LOADING_SCREEN_SHOWN firebaseUid=$_firebaseUid supabaseUid=$_supabaseUid hasPersistedUser=$hasPersistedUser');

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

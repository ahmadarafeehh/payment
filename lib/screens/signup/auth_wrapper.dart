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
import 'package:Ratedly/screens/feed/feed_skeleton.dart';
import 'package:Ratedly/services/feed_cache_service.dart';

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
  bool _initLock = false;

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
    _initializeAuth();

    _authSubscription = _supabase.auth.onAuthStateChange.listen((data) async {
      if (data.event == AuthChangeEvent.signedIn) {
        DebugLogger.logEvent('AUTH_EVENT: signedIn — triggering init');
        if (!_initLock) {
          _initLock = true;
          await _initializeAuth();
          _initLock = false;
        } else {
          DebugLogger.logEvent(
              'AUTH_EVENT: signedIn ignored — init already running');
        }
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
        });
      }
    });
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
          'ONBOARDING_APP_BACKGROUNDED [$userId] at step=$step after ${elapsed}s — possible abandon (not logged to DB)');
    }
  }

  Future<void> _initializeAuth() async {
    final userProvider = Provider.of<UserProvider>(context, listen: false);

    final supabaseSession = _supabase.auth.currentSession;
    final firebaseUser = _auth.currentUser;

    DebugLogger.logEvent(
        'INIT_AUTH: hasSupabase=${supabaseSession != null} hasFirebase=${firebaseUser != null}');

    if (supabaseSession != null) {
      await _handleSupabaseSession(supabaseSession, userProvider);
      return;
    }

    if (firebaseUser != null) {
      await _handleFirebaseUser(firebaseUser, userProvider);
      return;
    }

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

      if (mounted) {
        setState(() {
          if (!_onboardingComplete) {
            _onboardingComplete = hasCompletedOnboarding;
          }
          _isLoading = false;
        });
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
      _runCountryChecks(_firebaseUid!);
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
    _runCountryChecks(_firebaseUid!);
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

  void _runCountryChecks(String uid) {
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
      return OnboardingFlow(
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

  /// Returns [FeedSkeleton] for returning signed-in users (persisted userId
  /// exists in cache), and the logo spinner for first-time / logged-out users.
  Widget _buildLoadingScreen() {
    final hasPersistedUser =
        FeedCacheService.getLastUserIdSync()?.isNotEmpty == true;

    if (hasPersistedUser) {
      // A returning user is signing back in — show the feed skeleton so the
      // experience is consistent with what _AppBootstrap shows during init.
      return const FeedSkeleton(isDark: true);
    }

    // No persisted user — first-time open or logged-out state.
    // Show the branded logo screen while auth resolves.
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

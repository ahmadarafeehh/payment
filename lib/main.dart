import 'dart:async';
import 'dart:io';                              // ← needed for Platform in ad error logger
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:Ratedly/providers/user_provider.dart';
import 'package:Ratedly/utils/theme_provider.dart';
import 'package:Ratedly/resources/profile_firestore_methods.dart';
import 'package:Ratedly/screens/signup/auth_wrapper.dart';
import 'package:Ratedly/utils/colors.dart';
import 'package:Ratedly/services/analytics_service.dart';
import 'package:Ratedly/services/notification_service.dart';
import 'package:Ratedly/services/notification_navigation_handler.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:Ratedly/services/country_service.dart';
import 'package:Ratedly/screens/feed/feed_skeleton.dart';
import 'package:Ratedly/services/feed_cache_service.dart';
import 'package:Ratedly/services/iap_service.dart';

const bool useDebugHome = false;

const String supabaseUrl = 'https://tbiemcbqjjjsgumnjlqq.supabase.co';
const String supabaseAnonKey =
    'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InRiaWVtY2Jxampqc2d1bW5qbHFxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTQzMTQ2NjQsImV4cCI6MjA2OTg5MDY2NH0.JAgFU3fDBGAlMFuHQDqiu35GFe-QYMJfoaIc3mI26yM';

enum _InitState { loading, ready, error }

final _appInitState = ValueNotifier<_InitState>(_InitState.loading);

// Hold any AdMob init error until Supabase is available, then log it.
String? _admobInitError;

// ─── AD ERROR LOGGER ────────────────────────────────────────────────────────
Future<void> _logAdError({
  required String errorType,
  String? userId,
  String? errorMessage,
  Map<String, dynamic>? extraInfo,
}) async {
  try {
    await Supabase.instance.client.from('ads_errors').insert({
      'user_id': userId,
      'platform': kIsWeb ? 'web' : (Platform.isAndroid ? 'android' : 'ios'),
      'error_type': errorType,
      'error_message': errorMessage,
      'extra_info': extraInfo,
    });
  } catch (_) {
    // Logging must never crash the app.
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await FeedCacheService.warmUserIdCache();

  if (!kIsWeb) {
    try {
      await MobileAds.instance.initialize();
    } catch (e) {
      // Save the error – we'll log it once Supabase is ready.
      _admobInitError = e.toString();
    }
  }

  await IAPService.init();

  runApp(
    ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: _AppBootstrap(stateNotifier: _appInitState),
    ),
  );

  try {
    await Future.wait([
      _initializeFirebase(),
      _initializeSupabase(),
    ]);

    // Now we can log the saved AdMob init error (if any).
    if (_admobInitError != null) {
      await _logAdError(
        errorType: 'ads_init_failed',
        errorMessage: _admobInitError,
        extraInfo: {'stage': 'MobileAds.instance.initialize'},
      );
      _admobInitError = null;
    }

    NotificationService.registerWarmStartListener();
    await NotificationService.handleColdStart();

    _appInitState.value = _InitState.ready;
  } catch (_) {
    _appInitState.value = _InitState.error;
  }

  _initializeNonEssentialServicesInBackground();
}

Future<void> _initializeFirebase() async {
  if (kIsWeb) {
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: "AIzaSyAFpbPiK6u8KMIfob0pu44ca8YLGYKJHDk",
        authDomain: "rateapp-3b78e.firebaseapp.com",
        projectId: "rateapp-3b78e",
        storageBucket: "rateapp-3b78e.appspot.com",
        messagingSenderId: "411393947451",
        appId: "1:411393947451:web:62e5c1b57a3c7a66da691e",
        measurementId: "G-JSXVSH5PB8",
      ),
    );
  } else {
    await Firebase.initializeApp();
  }
}

Future<void> _initializeSupabase() async {
  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseAnonKey,
    authOptions: const FlutterAuthClientOptions(autoRefreshToken: true),
  );
}

Future<void> _initializeNonEssentialServicesInBackground() async {
  try {
    await _initializeOtherServicesInBackground();
  } catch (_) {}
}

Future<void> _initializeOtherServicesInBackground() async {
  try {
    await Future.microtask(() async {
      if (kIsWeb) {
        await FirebaseAuth.instance.setPersistence(Persistence.LOCAL);
      }
    });
    unawaited(Future.microtask(() async => await AnalyticsService.init()));
    unawaited(Future.microtask(() async => await NotificationService().init()));
  } catch (_) {}
}

// ─── APP BOOTSTRAP ───────────────────────────────────────────────────────────

class _AppBootstrap extends StatelessWidget {
  final ValueNotifier<_InitState> stateNotifier;
  const _AppBootstrap({required this.stateNotifier});

  static final _lightTheme = ThemeData.light().copyWith(
    scaffoldBackgroundColor: Colors.grey[100],
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: Colors.white,
      selectedItemColor: primaryColor,
      unselectedItemColor: Colors.grey[600],
      selectedLabelStyle: const TextStyle(color: primaryColor),
      unselectedLabelStyle: TextStyle(color: Colors.grey[600]),
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
  );

  static final _darkTheme = ThemeData.dark().copyWith(
    scaffoldBackgroundColor: mobileBackgroundColor,
    bottomNavigationBarTheme: BottomNavigationBarThemeData(
      backgroundColor: mobileBackgroundColor,
      selectedItemColor: primaryColor,
      unselectedItemColor: Colors.grey[600],
      selectedLabelStyle: const TextStyle(color: primaryColor),
      unselectedLabelStyle: TextStyle(color: Colors.grey[600]),
      type: BottomNavigationBarType.fixed,
      elevation: 0,
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeProvider>(
      builder: (context, themeProvider, _) {
        return ValueListenableBuilder<_InitState>(
          valueListenable: stateNotifier,
          builder: (context, state, _) {
            if (state == _InitState.error) {
              return const MaterialApp(
                debugShowCheckedModeBanner: false,
                home: ErrorApp(),
              );
            }

            if (state == _InitState.loading) {
              final isDark = themeProvider.themeMode == ThemeMode.dark ||
                  (themeProvider.themeMode == ThemeMode.system &&
                      WidgetsBinding
                              .instance.platformDispatcher.platformBrightness ==
                          Brightness.dark);
              return MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: _lightTheme,
                darkTheme: _darkTheme,
                themeMode: themeProvider.themeMode,
                home: FeedSkeleton(isDark: isDark),
              );
            }

            return _OptimizedMyApp(
              lightTheme: _lightTheme,
              darkTheme: _darkTheme,
            );
          },
        );
      },
    );
  }
}

// ─── MAIN APP ────────────────────────────────────────────────────────────────

class _OptimizedMyApp extends StatefulWidget {
  final ThemeData lightTheme;
  final ThemeData darkTheme;
  const _OptimizedMyApp({required this.lightTheme, required this.darkTheme});

  @override
  State<_OptimizedMyApp> createState() => _OptimizedMyAppState();
}

// FIX: added WidgetsBindingObserver so didChangeAppLifecycleState fires.
// Without this, warm-start taps stored _pendingData but executePendingNavigation()
// was never called because the widget was already built (initState doesn't re-run).
class _OptimizedMyAppState extends State<_OptimizedMyApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Handles cold start: app was terminated, now freshly built.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      NotificationNavigationHandler.executePendingNavigation();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // FIX: This is the core of the warm-start fix.
  // When the app resumes from background (warm start), the widget tree is
  // already built so initState never fires again. The listener in
  // registerWarmStartListener() correctly stored _pendingData, but nothing
  // was ever consuming it. Now, as soon as the app comes to the foreground,
  // we attempt to execute any pending navigation.
  // executePendingNavigation() is idempotent — it clears _pendingData
  // immediately, so repeated resumes without a notification tap are no-ops.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      NotificationNavigationHandler.executePendingNavigation();
    }
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => UserProvider()),
        Provider(create: (_) => SupabaseProfileMethods()),
        Provider(create: (_) => NotificationService()),
        Provider(create: (_) => CountryService()),
      ],
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          return MaterialApp(
            debugShowCheckedModeBanner: false,
            title: 'Ratedly',
            theme: widget.lightTheme,
            darkTheme: widget.darkTheme,
            themeMode: themeProvider.themeMode,
            navigatorKey: notificationNavigatorKey,
            home: useDebugHome ? const DebugHome() : const AuthWrapper(),
            navigatorObservers: [CountryCheckObserver()],
            builder: (context, child) {
              return Stack(
                children: [
                  child!,
                  ValueListenableBuilder<bool>(
                    valueListenable:
                        NotificationNavigationHandler.isNavigatingToPost,
                    builder: (ctx, navigating, _) {
                      if (!navigating) return const SizedBox.shrink();
                      return ColoredBox(
                        color: Theme.of(ctx).scaffoldBackgroundColor,
                        child: const SizedBox.expand(),
                      );
                    },
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

// ─── NAVIGATOR OBSERVER ──────────────────────────────────────────────────────

class CountryCheckObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _checkCountryInBackground();
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _checkCountryInBackground();
    super.didPop(route, previousRoute);
  }

  void _checkCountryInBackground() {
    Future.delayed(const Duration(seconds: 1), () {
      try {
        CountryService().checkAndUpdateCountryIfNeeded();
      } catch (_) {}
    });
  }
}

// ─── ERROR SCREEN ─────────────────────────────────────────────────────────────

class ErrorApp extends StatelessWidget {
  const ErrorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: const [
              Icon(Icons.error_outline, color: Colors.red, size: 64),
              SizedBox(height: 20),
              Text('App initialization failed',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              SizedBox(height: 10),
              Padding(
                padding: EdgeInsets.symmetric(horizontal: 32.0),
                child: Text(
                  'Please check your internet connection and try again.',
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── ORIENTATION WRAPPER ──────────────────────────────────────────────────────

class OrientationPersistentWrapper extends StatefulWidget {
  const OrientationPersistentWrapper({super.key});

  @override
  State<OrientationPersistentWrapper> createState() =>
      _OrientationPersistentWrapperState();
}

class _OrientationPersistentWrapperState
    extends State<OrientationPersistentWrapper> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _setSystemUIOverlayStyle();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _setSystemUIOverlayStyle();
    super.didChangeMetrics();
  }

  void _setSystemUIOverlayStyle() {
    final themeProvider = Provider.of<ThemeProvider>(context, listen: false);
    final isDarkMode = themeProvider.themeMode == ThemeMode.dark;
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: isDarkMode ? Brightness.light : Brightness.dark,
      systemNavigationBarColor:
          isDarkMode ? const Color(0xFF121212) : Colors.white,
      systemNavigationBarIconBrightness:
          isDarkMode ? Brightness.light : Brightness.dark,
    ));
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _setSystemUIOverlayStyle());
    return const AuthWrapper();
  }
}

// ─── DEBUG HOME ───────────────────────────────────────────────────────────────

class DebugHome extends StatefulWidget {
  const DebugHome({Key? key}) : super(key: key);

  @override
  State<DebugHome> createState() => _DebugHomeState();
}

class _DebugHomeState extends State<DebugHome> {
  final SupabaseClient _supabase = Supabase.instance.client;
  String _msg = 'starting...';

  @override
  void initState() {
    super.initState();
    _checkSupabase();
  }

  Future<void> _checkSupabase() async {
    try {
      final firebaseUser = FirebaseAuth.instance.currentUser;
      setState(() => _msg = 'Firebase UID: ${firebaseUser?.uid ?? "null"}');
      final resp =
          await _supabase.from('posts').select('postId').limit(1).maybeSingle();
      setState(
          () => _msg = 'Supabase query result: ${resp?.toString() ?? "null"}');
    } catch (e) {
      setState(() => _msg = 'error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Debug Supabase + Firebase'),
        backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Text(
            _msg,
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16),
          ),
        ),
      ),
    );
  }
}

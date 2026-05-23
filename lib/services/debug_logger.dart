import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/foundation.dart';
import 'dart:io';

class DebugLogger {
  static final SupabaseClient _supabase = Supabase.instance.client;
  static bool _enabled = true;

  // Get device info for logging
  static String get _platformInfo {
    if (kIsWeb) return 'web';
    if (Platform.isIOS) return 'ios';
    if (Platform.isAndroid) return 'android';
    return 'unknown';
  }

  // Main logging method - FIXED sessionData type
  static Future<void> log({
    required String eventName,
    String? message,
    String? errorDetails,
    String? redirectUrl,
    String? oauthProvider,
    Map<String, dynamic>? sessionData,
    String? firebaseUid,
    String? supabaseUid,
  }) async {
    if (!_enabled) return;

    try {
      // Collect device info
      final userAgent = 'iOS Physical Device';

      // Insert log into Supabase
      await _supabase.from('signup_debug_logs').insert({
        'event_name': eventName,
        'message': message,
        'error_details': errorDetails,
        'user_agent': userAgent,
        'device_info': 'iPhone (TestFlight)',
        'redirect_url': redirectUrl,
        'oauth_provider': oauthProvider,
        'session_data': sessionData,
        'firebase_uid': firebaseUid,
        'supabase_uid': supabaseUid,
        'platform': _platformInfo,
      });

      // Also print to console for immediate feedback
      print('🔍 DEBUG LOG: $eventName - $message');
      if (errorDetails != null) print('❌ ERROR: $errorDetails');
    } catch (e) {
      // If logging fails, at least print to console
      print('⚠️ Failed to log to Supabase: $e');
      print('📝 Event: $eventName - $message');
    }
  }

  // Quick logging methods - FIXED logSession parameter
  static Future<void> logEvent(String event, [String? details]) async {
    await log(eventName: event, message: details);
  }

  static Future<void> logError(String event, dynamic error) async {
    await log(
      eventName: 'ERROR_$event',
      errorDetails: error.toString(),
      message: 'Error occurred',
    );
  }

  static Future<void> logOAuthStart(String provider, String redirectUrl) async {
    await log(
      eventName: 'OAUTH_STARTED',
      oauthProvider: provider,
      redirectUrl: redirectUrl,
      message: 'Starting OAuth for $provider',
    );
  }

  static Future<void> logSession(Map<String, dynamic>? sessionData) async {
    await log(
      eventName: 'SESSION_INFO',
      sessionData: sessionData,
      message: 'Session data captured',
    );
  }

  // Enable/disable logging
  static void enable() => _enabled = true;
  static void disable() => _enabled = false;
}

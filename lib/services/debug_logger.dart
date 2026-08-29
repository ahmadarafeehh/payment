import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Crash-proof debug/event logger. Writes fire-and-forget rows to the
/// `signup_debug_logs` table so onboarding/auth flow can be reconstructed
/// after the fact — including cases where the app crashed or froze and
/// never got a chance to log a clean "exit" event.
///
/// Every method here must NEVER throw and NEVER block the caller on the
/// network write completing (logging must not be able to crash or slow
/// down the app it's trying to observe). All writes are best-effort.
class DebugLogger {
  DebugLogger._();

  static const String _table = 'signup_debug_logs';

  // Matches deviceId=<id>, supabaseUid=<id>, uid=<id>, userId=<id> etc. so
  // that whichever identifier callers embedded in their free-form message
  // string also gets pulled into a proper 'firebase_uid' column. This is
  // what AuthMethods._linkDeviceLogsToUid()'s
  // `.eq('firebase_uid', deviceId)` update actually matches against —
  // without this, that link-back would silently match zero rows.
  static final RegExp _keyValueIdPattern = RegExp(
    r'(?:deviceId|supabaseUid|firebaseUid|uid|userId)=([^\s]+)',
  );
  // Catches the `[$userId]` bracket convention used by step-tracker logs
  // (e.g. 'ONBOARDING_STEP [abc-123] init → age_screen').
  static final RegExp _bracketIdPattern = RegExp(r'^\[([^\]]+)\]');

  static String? _extractId(String? text) {
    if (text == null) return null;
    final kv = _keyValueIdPattern.firstMatch(text);
    if (kv != null) return kv.group(1);
    final bracket = _bracketIdPattern.firstMatch(text.trim());
    return bracket?.group(1);
  }

  /// Fire-and-forget insert. Never awaited by callers, never throws.
  static void _insert(Map<String, dynamic> row) {
    // Intentionally not awaited — callers treat every DebugLogger method as
    // synchronous/fire-and-forget so it can be dropped into initState(),
    // dispose(), and build() without making those methods async.
    Future(() async {
      try {
        // Some call sites (e.g. logEvent('ONBOARDING_STEP [$userId] ...'))
        // pass everything as a single positional arg, landing the id in
        // event_type rather than message — check both.
        final extractedId = _extractId(row['message'] as String?) ??
            _extractId(row['event_type'] as String?);

        final enriched = {
          ...row,
          // Only fill firebase_uid from the message if the caller didn't
          // already pass one explicitly.
          if (row['firebase_uid'] == null && extractedId != null)
            'firebase_uid': extractedId,
          'logged_at': DateTime.now().toIso8601String(),
          'platform': defaultTargetPlatform.name,
        };
        await Supabase.instance.client.from(_table).insert(enriched);
      } catch (_) {
        // Logging must never crash the app or surface an error of its own.
      }
    });
  }

  /// General-purpose event log. `detail` is optional free-form context
  /// (e.g. 'age_verification deviceId=abc123'). Covers call sites that pass
  /// either just an event name, or an event name plus a detail string.
  static void logEvent(String eventName, [String? detail]) {
    _insert({
      'event_type': eventName,
      'message': detail,
    });
  }

  /// Logs a caught error/exception with its associated event/context name.
  /// `error` is typically an exception object; its toString() is stored.
  static void logError(String eventName, Object error, [StackTrace? stackTrace]) {
    _insert({
      'event_type': '${eventName}_ERROR',
      'error_details': error.toString(),
      'stack_trace': stackTrace?.toString(),
    });
  }

  /// Fully flexible named-parameter log, used where callers want to attach
  /// error details and/or a message under a specific event name.
  static void log({
    required String eventName,
    String? message,
    String? errorDetails,
    String? stackTrace,
  }) {
    _insert({
      'event_type': eventName,
      'message': message,
      'error_details': errorDetails,
      'stack_trace': stackTrace,
    });
  }

  /// Logs a Flutter framework error (from FlutterError.onError). Captures
  /// the exception, stack, and library/context so framework-level crashes
  /// (widget build errors, render errors, etc.) are traceable.
  static void logFlutterError(FlutterErrorDetails details) {
    _insert({
      'event_type': 'FLUTTER_CRASH',
      'error_details': details.exceptionAsString(),
      'stack_trace': details.stack?.toString(),
      'message': details.context?.toString(),
    });
  }

  /// Logs an uncaught async/platform error (from
  /// PlatformDispatcher.instance.onError). Covers errors outside the
  /// Flutter widget lifecycle — e.g. uncaught exceptions in async code.
  static void logUncaughtError(Object error, StackTrace stack) {
    _insert({
      'event_type': 'UNCAUGHT_ERROR',
      'error_details': error.toString(),
      'stack_trace': stack.toString(),
    });
  }
}

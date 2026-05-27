import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class PlatformService {
  static const _prefKey = 'platform_saved_v1';

  /// Detects the current platform as a simple string.
  static String detectPlatform() {
    if (kIsWeb) return 'web';
    if (Platform.isAndroid) return 'android';
    if (Platform.isIOS) return 'ios';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isWindows) return 'windows';
    if (Platform.isLinux) return 'linux';
    return 'unknown';
  }

  /// Saves the platform to the DB exactly once per device install.
  ///
  /// - Checks SharedPreferences first — if already saved for this [uid],
  ///   returns immediately with zero DB calls.
  /// - If not yet saved, writes to Supabase and marks the pref so it
  ///   never runs again.
  /// - Designed to be called unawaited (fire-and-forget) so it never
  ///   blocks the UI or auth flow.
  static Future<void> saveOnce(String uid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final savedKey = '${_prefKey}_$uid';

      // Gate: already saved on this device — do nothing.
      if (prefs.getBool(savedKey) == true) return;

      final platform = detectPlatform();

      await Supabase.instance.client
          .from('users')
          .update({'platform': platform})
          .eq('uid', uid);

      // Mark as saved locally so we never touch the DB again.
      await prefs.setBool(savedKey, true);
    } catch (_) {
      // Silent — this is non-essential metadata; never let it affect the user.
    }
  }
}

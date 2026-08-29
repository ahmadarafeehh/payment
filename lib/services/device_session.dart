import 'dart:math';
import 'package:shared_preferences/shared_preferences.dart';

/// Provides a stable, persistent per-install device identifier used to tag
/// pre-signup analytics/debug logs (screen views, signup funnel events)
/// before a real Firebase/Supabase uid exists. Once an account is created,
/// callers use this id to retroactively link those earlier log rows to the
/// real uid (see AuthMethods._linkDeviceLogsToUid / AuthWrapper's inline
/// equivalent).
///
/// Usage contract (matches every call site in the app):
/// - `DeviceSession.warm()` must be awaited once, early in `main()`, before
///   `runApp()`. This loads (or creates) the id and caches it in memory so
///   `idSync` is available synchronously afterward.
/// - `DeviceSession.id` is the async getter — always resolves to a valid,
///   non-null id. Safe to call even if `warm()` hasn't run yet (it will
///   warm on demand), used in places that can `await` (e.g. postFrameCallback).
/// - `DeviceSession.idSync` is the sync getter — returns `null` if `warm()`
///   hasn't completed yet. Used in places that cannot `await`, such as
///   `dispose()`. Callers consistently fall back to `'anonymous'` if null.
class DeviceSession {
  DeviceSession._();

  static const String _prefsKey = 'device_session_id_v1';

  static String? _cachedId;
  static Future<String>? _warmupFuture;

  /// Synchronous access to the cached id. Returns null until [warm] (or a
  /// prior call to [id]) has completed at least once.
  static String? get idSync => _cachedId;

  /// Async access to the id. Always resolves — if warming hasn't happened
  /// yet, this triggers and awaits it.
  static Future<String> get id async {
    if (_cachedId != null) return _cachedId!;
    return warm();
  }

  /// Loads the persisted device id from SharedPreferences, generating and
  /// saving a new one on first run. Idempotent and safe to call multiple
  /// times or concurrently — subsequent calls reuse the same in-flight
  /// future rather than racing separate reads/writes.
  static Future<String> warm() {
    if (_cachedId != null) {
      return Future.value(_cachedId);
    }
    // Reuse an in-flight warmup instead of starting a second one if called
    // concurrently (e.g. main() and an early screen both call it).
    return _warmupFuture ??= _loadOrCreate();
  }

  static Future<String> _loadOrCreate() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? existing = prefs.getString(_prefsKey);

      if (existing == null || existing.isEmpty) {
        existing = _generateId();
        await prefs.setString(_prefsKey, existing);
      }

      _cachedId = existing;
      return existing;
    } catch (_) {
      // SharedPreferences failed (extremely rare) — fall back to a
      // per-session (non-persistent) id rather than throwing, since every
      // call site awaits this directly with no error handling.
      final fallback = _generateId();
      _cachedId = fallback;
      return fallback;
    } finally {
      // Allow a future retry if this attempt failed to persist, by clearing
      // the in-flight future once resolved either way.
      _warmupFuture = null;
    }
  }

  static String _generateId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    // Format as a UUIDv4-like string for readability in logs/DB rows.
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) =>
        bytes.sublist(start, end).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}

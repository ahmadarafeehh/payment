import 'dart:async';
import 'package:country_detector/country_detector.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;

class CountryService {
  static const String _lastCheckKey = 'last_country_check_';
  static const String _countryUpdateEnabledKey = 'country_update_enabled';
  static const String _countryBackfilledKey = 'country_backfilled_';

  static const int _checkIntervalDays = 3;
  static const int _millisecondsInDay = 24 * 60 * 60 * 1000;

  static CountryService? _instance;
  factory CountryService() {
    _instance ??= CountryService._internal();
    return _instance!;
  }

  CountryService._internal();

  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;
  final SupabaseClient _supabase = Supabase.instance.client;
  final CountryDetector _detector = CountryDetector();
  SharedPreferences? _prefs;

  Future<void> _initPrefs() async {
    if (_prefs == null) {
      _prefs = await SharedPreferences.getInstance();
    }
  }

  Future<void> checkAndUpdateCountryIfNeeded() async {
    try {
      await _initPrefs();

      final user = _auth.currentUser;
      if (user == null) {
        return;
      }

      final isEnabled = _prefs!.getBool(_countryUpdateEnabledKey) ?? true;
      if (!isEnabled) {
        return;
      }

      final userId = user.uid;
      final lastCheckKey = '$_lastCheckKey$userId';
      final lastCheckTime = _prefs!.getInt(lastCheckKey) ?? 0;
      final currentTime = DateTime.now().millisecondsSinceEpoch;

      final daysSinceLastCheck =
          (currentTime - lastCheckTime) / _millisecondsInDay;

      if (daysSinceLastCheck >= _checkIntervalDays) {
        await _updateCountryForUser(userId);
        await _prefs!.setInt(lastCheckKey, currentTime);
      }
    } catch (e) {}
  }

  Future<void> forceUpdateCountry() async {
    try {
      await _initPrefs();

      final user = _auth.currentUser;
      if (user == null) return;

      final userId = user.uid;
      await _updateCountryForUser(userId);

      final lastCheckKey = '$_lastCheckKey$userId';
      await _prefs!.setInt(lastCheckKey, DateTime.now().millisecondsSinceEpoch);
    } catch (e) {}
  }

  Future<void> setupCountryTimer(String userId) async {
    try {
      await _initPrefs();

      final lastCheckKey = '$_lastCheckKey$userId';
      await _prefs!.setInt(lastCheckKey, DateTime.now().millisecondsSinceEpoch);
      await _prefs!.setBool(_countryUpdateEnabledKey, true);
    } catch (e) {}
  }

  Future<void> setCountryForUser(String userId) async {
    try {
      final String? countryCode = await _detectCurrentCountry();

      if (countryCode != null) {
        await _supabase
            .from('users')
            .update({'country': countryCode}).eq('uid', userId);

        await setupCountryTimer(userId);

        final backfilledKey = '$_countryBackfilledKey$userId';
        await _prefs!.setBool(backfilledKey, true);
      }
    } catch (e) {}
  }

  Future<void> checkAndBackfillCountryForExistingUsers() async {
    try {
      await _initPrefs();

      final user = _auth.currentUser;
      if (user == null) return;

      final userId = user.uid;

      final backfilledKey = '$_countryBackfilledKey$userId';
      final alreadyBackfilled = _prefs!.getBool(backfilledKey) ?? false;

      if (alreadyBackfilled) {
        return;
      }

      final userData = await _supabase
          .from('users')
          .select('country, username, onboardingComplete')
          .eq('uid', userId)
          .maybeSingle();

      if (userData == null) {
        return;
      }

      final String? currentCountry = userData['country'] as String?;
      final bool hasUsername = userData['username'] != null &&
          userData['username'].toString().isNotEmpty;
      final bool onboardingComplete = userData['onboardingComplete'] == true;

      final bool needsBackfill =
          (onboardingComplete || hasUsername) && currentCountry == null;

      if (needsBackfill) {
        await setCountryForUser(userId);
      } else if (currentCountry != null) {
        await setupCountryTimer(userId);
        await _prefs!.setBool(backfilledKey, true);
      }
    } catch (e) {}
  }

  Future<Duration> getTimeUntilNextCheck() async {
    try {
      await _initPrefs();

      final user = _auth.currentUser;
      if (user == null) return Duration.zero;

      final lastCheckKey = '$_lastCheckKey${user.uid}';
      final lastCheckTime = _prefs!.getInt(lastCheckKey) ?? 0;
      final nextCheckTime =
          lastCheckTime + (_checkIntervalDays * _millisecondsInDay);
      final currentTime = DateTime.now().millisecondsSinceEpoch;

      if (currentTime >= nextCheckTime) {
        return Duration.zero;
      } else {
        return Duration(milliseconds: nextCheckTime - currentTime);
      }
    } catch (e) {
      return Duration.zero;
    }
  }

  Future<void> setCountryUpdatesEnabled(bool enabled) async {
    try {
      await _initPrefs();
      await _prefs!.setBool(_countryUpdateEnabledKey, enabled);
    } catch (e) {}
  }

  Future<bool> areCountryUpdatesEnabled() async {
    try {
      await _initPrefs();
      return _prefs!.getBool(_countryUpdateEnabledKey) ?? true;
    } catch (e) {
      return true;
    }
  }

  Future<void> resetCheckTimer() async {
    try {
      await _initPrefs();

      final user = _auth.currentUser;
      if (user == null) return;

      final lastCheckKey = '$_lastCheckKey${user.uid}';
      await _prefs!.remove(lastCheckKey);
    } catch (e) {}
  }

  Future<String?> getCurrentUserCountry() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return null;

      final userData = await _supabase
          .from('users')
          .select('country')
          .eq('uid', user.uid)
          .maybeSingle();

      return userData?['country'] as String?;
    } catch (e) {
      return null;
    }
  }

  Future<void> _updateCountryForUser(String userId) async {
    try {
      final String? newCountryCode = await _detectCurrentCountry();

      if (newCountryCode == null) {
        return;
      }

      final currentData = await _supabase
          .from('users')
          .select('country')
          .eq('uid', userId)
          .maybeSingle();

      final String? currentCountry = currentData?['country'] as String?;

      if (currentCountry == null || currentCountry != newCountryCode) {
        await _supabase
            .from('users')
            .update({'country': newCountryCode}).eq('uid', userId);
      }
    } catch (e) {}
  }

  Future<String?> _detectCurrentCountry() async {
    try {
      final countryCode = await _detector.isoCountryCode();

      if (countryCode != null &&
          countryCode.isNotEmpty &&
          countryCode != "--") {
        return countryCode;
      }

      final allCodes = await _detector.detectAll();
      final sources = [
        allCodes.sim,
        allCodes.network,
        allCodes.locale,
      ];

      for (final code in sources) {
        if (code != null && code.isNotEmpty && code != "--") {
          return code;
        }
      }

      return null;
    } catch (e) {
      return null;
    }
  }

  Future<DateTime?> getLastCheckTime() async {
    try {
      await _initPrefs();

      final user = _auth.currentUser;
      if (user == null) return null;

      final lastCheckKey = '$_lastCheckKey${user.uid}';
      final lastCheckTime = _prefs!.getInt(lastCheckKey) ?? 0;

      if (lastCheckTime == 0) return null;
      return DateTime.fromMillisecondsSinceEpoch(lastCheckTime);
    } catch (e) {
      return null;
    }
  }
}

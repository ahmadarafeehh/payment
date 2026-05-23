import 'dart:convert';
import 'package:flutter/widgets.dart';
import 'package:supabase_flutter/supabase_flutter.dart' hide User;
import 'package:Ratedly/models/user.dart';
import 'package:Ratedly/resources/auth_methods.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;

class UserProvider with ChangeNotifier {
  AppUser? _user;
  String? _firebaseUid;
  String? _supabaseUid;
  bool _isMigrated = false;
  final AuthMethods _authMethods = AuthMethods();
  final firebase_auth.FirebaseAuth _firebaseAuth =
      firebase_auth.FirebaseAuth.instance;
  final SupabaseClient _supabase = Supabase.instance.client;

  AppUser? get user => _user;
  String? get firebaseUid => _firebaseUid;
  String? get supabaseUid => _supabaseUid;
  bool get isMigrated => _isMigrated;

  // ===========================================================================
  // LOGGING HELPER
  // ===========================================================================
  Future<void> _logEvent({
    required String eventType,
    String? errorDetails,
    StackTrace? stack,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      await _supabase.from('login_logs').insert({
        'event_type': eventType,
        'firebase_uid': _firebaseUid,
        'supabase_uid': _supabaseUid,
        'error_details': errorDetails,
        'stack_trace': stack?.toString(),
        'additional_data': additionalData,
      });
    } catch (_) {}
  }

  // ===========================================================================
  // SAFE DATA SANITIZER
  // ===========================================================================
  Map<String, dynamic> _sanitizeUserData(Map<String, dynamic> raw) {
    final data = Map<String, dynamic>.from(raw);

    if (data.containsKey('blockedUsers')) {
      final val = data['blockedUsers'];
      if (val == null) {
        data['blockedUsers'] = <dynamic>[];
      } else if (val is List) {
        data['blockedUsers'] = val;
      } else if (val is String) {
        String cleaned = val.trim();
        while (cleaned.startsWith('"') && cleaned.endsWith('"')) {
          try {
            final decoded = jsonDecode(cleaned);
            if (decoded is String) {
              cleaned = decoded.trim();
            } else {
              data['blockedUsers'] = decoded;
              cleaned = '';
              break;
            }
          } catch (_) {
            cleaned = cleaned.substring(1, cleaned.length - 1);
          }
        }
        if (cleaned.isNotEmpty) {
          try {
            final decoded = jsonDecode(cleaned);
            data['blockedUsers'] = decoded is List ? decoded : <dynamic>[];
          } catch (_) {
            data['blockedUsers'] = <dynamic>[];
          }
        }
      } else {
        data['blockedUsers'] = <dynamic>[];
      }
    } else {
      data['blockedUsers'] = <dynamic>[];
    }

    return data;
  }

  // ===========================================================================
  // USER INITIALIZATION
  // ===========================================================================
  void initializeUser(Map<String, dynamic> userData) {
    try {
      _firebaseUid = userData['uid'] as String?;
      _supabaseUid = userData['supabase_uid'] as String?;
      _isMigrated = userData['migrated'] == true;

      final Map<String, dynamic> appUserData =
          Map<String, dynamic>.from(userData);
      appUserData.remove('supabase_uid');
      appUserData.remove('migrated');

      final sanitized = _sanitizeUserData(appUserData);
      _user = AppUser.fromMap(sanitized);
      notifyListeners();

      _logEvent(
        eventType: 'PROVIDER_INIT_SUCCESS',
        additionalData: {
          'uid': _firebaseUid,
          'supabase_uid': _supabaseUid,
          'is_pure_supabase_user': _firebaseUid == _supabaseUid,
          'username': sanitized['username'],
          'onboardingComplete': sanitized['onboardingComplete'],
        },
      );
    } catch (e, stack) {
      _logEvent(
        eventType: 'PROVIDER_INIT_ERROR',
        errorDetails: e.toString(),
        stack: stack,
        additionalData: {
          'raw_uid': userData['uid'],
          'raw_supabase_uid': userData['supabase_uid'],
          'raw_blockedUsers': userData['blockedUsers'].toString(),
        },
      );
      try {
        final fallback = _sanitizeUserData(userData);
        fallback.remove('supabase_uid');
        fallback.remove('migrated');
        fallback['blockedUsers'] = <dynamic>[];
        _user = AppUser.fromMap(fallback);
        notifyListeners();
      } catch (e2, stack2) {
        _logEvent(
          eventType: 'PROVIDER_INIT_FALLBACK_ERROR',
          errorDetails: e2.toString(),
          stack: stack2,
        );
      }
    }
  }

  void setUser(AppUser user, {String? supabaseUid, bool migrated = false}) {
    try {
      _user = user;
      _firebaseUid = user.uid;
      _supabaseUid = supabaseUid;
      _isMigrated = migrated;
      notifyListeners();
    } catch (e, stack) {
      _logEvent(
          eventType: 'PROVIDER_SET_USER_ERROR',
          errorDetails: e.toString(),
          stack: stack);
    }
  }

  void setUserFromCompleteData(Map<String, dynamic> userData) {
    try {
      _firebaseUid = userData['uid'] as String?;
      _supabaseUid = userData['supabase_uid'] as String?;
      _isMigrated = userData['migrated'] == true;

      final Map<String, dynamic> appUserData =
          Map<String, dynamic>.from(userData);
      appUserData.remove('supabase_uid');
      appUserData.remove('migrated');

      final sanitized = _sanitizeUserData(appUserData);
      _user = AppUser.fromMap(sanitized);
      notifyListeners();
    } catch (e, stack) {
      _logEvent(
          eventType: 'PROVIDER_SET_COMPLETE_ERROR',
          errorDetails: e.toString(),
          stack: stack);
    }
  }

  // ===========================================================================
  // REFRESH USER
  // ===========================================================================
  Future<void> refreshUser() async {
    try {
      final firebase_auth.User? firebaseUser = _firebaseAuth.currentUser;

      if (firebaseUser == null) {
        final supabaseUser = _supabase.auth.currentUser;
        if (supabaseUser != null) {
          await _refreshFromSupabase(supabaseUser.id);
          return;
        }

        _clearUserState();
        return;
      }

      final Map<String, dynamic>? userData =
          await _getUserDataByFirebaseUid(firebaseUser.uid);

      if (userData != null) {
        setUserFromCompleteData(userData);
        await _loadRelationships(firebaseUser.uid);
      } else {
        _clearUserState();
      }
    } catch (e, stack) {
      await _logEvent(
          eventType: 'PROVIDER_REFRESH_ERROR',
          errorDetails: e.toString(),
          stack: stack);
      _clearUserState();
    }
  }

  // ===========================================================================
  // HELPERS
  // ===========================================================================
  Future<void> _loadRelationships(String uid) async {
    try {
      final results = await Future.wait([
        _authMethods.getUserFollowers(uid),
        _authMethods.getUserFollowing(uid),
        _authMethods.getFollowRequests(uid),
      ]);

      if (_user != null) {
        _user = _user!.withRelationships(
          followers: results[0] as List<String>,
          following: results[1] as List<String>,
          followRequests: results[2] as List<String>,
        );
        notifyListeners();
      }
    } catch (e, stack) {
      await _logEvent(
          eventType: 'PROVIDER_LOAD_RELATIONSHIPS_ERROR',
          errorDetails: e.toString(),
          stack: stack,
          additionalData: {'uid': uid});
    }
  }

  Future<Map<String, dynamic>?> _getUserDataByFirebaseUid(
      String firebaseUid) async {
    try {
      final response = await _supabase
          .from('users')
          .select()
          .eq('uid', firebaseUid)
          .limit(1);
      if (response.isNotEmpty) return response[0] as Map<String, dynamic>;
    } catch (e, stack) {
      await _logEvent(
          eventType: 'PROVIDER_GET_BY_FIREBASE_UID_ERROR',
          errorDetails: e.toString(),
          stack: stack,
          additionalData: {'firebaseUid': firebaseUid});
    }
    return null;
  }

  Future<void> _refreshFromSupabase(String supabaseUid) async {
    try {
      final userData = await _getUserDataBySupabaseUid(supabaseUid);
      if (userData != null) {
        setUserFromCompleteData(userData);
        final dbUid = userData['uid'] as String? ?? supabaseUid;
        await _loadRelationships(dbUid);
        await _logEvent(
          eventType: 'PROVIDER_REFRESH_SUPABASE_SUCCESS',
          additionalData: {
            'supabase_uid': supabaseUid,
            'db_uid': dbUid,
            'is_pure_supabase_user': dbUid == supabaseUid,
          },
        );
      } else {
        await _logEvent(
          eventType: 'PROVIDER_REFRESH_SUPABASE_NO_RECORD',
          errorDetails: 'No user data found for supabaseUid $supabaseUid',
        );
        _clearUserState();
      }
    } catch (e, stack) {
      await _logEvent(
          eventType: 'PROVIDER_REFRESH_FROM_SUPABASE_ERROR',
          errorDetails: e.toString(),
          stack: stack,
          additionalData: {'supabaseUid': supabaseUid});
    }
  }

  Future<Map<String, dynamic>?> _getUserDataBySupabaseUid(
      String supabaseUid) async {
    try {
      final response = await _supabase
          .from('users')
          .select()
          .eq('supabase_uid', supabaseUid)
          .limit(1);
      if (response.isNotEmpty) return response[0] as Map<String, dynamic>;
    } catch (e, stack) {
      await _logEvent(
          eventType: 'PROVIDER_GET_BY_SUPABASE_UID_ERROR',
          errorDetails: e.toString(),
          stack: stack,
          additionalData: {'supabaseUid': supabaseUid});
    }
    return null;
  }

  void _clearUserState() {
    _user = null;
    _firebaseUid = null;
    _supabaseUid = null;
    _isMigrated = false;
    notifyListeners();
  }

  void clearUser() {
    _clearUserState();
  }

  void updateUser(Map<String, dynamic> updates) {
    if (_user != null) {
      try {
        final updatedMap = _user!.toMap();
        updatedMap.addAll(updates);
        final sanitized = _sanitizeUserData(updatedMap);
        _user = AppUser.fromMap(sanitized);

        if (updates.containsKey('uid'))
          _firebaseUid = updates['uid'] as String?;
        if (updates.containsKey('supabase_uid'))
          _supabaseUid = updates['supabase_uid'] as String?;
        if (updates.containsKey('migrated'))
          _isMigrated = updates['migrated'] == true;

        notifyListeners();
      } catch (e, stack) {
        _logEvent(
            eventType: 'PROVIDER_UPDATE_ERROR',
            errorDetails: e.toString(),
            stack: stack);
      }
    }
  }

  String? get safeUID {
    final uid = _firebaseUid ?? _supabaseUid;
    if (uid == null) {
      _logEvent(
          eventType: 'PROVIDER_SAFE_UID_NULL',
          errorDetails: 'Both _firebaseUid and _supabaseUid are null');
    }
    return uid;
  }
}

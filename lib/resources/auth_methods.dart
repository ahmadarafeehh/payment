import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_messaging/firebase_messaging.dart' as firebase_messaging;
import 'package:Ratedly/resources/storage_methods.dart';
import 'package:Ratedly/models/user.dart';
import 'package:country_detector/country_detector.dart';
import 'package:Ratedly/services/country_service.dart';
import 'package:Ratedly/services/debug_logger.dart';
import 'package:Ratedly/services/device_session.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;

class AuthMethods {
  final GoogleSignIn _googleSignIn;

  final SupabaseClient _supabase = Supabase.instance.client;
  final CountryService _countryService = CountryService();
  final CountryDetector _detector = CountryDetector();

  AuthMethods()
      : _googleSignIn = GoogleSignIn(
          scopes: ['email', 'profile'],
          clientId: defaultTargetPlatform == TargetPlatform.iOS
              ? '411393947451-dci447kne3aglou6qf8qqgh053sn1rps.apps.googleusercontent.com'
              : null,
          serverClientId: defaultTargetPlatform == TargetPlatform.iOS
              ? '411393947451-3h179hgbbhh3oqv8nm8ndbhc43j00rhc.apps.googleusercontent.com'
              : null,
        );

  String _generateRawNonce([int length = 32]) {
    const charset =
        '0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._';
    final random = Random.secure();
    return List.generate(length, (_) => charset[random.nextInt(charset.length)])
        .join();
  }

  String _sha256ofString(String input) {
    final bytes = utf8.encode(input);
    final digest = sha256.convert(bytes);
    return digest.toString();
  }

  // Shared username validation regex. Kept in one place so the client
  // (profile_setup_screen.dart) and server (this file) rules can no longer
  // silently drift apart.
  static final RegExp _usernameAllowedChars = RegExp(r'^[a-zA-Z0-9_.]+$');

  // =============================================
  // DEVICE-ID LINK-BACK
  // =============================================
  Future<void> _linkDeviceLogsToUid(String realUid) async {
    try {
      final deviceId = DeviceSession.idSync ?? await DeviceSession.id;
      if (deviceId == realUid) return; // nothing to link

      await _supabase
          .from('login_logs')
          .update({'supabase_uid': realUid}).eq('firebase_uid', deviceId);

      await _supabase
          .from('signup_debug_logs')
          .update({'supabase_uid': realUid}).eq('firebase_uid', deviceId);

      await _supabase
          .from('screen_time')
          .update({'uid': realUid}).eq('uid', deviceId);

      DebugLogger.logEvent(
          'DEVICE_LOGS_LINKED', 'deviceId=$deviceId realUid=$realUid');
    } catch (e) {
      DebugLogger.logError('LINK_DEVICE_LOGS', e);
    }
  }

  // =============================================
  // NATIVE GOOGLE SIGN‑IN
  // =============================================
  Future<String> signInWithGoogleNative() async {
    final deviceId = DeviceSession.idSync ?? await DeviceSession.id;
    DebugLogger.logEvent('GOOGLE_SIGNIN_STARTED', 'deviceId=$deviceId');
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) {
        DebugLogger.logEvent('GOOGLE_SIGNIN_CANCELLED', 'deviceId=$deviceId');
        return "cancelled";
      }
      DebugLogger.logEvent(
          'GOOGLE_SIGNIN_ACCOUNT_OBTAINED', 'deviceId=$deviceId');

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      if (googleAuth.idToken == null) {
        DebugLogger.logEvent(
            'GOOGLE_SIGNIN_NO_ID_TOKEN', 'deviceId=$deviceId');
        return "Google sign‑in failed: no ID token";
      }
      DebugLogger.logEvent(
          'GOOGLE_SIGNIN_ID_TOKEN_OBTAINED', 'deviceId=$deviceId');

      final AuthResponse response = await _supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: googleAuth.idToken!,
        accessToken: googleAuth.accessToken,
      );

      if (response.user == null) {
        DebugLogger.logEvent(
            'GOOGLE_SIGNIN_SUPABASE_NULL_USER', 'deviceId=$deviceId');
        return "Supabase sign‑in failed";
      }
      DebugLogger.logEvent('GOOGLE_SIGNIN_SUPABASE_SUCCESS',
          'deviceId=$deviceId supabaseUid=${response.user!.id}');

      final result = await _checkSupabaseUserOnboarding();
      DebugLogger.logEvent(
          'GOOGLE_SIGNIN_COMPLETE', 'deviceId=$deviceId result=$result');
      return result;
    } catch (e, stack) {
      DebugLogger.log(
        eventName: 'GOOGLE_SIGNIN_EXCEPTION',
        errorDetails: e.toString(),
        message: 'deviceId=$deviceId stack=${stack.toString()}',
      );
      return "Google sign‑in failed: ${e.toString()}";
    }
  }

  // =============================================
  // NATIVE APPLE SIGN‑IN
  // =============================================
  Future<String> signInWithAppleNative() async {
    final deviceId = DeviceSession.idSync ?? await DeviceSession.id;
    DebugLogger.logEvent('APPLE_SIGNIN_STARTED', 'deviceId=$deviceId');
    try {
      final rawNonce = _generateRawNonce();
      final hashedNonce = _sha256ofString(rawNonce);

      final appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email],
        nonce: hashedNonce,
      );
      DebugLogger.logEvent(
          'APPLE_SIGNIN_CREDENTIAL_OBTAINED', 'deviceId=$deviceId');

      final idToken = appleCredential.identityToken;
      if (idToken == null) {
        DebugLogger.logEvent('APPLE_SIGNIN_NO_ID_TOKEN', 'deviceId=$deviceId');
        return "Apple sign‑in failed: no ID token";
      }

      final AuthResponse response = await _supabase.auth.signInWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );

      if (response.user == null) {
        DebugLogger.logEvent(
            'APPLE_SIGNIN_SUPABASE_NULL_USER', 'deviceId=$deviceId');
        return "Supabase sign‑in failed";
      }
      DebugLogger.logEvent('APPLE_SIGNIN_SUPABASE_SUCCESS',
          'deviceId=$deviceId supabaseUid=${response.user!.id}');

      final result = await _checkSupabaseUserOnboarding();
      DebugLogger.logEvent(
          'APPLE_SIGNIN_COMPLETE', 'deviceId=$deviceId result=$result');
      return result;
    } on SignInWithAppleAuthorizationException catch (e, stack) {
      if (e.code == AuthorizationErrorCode.canceled) {
        DebugLogger.logEvent('APPLE_SIGNIN_CANCELLED', 'deviceId=$deviceId');
        return "cancelled";
      }
      DebugLogger.log(
        eventName: 'APPLE_SIGNIN_AUTHORIZATION_EXCEPTION',
        errorDetails: e.message,
        message: 'deviceId=$deviceId stack=${stack.toString()}',
      );
      return "Apple sign‑in failed: ${e.message}";
    } catch (e, stack) {
      DebugLogger.log(
        eventName: 'APPLE_SIGNIN_EXCEPTION',
        errorDetails: e.toString(),
        message: 'deviceId=$deviceId stack=${stack.toString()}',
      );
      return "Apple sign‑in failed: ${e.toString()}";
    }
  }

  // =============================================
  // SUPABASE OAUTH (web)
  // =============================================
  Future<String> signUpWithGoogleSupabase() async {
    try {
      await _supabase.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'ratedly://login-callback',
      );
      return "oauth_initiated";
    } catch (e) {
      DebugLogger.logError('GOOGLE_SUPABASE_OAUTH', e);
      if (e is AuthException) return "Google sign-up failed: ${e.message}";
      return "Google sign-up failed: $e";
    }
  }

  Future<String> signUpWithAppleSupabase() async {
    try {
      await _supabase.auth.signInWithOAuth(
        OAuthProvider.apple,
        redirectTo: 'ratedly://login-callback',
      );
      return "oauth_initiated";
    } catch (e) {
      DebugLogger.logError('APPLE_SUPABASE_OAUTH', e);
      if (e is AuthException) return "Apple sign-up failed: ${e.message}";
      return "Apple sign-up failed: $e";
    }
  }

  // =============================================
  // CHECK SUPABASE USER ONBOARDING
  // =============================================
  Future<String> _checkSupabaseUserOnboarding() async {
    try {
      final session = _supabase.auth.currentSession;
      if (session == null) {
        DebugLogger.logEvent('CHECK_ONBOARDING_NO_SESSION');
        return "no_session";
      }

      final List<dynamic> userRecords = await _supabase
          .from('users')
          .select('username, "dateOfBirth", gender, "onboardingComplete", uid')
          .eq('supabase_uid', session.user.id)
          .limit(1);

      if (userRecords.isEmpty) {
        DebugLogger.logEvent('CHECK_ONBOARDING_CREATING_NEW_USER',
            'supabaseUid=${session.user.id}');
        try {
          await _supabase.from('users').upsert({
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
          }, onConflict: 'uid');

          await _linkDeviceLogsToUid(session.user.id);
        } catch (e) {
          DebugLogger.log(
            eventName: 'CHECK_ONBOARDING_USER_CREATE_ERROR',
            errorDetails: e.toString(),
            message: 'supabaseUid=${session.user.id}',
          );
        }
        return "onboarding_required";
      }

      final Map<String, dynamic> data = userRecords[0];
      final hasCompletedOnboarding = data['onboardingComplete'] == true ||
          (data['username'] != null &&
              data['username'].toString().isNotEmpty &&
              data['dateOfBirth'] != null &&
              data['gender'] != null &&
              data['gender'].toString().isNotEmpty);

      DebugLogger.logEvent('CHECK_ONBOARDING_EXISTING_USER',
          'supabaseUid=${session.user.id} complete=$hasCompletedOnboarding');

      return hasCompletedOnboarding ? "success" : "onboarding_required";
    } catch (e) {
      DebugLogger.log(
        eventName: 'CHECK_ONBOARDING_UNEXPECTED_ERROR',
        errorDetails: e.toString(),
      );
      return "onboarding_required";
    }
  }

  // =============================================
  // COMPLETE PROFILE — SUPABASE USER
  // =============================================
  Future<String> completeProfileSupabase({
    required String username,
    required String bio,
    Uint8List? file,
    bool isPrivate = false,
    required DateTime dateOfBirth,
    required String gender,
  }) async {
    try {
      final session = _supabase.auth.currentSession;
      if (session == null) return "User not authenticated";

      final processedUsername = username.trim();
      if (processedUsername.isEmpty) return "Username cannot be empty";
      if (processedUsername.length < 3)
        return "Username must be at least 3 characters";
      if (processedUsername.length > 20)
        return "Username cannot exceed 20 characters";
      if (!_usernameAllowedChars.hasMatch(processedUsername)) {
        return "Username can only contain letters, numbers, '.', and underscores";
      }

      final List<dynamic> usernameRes = await _supabase
          .from('users')
          .select('uid')
          .eq('username', processedUsername)
          .limit(1);

      if (usernameRes.isNotEmpty) {
        final existingUserId = usernameRes[0]['uid'] as String;
        if (existingUserId != session.user.id) {
          return "Username '$processedUsername' is already taken";
        }
      }

      String photoUrl = 'default';
      if (file != null) {
        String fileName =
            'profile_${DateTime.now().millisecondsSinceEpoch}.jpg';
        photoUrl = await StorageMethods().uploadImageToSupabase(
          file,
          fileName,
          useUserFolder: true,
        );
      }

      String? fcmToken;
      try {
        final messaging = firebase_messaging.FirebaseMessaging.instance;
        fcmToken = await messaging.getToken();
      } catch (_) {}

      final payload = {
        'uid': session.user.id,
        'email': session.user.email,
        'username': processedUsername,
        'bio': bio,
        'photoUrl': photoUrl,
        'isPrivate': isPrivate,
        'onboardingComplete': true,
        'createdAt': DateTime.now().toIso8601String(),
        'dateOfBirth': dateOfBirth.toIso8601String(),
        'gender': gender,
        'isVerified': false,
        'migrated': true,
        'supabase_uid': session.user.id,
        'blockedUsers': <dynamic>[],
        if (fcmToken != null) 'fcmToken': fcmToken,
      };

      await _supabase.from('users').upsert(payload, onConflict: 'uid');
      await _countryService.setCountryForUser(session.user.id);

      DebugLogger.logEvent(
          'COMPLETE_PROFILE_SUCCESS', 'supabaseUid=${session.user.id}');
      return "success";
    } catch (e) {
      DebugLogger.log(
        eventName: 'COMPLETE_PROFILE_ERROR',
        errorDetails: e.toString(),
      );
      return "Failed to save profile: ${e.toString()}";
    }
  }

  // =============================================
  // GET SUPABASE USER DETAILS
  // =============================================
  Future<AppUser?> getSupabaseUserDetails() async {
    try {
      final session = _supabase.auth.currentSession;
      if (session == null) return null;

      final List<dynamic> data = await _supabase
          .from('users')
          .select()
          .eq('supabase_uid', session.user.id)
          .limit(1);

      if (data.isEmpty) return null;
      return AppUser.fromMap(_sanitizeBlockedUsers(data[0]));
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST116') return null;
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<void> signOut() async {
    await _googleSignIn.signOut();
    try {
      await _supabase.auth.signOut();
    } catch (e) {}
  }

  Future<void> checkCountryPeriodically() async {
    await _countryService.checkAndUpdateCountryIfNeeded();
  }

  Future<void> backfillCountryForExistingUsers() async {
    await _countryService.checkAndBackfillCountryForExistingUsers();
  }

  // =============================================
  // UTILITY
  // =============================================
  static Map<String, dynamic> _sanitizeBlockedUsers(Map<String, dynamic> raw) {
    final data = Map<String, dynamic>.from(raw);
    final val = data['blockedUsers'];

    if (val == null || val is List) {
      data['blockedUsers'] = val ?? <dynamic>[];
    } else if (val is String) {
      String cleaned = val.trim();
      while (cleaned.startsWith('"') && cleaned.endsWith('"')) {
        try {
          final decoded = jsonDecode(cleaned);
          if (decoded is List) {
            data['blockedUsers'] = decoded;
            return data;
          } else if (decoded is String) {
            cleaned = decoded.trim();
          } else {
            break;
          }
        } catch (_) {
          cleaned = cleaned.substring(1, cleaned.length - 1);
        }
      }
      try {
        final decoded = jsonDecode(cleaned);
        data['blockedUsers'] = decoded is List ? decoded : <dynamic>[];
      } catch (_) {
        data['blockedUsers'] = <dynamic>[];
      }
    } else {
      data['blockedUsers'] = <dynamic>[];
    }

    return data;
  }

  static dynamic _unwrapSupabaseResponse(dynamic res) {
    try {
      if (res == null) return null;
      final data = (res is Map && res.containsKey('data')) ? res['data'] : null;
      if (data != null) return data;
    } catch (_) {}
    return res;
  }

  Future<List<String>> getUserFollowers(String uid) async {
    try {
      final dynamic res = await _supabase
          .from('user_followers')
          .select('follower_id')
          .eq('user_id', uid);

      final dynamic data = _unwrapSupabaseResponse(res) ?? res;
      if (data is List) {
        return data
            .map<String>(
                (e) => (e['follower_id'] ?? e['followerId'])?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
      } else if (data is Map) {
        final id = (data['follower_id'] ?? data['followerId'])?.toString();
        return id != null ? [id] : [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  Future<List<String>> getUserFollowing(String uid) async {
    try {
      final dynamic res = await _supabase
          .from('user_following')
          .select('following_id')
          .eq('user_id', uid);

      final dynamic data = _unwrapSupabaseResponse(res) ?? res;
      if (data is List) {
        return data
            .map<String>((e) =>
                (e['following_id'] ?? e['followingId'])?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
      } else if (data is Map) {
        final id = (data['following_id'] ?? data['followingId'])?.toString();
        return id != null ? [id] : [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }

  Future<List<String>> getFollowRequests(String uid) async {
    try {
      final dynamic res = await _supabase
          .from('user_follow_request')
          .select('requester_id')
          .eq('user_id', uid);

      final dynamic data = _unwrapSupabaseResponse(res) ?? res;
      if (data is List) {
        return data
            .map<String>((e) =>
                (e['requester_id'] ?? e['requesterId'])?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();
      } else if (data is Map) {
        final id = (data['requester_id'] ?? data['requesterId'])?.toString();
        return id != null ? [id] : [];
      }
      return [];
    } catch (e) {
      return [];
    }
  }
}

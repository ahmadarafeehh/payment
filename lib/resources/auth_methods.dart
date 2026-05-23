import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:Ratedly/resources/storage_methods.dart';
import 'package:Ratedly/models/user.dart';
import 'package:country_detector/country_detector.dart';
import 'package:Ratedly/services/country_service.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;

class AuthMethods {
  final firebase_auth.FirebaseAuth _auth = firebase_auth.FirebaseAuth.instance;

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

  // =============================================
  // NATIVE GOOGLE SIGN‑IN
  // =============================================
  Future<String> signInWithGoogleNative() async {
    try {
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return "cancelled";

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;

      if (googleAuth.idToken == null) {
        return "Google sign‑in failed: no ID token";
      }

      final AuthResponse response = await _supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: googleAuth.idToken!,
        accessToken: googleAuth.accessToken,
      );

      if (response.user == null) return "Supabase sign‑in failed";

      return await _checkSupabaseUserOnboarding();
    } catch (e, stack) {
      return "Google sign‑in failed: ${e.toString()}";
    }
  }

  // =============================================
  // NATIVE GOOGLE MIGRATION
  // =============================================
  Future<String> migrateGoogleUserNative() async {
    try {
      final result = await signInWithGoogleNative();
      if (result == "success" || result == "onboarding_required") {
        final firebaseUser = _auth.currentUser;
        final supabaseSession = _supabase.auth.currentSession;
        if (firebaseUser != null && supabaseSession != null) {
          await markAsMigrated(firebaseUser.uid, supabaseSession.user.id);
        }
      }
      return result;
    } catch (e) {
      return "Google migration failed: $e";
    }
  }

  // =============================================
  // NATIVE APPLE SIGN‑IN
  // =============================================
  Future<String> signInWithAppleNative() async {
    try {
      final rawNonce = _generateRawNonce();
      final hashedNonce = _sha256ofString(rawNonce);

      final appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email],
        nonce: hashedNonce,
      );

      final idToken = appleCredential.identityToken;
      if (idToken == null) return "Apple sign‑in failed: no ID token";

      final AuthResponse response = await _supabase.auth.signInWithIdToken(
        provider: OAuthProvider.apple,
        idToken: idToken,
        nonce: rawNonce,
      );

      if (response.user == null) return "Supabase sign‑in failed";

      return await _checkSupabaseUserOnboarding();
    } on SignInWithAppleAuthorizationException catch (e, stack) {
      if (e.code == AuthorizationErrorCode.canceled) return "cancelled";
      return "Apple sign‑in failed: ${e.message}";
    } catch (e, stack) {
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
      if (session == null) return "no_session";

      final List<dynamic> userRecords = await _supabase
          .from('users')
          .select('username, "dateOfBirth", gender, "onboardingComplete", uid')
          .eq('supabase_uid', session.user.id)
          .limit(1);

      if (userRecords.isEmpty) {
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
            'test': Random().nextBool(), // ← randomly assign A/B test group
          }, onConflict: 'uid');
        } catch (e) {
          // ignore
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

      return hasCompletedOnboarding ? "success" : "onboarding_required";
    } catch (e) {
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
      if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(processedUsername)) {
        return "Username can only contain letters, numbers, and underscores";
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
        'isVerified': false, // ✅ FIX: blue check earned via referrals only
        'migrated': true,
        'supabase_uid': session.user.id,
        'blockedUsers': <dynamic>[],
      };

      await _supabase.from('users').upsert(payload, onConflict: 'uid');
      await _countryService.setCountryForUser(session.user.id);

      return "success";
    } catch (e) {
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

  // =============================================
  // FIREBASE MIGRATION HELPERS
  // =============================================
  Future<String> migrateGoogleUser({
    required String firebaseUid,
    required String email,
  }) async {
    try {
      await _supabase.auth.signInWithOAuth(
        OAuthProvider.google,
        redirectTo: 'ratedly://login-callback',
      );
      return "oauth_initiated";
    } catch (e) {
      return "Google migration failed: $e";
    }
  }

  Future<String> completeMigrationAfterOAuth() async {
    try {
      await Future.delayed(const Duration(seconds: 1));

      final session = _supabase.auth.currentSession;
      if (session == null) {
        return "No Supabase session found. OAuth might have failed.";
      }

      final firebaseUser = _auth.currentUser;
      if (firebaseUser == null) {
        return "Firebase user not found. Please log in again.";
      }

      final List<dynamic> userCheck = await _supabase
          .from('users')
          .select('migrated, supabase_uid')
          .eq('uid', firebaseUser.uid)
          .limit(1);

      if (userCheck.isNotEmpty && userCheck[0]['migrated'] == true) {
        return "already_migrated";
      }

      await _supabase.from('users').update({
        'migrated': true,
        'supabase_uid': session.user.id,
      }).eq('uid', firebaseUser.uid);

      return "success";
    } catch (e) {
      return "Failed to complete migration: $e";
    }
  }

  Future<bool> checkAndCompleteMigration() async {
    try {
      final firebaseUser = _auth.currentUser;
      if (firebaseUser == null) return false;

      final session = _supabase.auth.currentSession;
      if (session == null) return false;

      final List<dynamic> userCheck = await _supabase
          .from('users')
          .select('migrated')
          .eq('uid', firebaseUser.uid)
          .limit(1);

      if (userCheck.isEmpty) return false;

      if (userCheck[0]['migrated'] != true) {
        await _supabase.from('users').update({
          'migrated': true,
          'supabase_uid': session.user.id,
        }).eq('uid', firebaseUser.uid);
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  // =============================================
  // GET USER DETAILS (Firebase UID based)
  // =============================================
  Future<AppUser?> getUserDetails() async {
    try {
      final user = _auth.currentUser;
      if (user == null) return null;

      final List<dynamic> data =
          await _supabase.from('users').select().eq('uid', user.uid).limit(1);

      if (data.isEmpty) return null;
      return AppUser.fromMap(_sanitizeBlockedUsers(data[0]));
    } on PostgrestException catch (e) {
      if (e.code == 'PGRST116') return null;
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<bool> needsMigration(String uid) async {
    try {
      final List<dynamic> result = await _supabase
          .from('users')
          .select('migrated')
          .eq('uid', uid)
          .limit(1);

      if (result.isEmpty) return true;
      return result[0]['migrated'] != true;
    } catch (e) {
      return true;
    }
  }

  Future<void> markAsMigrated(String uid, String? supabaseUid) async {
    try {
      await _supabase.from('users').update({
        'migrated': true,
        'supabase_uid': supabaseUid,
      }).eq('uid', uid);
    } catch (e) {
      rethrow;
    }
  }

  // =============================================
  // EMAIL/PASSWORD SIGNUP (Firebase)
  // =============================================
  Future<String> signUpUser({
    required String email,
    required String password,
  }) async {
    try {
      if (email.isEmpty || password.isEmpty) {
        return "Please fill all required fields";
      }

      final List<dynamic> existingUsers = await _supabase
          .from('users')
          .select('uid')
          .eq('email', email)
          .limit(1);

      if (existingUsers.isNotEmpty) {
        return "User with this email already exists. Please log in instead.";
      }

      final firebase_auth.UserCredential cred =
          await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (cred.user == null) return "Registration failed - please try again";

      await cred.user!.sendEmailVerification();

      try {
        await _supabase.from('users').upsert({
          'uid': cred.user!.uid,
          'email': cred.user!.email,
          'username': '',
          'bio': '',
          'photoUrl': 'default',
          'isPrivate': false,
          'onboardingComplete': false,
          'createdAt': DateTime.now().toIso8601String(),
          'dateOfBirth': null,
          'gender': null,
          'isVerified': false, // ✅ FIX: never auto-verify on signup
          'blockedUsers': <dynamic>[],
          'country': null,
          'migrated': false,
        });
      } catch (_) {}

      return "success";
    } on firebase_auth.FirebaseAuthException catch (e) {
      if (e.code == 'email-already-in-use') {
        return "Email already registered. Please log in instead.";
      }
      return e.message ?? "Registration failed";
    } catch (err) {
      return err.toString();
    }
  }

  // =============================================
  // COMPLETE PROFILE (Firebase user)
  // =============================================
  Future<String> completeProfile({
    required String username,
    required String bio,
    Uint8List? file,
    bool isPrivate = false,
    required DateTime dateOfBirth,
    required String gender,
  }) async {
    try {
      final firebase_auth.User? user = _auth.currentUser;
      if (user == null) return "User not authenticated";

      final isSocialUser = user.providerData
          .any((userInfo) => userInfo.providerId != 'password');

      if (!isSocialUser && !user.emailVerified) return "Email not verified";

      final processedUsername = username.trim();
      if (processedUsername.isEmpty) return "Username cannot be empty";
      if (processedUsername.length < 3)
        return "Username must be at least 3 characters";
      if (processedUsername.length > 20)
        return "Username cannot exceed 20 characters";
      if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(processedUsername)) {
        return "Username can only contain letters, numbers, and underscores";
      }

      final List<dynamic> usernameRes = await _supabase
          .from('users')
          .select('uid')
          .eq('username', processedUsername)
          .limit(1);

      if (usernameRes.isNotEmpty) {
        return "Username '$processedUsername' is already taken";
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

      final List<dynamic> currentUserData = await _supabase
          .from('users')
          .select('country')
          .eq('uid', user.uid)
          .limit(1);

      final String? existingCountry = currentUserData.isNotEmpty
          ? currentUserData[0]['country'] as String?
          : null;

      final payload = {
        'uid': user.uid,
        'email': user.email,
        'username': processedUsername,
        'bio': bio,
        'photoUrl': photoUrl,
        'isPrivate': isPrivate,
        'onboardingComplete': true,
        'createdAt': DateTime.now().toIso8601String(),
        'dateOfBirth': dateOfBirth.toIso8601String(),
        'gender': gender,
        'isVerified': false, // ✅ FIX: blue check earned via referrals only
        'migrated': false,
        'blockedUsers': <dynamic>[],
      };

      await _supabase.from('users').upsert(payload);

      if (existingCountry == null) {
        await _countryService.setCountryForUser(user.uid);
      } else {
        await _countryService.setupCountryTimer(user.uid);
      }

      return "success";
    } on Exception catch (e) {
      return e.toString();
    }
  }

  // =============================================
  // UNIFIED LOGIN
  // =============================================
  Future<String> loginUser({
    required String email,
    required String password,
  }) async {
    try {
      final List<dynamic> userRecords = await _supabase
          .from('users')
          .select('uid, migrated, "supabase_uid", "createdAt"')
          .eq('email', email);

      if (userRecords.isEmpty) {
        return await _loginWithFirebase(email, password, null);
      }

      userRecords.sort((a, b) {
        final aTime = DateTime.parse(a['createdAt'] ?? '2000-01-01');
        final bTime = DateTime.parse(b['createdAt'] ?? '2000-01-01');
        return bTime.compareTo(aTime);
      });

      final Map<String, dynamic> userRecord = userRecords[0];
      final bool isMigrated = userRecord['migrated'] == true;
      final String firebaseUid = userRecord['uid'] as String;
      final String? supabaseUid = userRecord['supabase_uid'] as String?;

      if (isMigrated && supabaseUid != null) {
        try {
          final AuthResponse supabaseResponse =
              await _supabase.auth.signInWithPassword(
            email: email,
            password: password,
          );

          if (supabaseResponse.user != null) {
            return await _checkOnboardingStatus(firebaseUid);
          }
        } on AuthException catch (_) {
          return await _loginWithFirebase(email, password, firebaseUid);
        }
      } else {
        return await _loginWithFirebase(email, password, firebaseUid);
      }

      return "Incorrect email or password";
    } catch (e) {
      return "An unexpected error occurred";
    }
  }

  Future<String> _loginWithFirebase(
    String email,
    String password,
    String? expectedUid,
  ) async {
    try {
      final firebaseCred = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (firebaseCred.user == null) return "Login failed";

      final firebaseUid = firebaseCred.user!.uid;

      if (expectedUid != null && firebaseUid != expectedUid) {
        return "Account mismatch. Please contact support.";
      }

      final needsMigration = await this.needsMigration(firebaseUid);
      if (needsMigration) return "needs_migration";

      return await _checkOnboardingStatus(firebaseUid);
    } on firebase_auth.FirebaseAuthException catch (e) {
      if (e.code == 'invalid-email') {
        return "Please enter a valid email address";
      } else if (e.code == 'wrong-password' || e.code == 'user-not-found') {
        return "Incorrect email or password";
      } else if (e.code == 'user-disabled') {
        return "Account disabled";
      } else if (e.code == 'too-many-requests') {
        return "Too many attempts. Try again later";
      } else {
        return "Incorrect email or password";
      }
    } catch (e) {
      return "An unexpected error occurred";
    }
  }

  Future<String> _checkOnboardingStatus(String uid) async {
    try {
      final List<dynamic> userRecords = await _supabase
          .from('users')
          .select('username, "dateOfBirth", gender, "onboardingComplete"')
          .eq('uid', uid)
          .limit(1);

      if (userRecords.isEmpty) return "onboarding_required";

      final Map<String, dynamic> data = userRecords[0];
      final hasCompletedOnboarding = data['onboardingComplete'] == true ||
          (data['username'] != null &&
              data['username'].toString().isNotEmpty &&
              data['dateOfBirth'] != null &&
              data['gender'] != null &&
              data['gender'].toString().isNotEmpty);

      return hasCompletedOnboarding ? "success" : "onboarding_required";
    } catch (e) {
      return "onboarding_required";
    }
  }

  String _handleFirebaseAuthError(firebase_auth.FirebaseAuthException e) {
    switch (e.code) {
      case 'account-exists-with-different-credential':
        return 'Email already linked with another method';
      case 'invalid-credential':
        return 'Invalid Google credentials';
      case 'operation-not-allowed':
        return 'Google sign-in is disabled';
      case 'user-disabled':
        return 'User account disabled';
      case 'operation-not-supported':
        return 'Apple sign-in is not enabled';
      case 'user-not-found':
        return 'User not found';
      default:
        return 'Authentication failed: ${e.message}';
    }
  }

  // =============================================
  // GOOGLE SIGN-IN (Firebase + Supabase)
  // =============================================
  Future<String> signInWithGoogle() async {
    String? email;
    try {
      // 1. Get Google account
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return "cancelled";

      email = googleUser.email;

      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      final String? idToken = googleAuth.idToken;
      final String? accessToken = googleAuth.accessToken;

      if (idToken == null) {
        return "Google sign‑in failed: no ID token";
      }

      // 2. Query Supabase users by email
      final List<dynamic> userRecords = await _supabase
          .from('users')
          .select('uid, migrated, supabase_uid')
          .eq('email', email);

      // 3. Check for a Supabase Auth user (has supabase_uid)
      final Map<String, dynamic>? supabaseUserRecord =
          userRecords.cast<Map<String, dynamic>?>().firstWhere(
                (record) => record?['supabase_uid'] != null,
                orElse: () => null,
              );

      if (supabaseUserRecord != null) {
        final AuthResponse response = await _supabase.auth.signInWithIdToken(
          provider: OAuthProvider.google,
          idToken: idToken,
          accessToken: accessToken,
        );
        if (response.user == null) {
          return "Supabase sign‑in failed";
        }

        return await _checkSupabaseUserOnboarding();
      }

      // 4. Check for a Firebase user (migrated == false)
      final Map<String, dynamic>? firebaseUserRecord =
          userRecords.cast<Map<String, dynamic>?>().firstWhere(
                (record) => record?['migrated'] == false,
                orElse: () => null,
              );

      if (firebaseUserRecord != null) {
        final credential = firebase_auth.GoogleAuthProvider.credential(
          idToken: idToken,
          accessToken: accessToken,
        );
        final firebase_auth.UserCredential cred;
        try {
          cred = await _auth.signInWithCredential(credential);
        } on firebase_auth.FirebaseAuthException catch (e) {
          return _handleFirebaseAuthError(e);
        }

        final String userId = cred.user!.uid;

        final needsMigration = await this.needsMigration(userId);
        if (needsMigration) return "needs_migration";

        final List<dynamic> res = await _supabase
            .from('users')
            .select('username, dateOfBirth, gender, onboardingComplete')
            .eq('uid', userId)
            .limit(1);

        if (res.isEmpty) {
          await _supabase.from('users').upsert({
            'uid': userId,
            'email': email,
            'username': '',
            'bio': '',
            'photoUrl': 'default',
            'isPrivate': false,
            'onboardingComplete': false,
            'createdAt': DateTime.now().toIso8601String(),
            'dateOfBirth': null,
            'gender': null,
            'isVerified': false, // ✅ FIX: never auto-verify on signup
            'blockedUsers': <dynamic>[],
            'country': null,
            'migrated': false,
          }, onConflict: 'uid');
          return "onboarding_required";
        }

        final Map<String, dynamic> data = res[0];
        final hasCompletedOnboarding = data['onboardingComplete'] == true ||
            (data['username'] != null &&
                data['username'].toString().isNotEmpty &&
                data['dateOfBirth'] != null &&
                data['gender'] != null &&
                data['gender'].toString().isNotEmpty);

        return hasCompletedOnboarding ? "success" : "onboarding_required";
      }

      // 5. No existing user → sign up with Supabase (new user)
      final AuthResponse response = await _supabase.auth.signInWithIdToken(
        provider: OAuthProvider.google,
        idToken: idToken,
        accessToken: accessToken,
      );
      if (response.user == null) {
        return "Supabase sign‑up failed";
      }

      return await _checkSupabaseUserOnboarding();
    } on firebase_auth.FirebaseAuthException catch (e, stack) {
      return _handleFirebaseAuthError(e);
    } on AuthException catch (e, stack) {
      return "Supabase auth error: ${e.message}";
    } catch (e, stack) {
      return "Google sign‑in failed: ${e.toString()}";
    }
  }

  // =============================================
  // APPLE SIGN-IN (Firebase)
  // =============================================
  Future<String> signInWithApple() async {
    String? rawNonce;
    String? hashedNonce;

    try {
      rawNonce = _generateRawNonce();
      hashedNonce = _sha256ofString(rawNonce);

      final appleCredential = await SignInWithApple.getAppleIDCredential(
        scopes: [AppleIDAuthorizationScopes.email],
        nonce: hashedNonce,
      );

      final identityToken = appleCredential.identityToken;
      final oauthProvider = firebase_auth.OAuthProvider('apple.com');
      final oauthCredential = oauthProvider.credential(
        idToken: identityToken,
        accessToken: appleCredential.authorizationCode,
        rawNonce: rawNonce,
      );

      final firebase_auth.UserCredential userCredential =
          await _auth.signInWithCredential(oauthCredential);

      final String userId = userCredential.user!.uid;
      final String? userEmail = userCredential.user!.email;

      final List<dynamic> res = await _supabase
          .from('users')
          .select(
              'username, "dateOfBirth", gender, "onboardingComplete", migrated')
          .eq('uid', userId)
          .limit(1);

      if (res.isEmpty) {
        try {
          await _supabase.from('users').upsert({
            'uid': userId,
            'email': userEmail,
            'username': '',
            'bio': '',
            'photoUrl': 'default',
            'isPrivate': false,
            'onboardingComplete': false,
            'createdAt': DateTime.now().toIso8601String(),
            'dateOfBirth': null,
            'gender': null,
            'isVerified': false, // ✅ FIX: never auto-verify on signup
            'blockedUsers': <dynamic>[],
            'country': null,
            'migrated': false,
          });
        } catch (e) {}
        return "onboarding_required";
      }

      final Map<String, dynamic> data = res[0];
      if (data['migrated'] != true) return "needs_migration";

      final hasCompletedOnboarding = data['onboardingComplete'] == true ||
          (data['username'] != null &&
              data['username'].toString().isNotEmpty &&
              data['dateOfBirth'] != null &&
              data['gender'] != null &&
              data['gender'].toString().isNotEmpty);

      return hasCompletedOnboarding ? "success" : "onboarding_required";
    } on SignInWithAppleAuthorizationException catch (e) {
      return e.code == AuthorizationErrorCode.canceled
          ? "cancelled"
          : "Apple sign-in failed: ${e.message}";
    } on firebase_auth.FirebaseAuthException catch (e) {
      return _handleFirebaseAuthError(e);
    } catch (e) {
      return "Unexpected error: ${e.toString()}";
    }
  }

  // =============================================
  // MIGRATION STATUS
  // =============================================
  Future<Map<String, dynamic>> getCurrentUserMigrationStatus() async {
    final user = _auth.currentUser;
    if (user == null) {
      return {'needs_migration': false, 'reason': 'not_logged_in'};
    }

    try {
      final List<dynamic> result = await _supabase
          .from('users')
          .select('migrated, email')
          .eq('uid', user.uid)
          .limit(1);

      if (result.isEmpty) {
        return {
          'needs_migration': true,
          'reason': 'no_user_record',
          'email': user.email,
          'firebase_uid': user.uid,
        };
      }

      final isMigrated = result[0]['migrated'] == true;
      return {
        'needs_migration': !isMigrated,
        'reason': isMigrated ? 'already_migrated' : 'needs_migration',
        'email': result[0]['email'] ?? user.email,
        'firebase_uid': user.uid,
        'migrated': isMigrated,
      };
    } catch (e) {
      return {
        'needs_migration': true,
        'reason': 'error_checking_status',
        'error': e.toString(),
        'firebase_uid': user.uid,
      };
    }
  }

  Future<firebase_auth.OAuthCredential?> getCurrentUserCredential() async {
    try {
      final GoogleSignInAccount? googleUser =
          await _googleSignIn.signInSilently();
      if (googleUser == null) return null;
      final GoogleSignInAuthentication googleAuth =
          await googleUser.authentication;
      return firebase_auth.GoogleAuthProvider.credential(
        idToken: googleAuth.idToken,
        accessToken: googleAuth.accessToken,
      );
    } catch (e) {
      return null;
    }
  }

  Future<void> signOut() async {
    await _auth.signOut();
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

  // =============================================
  // MIGRATION METHOD (email/password)
  // =============================================
  Future<String> migrateUser({
    required String email,
    required String newPassword,
    required String firebaseUid,
  }) async {
    try {
      final firebaseUser = _auth.currentUser;
      if (firebaseUser == null)
        return "User not logged in. Please log in first.";
      if (firebaseUser.uid != firebaseUid)
        return "UID mismatch. Please log in with the correct account.";
      if (firebaseUser.email != email)
        return "Email mismatch. Please log in with the correct account.";

      final AuthResponse response = await _supabase.auth.signUp(
        email: email,
        password: newPassword,
        data: {'firebase_uid': firebaseUid},
      );

      if (response.user == null) return "Failed to create Supabase account";

      await _supabase.from('users').update({
        'migrated': true,
        'supabase_uid': response.user!.id,
      }).eq('uid', firebaseUid);

      return "success";
    } on AuthException catch (e) {
      if (e.message?.contains('User already registered') ?? false) {
        try {
          final signInResponse = await _supabase.auth.signInWithPassword(
            email: email,
            password: newPassword,
          );

          if (signInResponse.user != null) {
            await _supabase.from('users').update({
              'migrated': true,
              'supabase_uid': signInResponse.user!.id,
            }).eq('uid', firebaseUid);
            return "success";
          }
          return "Account exists but could not sign in. Please try a different password.";
        } catch (signInError) {
          return "Account exists but could not sign in. Please try a different password or contact support.";
        }
      }
      return "Migration failed: ${e.message}";
    } catch (e) {
      return "Migration failed: $e";
    }
  }
}

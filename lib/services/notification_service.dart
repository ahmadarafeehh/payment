import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart'
    as firebase_messaging;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class NotificationService {
  final firebase_messaging.FirebaseMessaging _firebaseMessaging =
      firebase_messaging.FirebaseMessaging.instance;
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();

  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  int _getNotificationId() {
    return DateTime.now().millisecondsSinceEpoch % 2147483647;
  }

  // ─── INIT ────────────────────────────────────────────────────────────────
  Future<void> init() async {
    try {
      await _firebaseMessaging.requestPermission(
        alert: true,
        badge: true,
        criticalAlert: true,
        provisional: true,
        sound: true,
      );

      await firebase_messaging.FirebaseMessaging.instance
          .setForegroundNotificationPresentationOptions(
        alert: false,
        badge: false,
        sound: false,
      );

      firebase_messaging.FirebaseMessaging.onMessage
          .listen(_handleForegroundMessage);
      firebase_messaging.FirebaseMessaging.onMessageOpenedApp
          .listen(_handleBackgroundMessage);

      await _handleTokenRetrieval();

      _firebaseMessaging.onTokenRefresh.listen((newToken) async {
        await _saveToken(newToken);
      });

      const DarwinInitializationSettings initializationSettingsIOS =
          DarwinInitializationSettings();

      await _notifications.initialize(
        InitializationSettings(iOS: initializationSettingsIOS),
        onDidReceiveNotificationResponse:
            (NotificationResponse response) async {
          if (response.payload != null) {
            try {
              jsonDecode(response.payload!);
            } catch (e) {}
          }
        },
      );

      await _configureNotificationChannels();
      _setupAuthListener();
    } catch (e) {}
  }

  // ─── AUTH LISTENER ───────────────────────────────────────────────────────
  Future<void> _setupAuthListener() async {
    firebase_auth.FirebaseAuth.instance
        .authStateChanges()
        .listen((firebase_auth.User? user) async {
      if (user != null) {
        final token = await _firebaseMessaging.getToken();
        if (token != null) {
          await _saveToken(token);
        }
      }
    });
  }

  // ─── TOKEN RETRIEVAL ─────────────────────────────────────────────────────
  Future<void> _handleTokenRetrieval() async {
    try {
      final token = await _firebaseMessaging.getToken();
      if (token != null) {
        await _saveToken(token);
      }
    } catch (e) {}
  }

  Future<void> _configureNotificationChannels() async {
    try {
      final iOSPlugin = _notifications.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      if (iOSPlugin != null) {
        await iOSPlugin.requestPermissions(
          alert: true,
          badge: true,
          sound: true,
        );
      }
    } catch (e) {}
  }

  // ─── UNIFIED TOKEN SAVER ─────────────────────────────────────────────────
  Future<void> _saveToken(String token) async {
    await Future.wait([
      _saveTokenToSupabase(token),
      _saveTokenToFirestore(token),
    ]);
  }

  /// Saves the FCM token to Supabase.
  ///
  /// KEY FIX: Always saves by the `uid` column (text primary key), which is
  /// always populated for every user — both Firebase and Supabase auth users.
  ///
  /// The previous bug saved Supabase-auth users by `supabase_uid`, which is
  /// a nullable column. If it was null the UPDATE matched zero rows, the token
  /// was never stored, and the Cloud Function silently skipped those users.
  Future<void> _saveTokenToSupabase(String token) async {
    try {
      final supabase = Supabase.instance.client;
      final firebaseUser = firebase_auth.FirebaseAuth.instance.currentUser;
      final supabaseUser = supabase.auth.currentUser;

      // ── Firebase auth user ───────────────────────────────────────────────
      // uid column stores the Firebase UID directly.
      if (firebaseUser != null) {
        await supabase
            .from('users')
            .update({'fcmToken': token}).eq('uid', firebaseUser.uid);
        return;
      }

      // ── Supabase auth user ───────────────────────────────────────────────
      // uid column stores the Supabase auth UUID as text (set at registration).
      // Do NOT use supabase_uid here — that column is nullable and will silently
      // match zero rows if it hasn't been populated yet (e.g. migrated accounts).
      if (supabaseUser != null) {
        await supabase
            .from('users')
            .update({'fcmToken': token}).eq('uid', supabaseUser.id);
        return;
      }

      await _storePendingToken(token);
    } catch (e) {}
  }

  Future<void> _saveTokenToFirestore(String token) async {
    try {
      final user = firebase_auth.FirebaseAuth.instance.currentUser;
      if (user == null) {
        return;
      }

      await user.reload();
      if (!user.emailVerified) {
        return;
      }

      await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .set({'fcmToken': token}, SetOptions(merge: true));
    } catch (e) {}
  }

  Future<void> _storePendingToken(String token) async {
    try {
      await FirebaseFirestore.instance
          .collection('pending_tokens')
          .doc(token)
          .set({
        'token': token,
        'createdAt': FieldValue.serverTimestamp(),
        'associated': false,
      }, SetOptions(merge: true));
    } catch (e) {}
  }

  // ─── MESSAGE HANDLERS ────────────────────────────────────────────────────
  Future<void> _handleForegroundMessage(
      firebase_messaging.RemoteMessage message) async {}

  static Future<void> _handleBackgroundMessage(
      firebase_messaging.RemoteMessage message) async {
    try {
      await Firebase.initializeApp();
      final title = message.data['title'] ?? message.notification?.title ?? '';
      final body = message.data['body'] ?? message.notification?.body ?? '';

      if (title.isNotEmpty || body.isNotEmpty) {
        final NotificationService service = NotificationService();
        await service._showNotification(
          title: title,
          body: body,
          data: message.data,
        );
      }
    } catch (e) {}
  }

  Future<void> _showNotification({
    required String? title,
    required String? body,
    required Map<String, dynamic> data,
  }) async {
    const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'default',
      categoryIdentifier: 'ratedly_actions',
      threadIdentifier: 'ratedly_notifications',
    );

    final notificationId = _getNotificationId();
    final finalTitle = title ?? data['title'] ?? 'New Activity';
    final finalBody = body ?? data['body'] ?? 'You have new activity';

    await _notifications.show(
      notificationId,
      finalTitle,
      finalBody,
      const NotificationDetails(iOS: iosDetails),
      payload: jsonEncode(data),
    );
  }

  // ─── TRIGGER SERVER NOTIFICATION ─────────────────────────────────────────
  Future<void> triggerServerNotification({
    required String type,
    required String targetUserId,
    String? title,
    String? body,
    Map<String, dynamic>? customData,
  }) async {
    try {
      final notificationData = {
        'type': type,
        'targetUserId': targetUserId,
        'title': title ?? 'New Notification',
        'body': body ?? 'You have a new notification',
        'customData': customData ?? {},
        'createdAt': FieldValue.serverTimestamp(),
      };

      await FirebaseFirestore.instance
          .collection('Push Not')
          .add(notificationData);
    } catch (e) {}
  }
}

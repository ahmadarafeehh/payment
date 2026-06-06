import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart'
    as firebase_messaging;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:Ratedly/services/notification_navigation_handler.dart';

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

      // Foreground messages → do nothing (no local notification)
      firebase_messaging.FirebaseMessaging.onMessage
          .listen(_handleForegroundMessage);

      // Background → foreground tap: navigate directly to the linked post.
      firebase_messaging.FirebaseMessaging.onMessageOpenedApp
          .listen(_handleNotificationTap);

      await _handleTokenRetrieval();

      _firebaseMessaging.onTokenRefresh.listen((newToken) async {
        await _saveToken(newToken);
      });

      // ── Cold-start: app was fully terminated and launched by a notification tap.
      //
      // FIX: Previously, storePendingNavigation() was called here but
      // executePendingNavigation() was only called from the postFrameCallback
      // in _OptimizedMyAppState.initState(), which fires BEFORE getInitialMessage()
      // resolves. The result was that _pendingData was always null at that point
      // and the cold-start tap was silently discarded.
      //
      // Fix: call executePendingNavigation() immediately after storing the data.
      // By the time getInitialMessage() completes (it is an async Firebase I/O
      // call), _OptimizedMyApp has already rendered and notificationNavigatorKey
      // is attached to the MaterialApp, so the push succeeds.
      // The postFrameCallback in _OptimizedMyApp is kept as a harmless fallback
      // (it becomes a no-op because _pendingData is cleared on first consumption).
      final initialMessage = await firebase_messaging
          .FirebaseMessaging.instance
          .getInitialMessage();
      if (initialMessage != null) {
        NotificationNavigationHandler.storePendingNavigation(
          Map<String, dynamic>.from(initialMessage.data),
        );
        // ✅ FIX: execute here, not only in the postFrameCallback.
        await NotificationNavigationHandler.executePendingNavigation();
      }

      const DarwinInitializationSettings initializationSettingsIOS =
          DarwinInitializationSettings();

      await _notifications.initialize(
        InitializationSettings(iOS: initializationSettingsIOS),
        onDidReceiveNotificationResponse:
            (NotificationResponse response) async {
          if (response.payload != null) {
            try {
              final data =
                  jsonDecode(response.payload!) as Map<String, dynamic>;
              await NotificationNavigationHandler.handleNotificationData(data);
            } catch (_) {}
          }
        },
      );

      await _configureNotificationChannels();
      _setupAuthListener();
    } catch (e) {}
  }

  // ─── NOTIFICATION TAP (background → foreground) ──────────────────────────
  Future<void> _handleNotificationTap(
      firebase_messaging.RemoteMessage message) async {
    await NotificationNavigationHandler.handleNotificationData(
      Map<String, dynamic>.from(message.data),
    );
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
  /// Always saves by the `uid` column (text primary key), which is
  /// always populated for every user — both Firebase and Supabase auth users.
  Future<void> _saveTokenToSupabase(String token) async {
    try {
      final supabase = Supabase.instance.client;
      final firebaseUser = firebase_auth.FirebaseAuth.instance.currentUser;
      final supabaseUser = supabase.auth.currentUser;

      // ── Firebase auth user ───────────────────────────────────────────────
      if (firebaseUser != null) {
        await supabase
            .from('users')
            .update({'fcmToken': token}).eq('uid', firebaseUser.uid);
        return;
      }

      // ── Supabase auth user ───────────────────────────────────────────────
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

  /// Foreground message: do nothing (no local notification shown).
  Future<void> _handleForegroundMessage(
      firebase_messaging.RemoteMessage message) async {}

  /// Background / terminated message handler (registered in main.dart via
  /// FirebaseMessaging.onBackgroundMessage). Shows a local notification so
  /// the user can later tap it to navigate.
  static Future<void> handleBackgroundMessage(
      firebase_messaging.RemoteMessage message) async {
    try {
      await Firebase.initializeApp();
      final title =
          message.data['title'] ?? message.notification?.title ?? '';
      final body = message.data['body'] ?? message.notification?.body ?? '';

      if (title.isNotEmpty || body.isNotEmpty) {
        final service = NotificationService();
        await service._showNotification(
          title: title,
          body: body,
          data: message.data,
        );
      }
    } catch (_) {}
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
      // Payload carries the full FCM data map so the tap handler can navigate.
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

  // ─── READ RECEIPTS ───────────────────────────────────────────────────────
  static Future<void> markNotificationsAsRead(String userId) async {
    try {
      final supabase = Supabase.instance.client;
      await supabase
          .from('notifications')
          .update({'is_read': true})
          .eq('target_user_id', userId)
          .eq('is_read', false);
    } catch (e) {
      rethrow;
    }
  }
}

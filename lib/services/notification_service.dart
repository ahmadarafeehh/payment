import 'dart:convert';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart'
    as firebase_messaging;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_auth/firebase_auth.dart' as firebase_auth;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:flutter/material.dart';
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

  // ─── COLD START ──────────────────────────────────────────────────────────
  static Future<void> handleColdStart() async {
    try {
      final initialMessage = await firebase_messaging.FirebaseMessaging.instance
          .getInitialMessage();
      if (initialMessage == null) return;

      final data = Map<String, dynamic>.from(initialMessage.data);

      NotificationNavigationHandler.storePendingNavigation(data);
      await NotificationNavigationHandler.prefetchNavigationData(data);
    } catch (e, st) {
      // Log cold-start failures so we know if getInitialMessage itself throws.
      await NotificationNavigationHandler.logEvent(
        eventType: 'cold_start_error',
        errorMessage: e.toString(),
        additionalData: {'stack_trace': st.toString()},
      );
    }
  }

  // ─── INIT ────────────────────────────────────────────────────────────────
  Future<void> init() async {
    try {
      final settings = await _firebaseMessaging.requestPermission(
        alert: true,
        badge: true,
        criticalAlert: true,
        provisional: true,
        sound: true,
      );

      // Log the permission outcome so we can diagnose delivery issues
      // where the user may have denied permissions.
      await NotificationNavigationHandler.logEvent(
        eventType: 'notification_permission_result',
        additionalData: {
          'authorization_status': settings.authorizationStatus.name,
          'alert': settings.alert.name,
          'badge': settings.badge.name,
          'sound': settings.sound.name,
        },
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
          .listen(_handleNotificationTap);

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
              final data =
                  jsonDecode(response.payload!) as Map<String, dynamic>;
              await NotificationNavigationHandler.handleNotificationData(data);
            } catch (e) {
              await NotificationNavigationHandler.logEvent(
                eventType: 'local_notification_payload_parse_error',
                errorMessage: e.toString(),
                additionalData: {'raw_payload': response.payload},
              );
            }
          }
        },
      );

      await _configureNotificationChannels();
      _setupAuthListener();
    } catch (e, st) {
      await NotificationNavigationHandler.logEvent(
        eventType: 'notification_service_init_error',
        errorMessage: e.toString(),
        additionalData: {'stack_trace': st.toString()},
      );
    }
  }

  // ─── NOTIFICATION TAP (background → foreground) ──────────────────────────
  Future<void> _handleNotificationTap(
      firebase_messaging.RemoteMessage message) async {
    await NotificationNavigationHandler.handleNotificationData(
      Map<String, dynamic>.from(message.data),
    );
  }

  // ─── FOREGROUND MESSAGE ──────────────────────────────────────────────────
  /// We intentionally don't show a local notification for foreground messages,
  /// but we do log receipt so we know the message arrived and can compare
  /// against the notifications table.
  Future<void> _handleForegroundMessage(
      firebase_messaging.RemoteMessage message) async {
    await NotificationNavigationHandler.logEvent(
      eventType: 'foreground_message_received',
      notificationType: message.data['type']?.toString(),
      rawData: Map<String, dynamic>.from(message.data),
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

  Future<void> _saveTokenToSupabase(String token) async {
    try {
      final supabase = Supabase.instance.client;
      final firebaseUser = firebase_auth.FirebaseAuth.instance.currentUser;
      final supabaseUser = supabase.auth.currentUser;

      if (firebaseUser != null) {
        await supabase
            .from('users')
            .update({'fcmToken': token}).eq('uid', firebaseUser.uid);
        return;
      }

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
      if (user == null) return;

      await user.reload();
      if (!user.emailVerified) return;

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

  // ─── BACKGROUND MESSAGE HANDLER ──────────────────────────────────────────
  /// Runs when the app is terminated and a message arrives. Supabase is not
  /// initialized here, so we can't write to notification_tap_logs. The local
  /// notification shown here will produce a tap_received log via
  /// onDidReceiveNotificationResponse when the user taps it.
  static Future<void> handleBackgroundMessage(
      firebase_messaging.RemoteMessage message) async {
    try {
      await Firebase.initializeApp();

      final type = message.data['type']?.toString() ?? 'unknown';
      final title = message.data['title'] ?? message.notification?.title ?? '';
      final body = message.data['body'] ?? message.notification?.body ?? '';

      debugPrint(
        '[NotifBG] Background message received — type=$type '
        'title="$title" messageId=${message.messageId}',
      );

      if (title.isNotEmpty || body.isNotEmpty) {
        final service = NotificationService();
        await service._showNotification(
          title: title,
          body: body,
          data: message.data,
        );
      } else {
        debugPrint(
            '[NotifBG] Skipped local notification — title and body both empty');
      }
    } catch (e, st) {
      ('[NotifBG] handleBackgroundMessage error: $e\n$st');
    }
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
    final logData = <String, dynamic>{
      'type': type,
      'targetUserId': targetUserId,
      'title': title,
      'customData': customData ?? {},
    };

    // Log before the Firestore write so we have a record even if the write fails.
    await NotificationNavigationHandler.logEvent(
      eventType: 'notification_queued',
      notificationType: type,
      rawData: logData,
    );

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

      // Confirm the Firestore doc was created and the Cloud Function will pick it up.
      await NotificationNavigationHandler.logEvent(
        eventType: 'notification_queued_success',
        notificationType: type,
        rawData: logData,
      );
    } catch (e, st) {
      // Log failures so we know when notifications are silently dropped.
      await NotificationNavigationHandler.logEvent(
        eventType: 'notification_queue_error',
        notificationType: type,
        rawData: logData,
        errorMessage: e.toString(),
        additionalData: {'stack_trace': st.toString()},
      );
    }
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

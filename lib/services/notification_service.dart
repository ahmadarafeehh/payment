import 'dart:convert';
import 'dart:io' show Platform;
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

  static String get _platformName {
    try {
      if (Platform.isIOS) return 'ios';
      if (Platform.isAndroid) return 'android';
      return Platform.operatingSystem;
    } catch (_) {
      return 'unknown';
    }
  }

  static String? get _osVersion {
    try {
      return Platform.operatingSystemVersion;
    } catch (_) {
      return null;
    }
  }

  // ─── CENTRAL DIAGNOSTIC LOGGER ───────────────────────────────────────────
  /// Writes a row to `notification_errors`. Used for BOTH real errors
  /// (severity: 'error') and success/diagnostic breadcrumbs
  /// (severity: 'info') so we can see, per platform, exactly how far a
  /// notification got through init / token retrieval / foreground receipt /
  /// local display — not just when something throws.
  ///
  /// This intentionally does NOT throw on failure (best-effort logging),
  /// and intentionally does NOT depend on Supabase auth state, so it can be
  /// called even very early in app startup or from the background isolate.
  static Future<void> _logNotificationEvent({
    required String eventType,
    String severity = 'error',
    String? targetUserId,
    String? errorMessage,
    String? errorCode,
    StackTrace? stackTrace,
    String? notificationType,
    String? title,
    String? body,
    String? appStage,
    Map<String, dynamic>? additionalData,
  }) async {
    try {
      final supabase = Supabase.instance.client;

      // Best-effort resolution of the current user id if one wasn't passed
      // in explicitly — helps attribute init-time/background events that
      // happen before a caller has a uid handy.
      String? resolvedUserId = targetUserId;
      if (resolvedUserId == null) {
        try {
          resolvedUserId = firebase_auth.FirebaseAuth.instance.currentUser?.uid ??
              Supabase.instance.client.auth.currentUser?.id;
        } catch (_) {
          // ignore — resolvedUserId stays null
        }
      }

      await supabase.from('notification_errors').insert({
        'target_user_id': resolvedUserId,
        'platform': _platformName,
        'os_version': _osVersion,
        'app_stage': appStage ?? 'unknown',
        'event_type': eventType,
        'severity': severity,
        'error_message': errorMessage,
        'error_code': errorCode,
        'stack_trace': stackTrace?.toString(),
        'notification_type': notificationType,
        'title': title,
        'body': body,
        'additional_data': additionalData ?? {},
      });
    } catch (e) {
      // Last resort — don't let logging itself crash anything. Fall back
      // to debugPrint so it's at least visible in device/console logs.
      debugPrint('[NotifErrorLog] failed to write notification_errors: $e');
    }
  }

  // ─── COLD START ──────────────────────────────────────────────────────────
  /// Call this from main() BEFORE runApp() to capture taps on notifications
  /// that launched the app from a terminated state.
  static Future<void> handleColdStart() async {
    try {
      final initialMessage = await firebase_messaging.FirebaseMessaging.instance
          .getInitialMessage();
      if (initialMessage == null) return;

      final data = Map<String, dynamic>.from(initialMessage.data);

      await _logNotificationEvent(
        eventType: 'cold_start_message_received',
        severity: 'info',
        appStage: 'terminated',
        targetUserId: data['targetUserId']?.toString(),
        notificationType: data['type']?.toString(),
        additionalData: {'raw_data': data, 'messageId': initialMessage.messageId},
      );

      NotificationNavigationHandler.storePendingNavigation(data);
      await NotificationNavigationHandler.prefetchNavigationData(data);
    } catch (e, st) {
      // Log cold-start failures so we know if getInitialMessage itself throws.
      await NotificationNavigationHandler.logEvent(
        eventType: 'cold_start_error',
        errorMessage: e.toString(),
        additionalData: {'stack_trace': st.toString()},
      );
      await _logNotificationEvent(
        eventType: 'cold_start_error',
        appStage: 'terminated',
        errorMessage: e.toString(),
        stackTrace: st,
      );
    }
  }

  // ─── WARM START (background → foreground) ────────────────────────────────
  /// Call this from main() BEFORE runApp() so the listener is registered
  /// immediately — before the app is fully built. This prevents the
  /// onMessageOpenedApp event from firing into the void before init() runs.
  ///
  /// Previously this was registered inside init(), which caused a race
  /// condition: iOS resumes the app and fires the event before init() has
  /// finished registering the listener, so the tap was silently lost and
  /// the user landed on the default feed screen instead of the target post.
  static void registerWarmStartListener() {
    firebase_messaging.FirebaseMessaging.onMessageOpenedApp
        .listen((firebase_messaging.RemoteMessage message) async {
      final data = Map<String, dynamic>.from(message.data);

      await _logNotificationEvent(
        eventType: 'warm_start_message_opened',
        severity: 'info',
        appStage: 'background',
        targetUserId: data['targetUserId']?.toString(),
        notificationType: data['type']?.toString(),
        additionalData: {'raw_data': data, 'messageId': message.messageId},
      );

      // Mirror the cold-start pattern: store pending navigation immediately
      // and prefetch data in the background. executePendingNavigation() will
      // be called later, once the navigator is mounted and ready.
      NotificationNavigationHandler.storePendingNavigation(data);
      await NotificationNavigationHandler.prefetchNavigationData(data);
    }, onError: (e, st) async {
      await _logNotificationEvent(
        eventType: 'warm_start_listener_error',
        appStage: 'background',
        errorMessage: e.toString(),
        stackTrace: st is StackTrace ? st : null,
      );
    });
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

      await _logNotificationEvent(
        eventType: 'notification_permission_result',
        severity: 'info',
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

      // ✅ REMOVED: onMessageOpenedApp listener is no longer registered here.
      // It is now registered in main() via registerWarmStartListener() so it
      // is guaranteed to be attached before the app renders — eliminating the
      // race condition where the tap event fired before this line was reached.

      await _handleTokenRetrieval();

      _firebaseMessaging.onTokenRefresh.listen((newToken) async {
        await _saveToken(newToken);
      });

      // ── LOCAL NOTIFICATIONS PLUGIN INIT ─────────────────────────────────
      // FIX: previously only `iOS:` was supplied here, which throws
      // "Android settings must be set when targeting Android platform" on
      // every Android launch. Both platforms are now configured.
      const DarwinInitializationSettings initializationSettingsIOS =
          DarwinInitializationSettings();

      const AndroidInitializationSettings initializationSettingsAndroid =
          AndroidInitializationSettings('@mipmap/ic_launcher');

      await _notifications.initialize(
        const InitializationSettings(
          iOS: initializationSettingsIOS,
          android: initializationSettingsAndroid,
        ),
        onDidReceiveNotificationResponse:
            (NotificationResponse response) async {
          await _logNotificationEvent(
            eventType: 'local_notification_tapped',
            severity: 'info',
            additionalData: {
              'payload': response.payload,
              'notification_response_type': response.notificationResponseType.name,
              'action_id': response.actionId,
            },
          );

          if (response.payload != null) {
            try {
              final data =
                  jsonDecode(response.payload!) as Map<String, dynamic>;
              await NotificationNavigationHandler.handleNotificationData(data);
            } catch (e, st) {
              await NotificationNavigationHandler.logEvent(
                eventType: 'local_notification_payload_parse_error',
                errorMessage: e.toString(),
                additionalData: {'raw_payload': response.payload},
              );
              await _logNotificationEvent(
                eventType: 'local_notification_payload_parse_error',
                errorMessage: e.toString(),
                stackTrace: st,
                additionalData: {'raw_payload': response.payload},
              );
            }
          }
        },
      );

      await _logNotificationEvent(
        eventType: 'notification_service_init_success',
        severity: 'info',
      );

      await _configureNotificationChannels();
      _setupAuthListener();
    } catch (e, st) {
      await NotificationNavigationHandler.logEvent(
        eventType: 'notification_service_init_error',
        errorMessage: e.toString(),
        additionalData: {'stack_trace': st.toString()},
      );
      await _logNotificationEvent(
        eventType: 'notification_service_init_error',
        errorMessage: e.toString(),
        errorCode: e.runtimeType.toString(),
        stackTrace: st,
      );
    }
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

    await _logNotificationEvent(
      eventType: 'foreground_message_received',
      severity: 'info',
      appStage: 'foreground',
      targetUserId: message.data['targetUserId']?.toString(),
      notificationType: message.data['type']?.toString(),
      title: message.notification?.title ?? message.data['title']?.toString(),
      body: message.notification?.body ?? message.data['body']?.toString(),
      additionalData: {
        'raw_data': message.data,
        'messageId': message.messageId,
        'has_notification_payload': message.notification != null,
        'sent_time': message.sentTime?.toIso8601String(),
        'ttl': message.ttl,
      },
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
    }, onError: (e, st) async {
      await _logNotificationEvent(
        eventType: 'auth_listener_error',
        errorMessage: e.toString(),
        stackTrace: st is StackTrace ? st : null,
      );
    });
  }

  // ─── TOKEN RETRIEVAL ─────────────────────────────────────────────────────
  Future<void> _handleTokenRetrieval() async {
    try {
      final token = await _firebaseMessaging.getToken();
      if (token != null) {
        await _saveToken(token);
        await _logNotificationEvent(
          eventType: 'token_retrieval_success',
          severity: 'info',
          additionalData: {'token_suffix': _tokenSuffix(token)},
        );
      } else {
        await _logNotificationEvent(
          eventType: 'token_retrieval_null',
          severity: 'error',
          errorMessage: 'FirebaseMessaging.getToken() returned null',
        );
      }
    } catch (e, st) {
      await _logNotificationEvent(
        eventType: 'token_retrieval_error',
        errorMessage: e.toString(),
        stackTrace: st,
      );
    }
  }

  /// Last 8 chars only — enough to tell tokens apart in logs without
  /// storing a full, sensitive FCM token in a diagnostics table.
  String _tokenSuffix(String token) =>
      token.length > 8 ? token.substring(token.length - 8) : token;

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

      // Explicit Android notification channel — required on Android 8+
      // for local notifications to display at all. Without this, `.show()`
      // calls can silently fail to appear even once `.initialize()` is
      // fixed, because no channel exists for the system to route them to.
      final androidPlugin = _notifications.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      if (androidPlugin != null) {
        const androidChannel = AndroidNotificationChannel(
          'ratedly_default_channel',
          'Ratedly Notifications',
          description: 'Default channel for Ratedly notifications',
          importance: Importance.high,
        );
        await androidPlugin.createNotificationChannel(androidChannel);
      }

      await _logNotificationEvent(
        eventType: 'notification_channels_configured',
        severity: 'info',
      );
    } catch (e, st) {
      await _logNotificationEvent(
        eventType: 'notification_channels_configure_error',
        errorMessage: e.toString(),
        stackTrace: st,
      );
    }
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
    } catch (e, st) {
      await _logNotificationEvent(
        eventType: 'save_token_supabase_error',
        errorMessage: e.toString(),
        stackTrace: st,
        additionalData: {'token_suffix': _tokenSuffix(token)},
      );
    }
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
    } catch (e, st) {
      await _logNotificationEvent(
        eventType: 'save_token_firestore_error',
        errorMessage: e.toString(),
        stackTrace: st,
        additionalData: {'token_suffix': _tokenSuffix(token)},
      );
    }
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
    } catch (e, st) {
      await _logNotificationEvent(
        eventType: 'store_pending_token_error',
        errorMessage: e.toString(),
        stackTrace: st,
        additionalData: {'token_suffix': _tokenSuffix(token)},
      );
    }
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

      await _logNotificationEvent(
        eventType: 'background_message_received',
        severity: 'info',
        appStage: 'background_or_terminated',
        targetUserId: message.data['targetUserId']?.toString(),
        notificationType: type,
        title: title,
        body: body,
        additionalData: {
          'raw_data': message.data,
          'messageId': message.messageId,
          'has_notification_payload': message.notification != null,
        },
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
        await _logNotificationEvent(
          eventType: 'background_message_skipped_empty',
          severity: 'info',
          appStage: 'background_or_terminated',
          targetUserId: message.data['targetUserId']?.toString(),
          notificationType: type,
        );
      }
    } catch (e, st) {
      debugPrint('[NotifBG] handleBackgroundMessage error: $e\n$st');
      await _logNotificationEvent(
        eventType: 'background_message_handler_error',
        appStage: 'background_or_terminated',
        errorMessage: e.toString(),
        stackTrace: st,
        targetUserId: message.data['targetUserId']?.toString(),
      );
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

    // FIX: previously only `iOS:` NotificationDetails were built, so this
    // call had the same "no android settings" gap as init() — on Android
    // this is expected to fail (or no-op) if it's ever actually reached.
    const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
      'ratedly_default_channel',
      'Ratedly Notifications',
      channelDescription: 'Default channel for Ratedly notifications',
      importance: Importance.high,
      priority: Priority.high,
    );

    final notificationId = _getNotificationId();
    final finalTitle = title ?? data['title'] ?? 'New Activity';
    final finalBody = body ?? data['body'] ?? 'You have new activity';

    try {
      await _notifications.show(
        notificationId,
        finalTitle,
        finalBody,
        const NotificationDetails(iOS: iosDetails, android: androidDetails),
        payload: jsonEncode(data),
      );

      await _logNotificationEvent(
        eventType: 'local_notification_show_success',
        severity: 'info',
        appStage: 'background_or_terminated',
        targetUserId: data['targetUserId']?.toString(),
        notificationType: data['type']?.toString(),
        title: finalTitle,
        body: finalBody,
        additionalData: {'notification_id': notificationId},
      );
    } catch (e, st) {
      await _logNotificationEvent(
        eventType: 'local_notification_show_error',
        appStage: 'background_or_terminated',
        errorMessage: e.toString(),
        stackTrace: st,
        targetUserId: data['targetUserId']?.toString(),
        notificationType: data['type']?.toString(),
        title: finalTitle,
        body: finalBody,
        additionalData: {'notification_id': notificationId},
      );
    }
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
      await _logNotificationEvent(
        eventType: 'notification_queue_error',
        targetUserId: targetUserId,
        notificationType: type,
        title: title,
        body: body,
        errorMessage: e.toString(),
        stackTrace: st,
        additionalData: {'customData': customData ?? {}},
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

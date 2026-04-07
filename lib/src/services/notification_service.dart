import 'dart:developer' as dev;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Top-level handler for background messages (must be top-level function).
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp();
  dev.log(
    'Background message: ${message.messageId}',
    name: 'NotificationService',
  );
}

/// Standalone push-notification infrastructure.
///
/// Call [initialize] once after Supabase is ready.
/// No game logic, no triggers — pure plumbing.
class NotificationService {
  static final NotificationService _instance = NotificationService._();
  factory NotificationService() => _instance;
  NotificationService._();

  final _messaging = FirebaseMessaging.instance;
  final _localNotifications = FlutterLocalNotificationsPlugin();
  String? _fcmToken;

  /// Current FCM token (null until [initialize] completes).
  String? get fcmToken => _fcmToken;

  // ── Public API ──────────────────────────────────────────────────────────

  /// Initialise Firebase, request permission, grab the FCM token, and wire
  /// foreground / background handlers. Fails silently.
  Future<void> initialize() async {
    try {
      await Firebase.initializeApp();
      await _requestPermission();
      await _fetchToken();
      setupHandlers();
    } catch (e, st) {
      dev.log(
        'initialize failed: $e',
        name: 'NotificationService',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Persist the FCM token to Supabase `player_devices`.
  /// Call this after the user has signed in (anonymous or otherwise).
  Future<void> storeToken(String playerId) async {
    if (_fcmToken == null) return;
    try {
      await Supabase.instance.client.from('player_devices').upsert(
        {
          'player_id': playerId,
          'fcm_token': _fcmToken,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        },
        onConflict: 'player_id',
      );
    } catch (e, st) {
      dev.log(
        'storeToken failed: $e',
        name: 'NotificationService',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Register foreground and background message handlers.
  /// Currently logs only — add routing / business logic later.
  void setupHandlers() {
    // Background (app terminated or in background).
    FirebaseMessaging.onBackgroundMessage(
      _firebaseMessagingBackgroundHandler,
    );

    // Foreground — show a local notification so user sees something.
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      dev.log(
        'Foreground message: ${message.messageId}',
        name: 'NotificationService',
      );
      _showLocalNotification(message);
    });

    // Tap on notification while app is in background (but not terminated).
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      dev.log(
        'Notification tap (background): ${message.messageId}',
        name: 'NotificationService',
      );
    });

    // Token refresh — will persist when storeToken is wired up.
    _messaging.onTokenRefresh.listen((newToken) {
      _fcmToken = newToken;
      dev.log(
        'FCM token refreshed',
        name: 'NotificationService',
      );
    });
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  Future<void> _requestPermission() async {
    final settings = await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
    dev.log(
      'Permission status: ${settings.authorizationStatus}',
      name: 'NotificationService',
    );
  }

  Future<void> _fetchToken() async {
    _fcmToken = await _messaging.getToken();
    dev.log(
      'FCM token: ${_fcmToken ?? 'null'}',
      name: 'NotificationService',
    );
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        'hextrail_default',
        'HexTrail',
        channelDescription: 'HexTrail notifications',
        importance: Importance.high,
        priority: Priority.high,
      );
      const darwinDetails = DarwinNotificationDetails();
      const details = NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
      );

      await _localNotifications.initialize(
        const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          iOS: DarwinInitializationSettings(),
        ),
      );

      await _localNotifications.show(
        notification.hashCode,
        notification.title,
        notification.body,
        details,
      );
    } catch (e, st) {
      dev.log(
        '_showLocalNotification failed: $e',
        name: 'NotificationService',
        error: e,
        stackTrace: st,
      );
    }
  }
}

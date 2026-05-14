import 'dart:developer' as dev;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../../core/feature_flags.dart';

/// Broadcast notifier for inbound `tile_lost` FCM messages so any UI
/// surface (currently the map screen) can react instantly without
/// coupling NotificationService to game state.
///
/// Value is the lowercase H3 hex ID of the tile we just lost.  Listeners
/// should treat the same value arriving twice as two distinct events
/// (use a counter or guard, see map_screen wire-up).  Top-level so
/// background isolates can also write to it (where supported).
final ValueNotifier<TileLostEvent?> tileLostEvents =
    ValueNotifier<TileLostEvent?>(null);

@immutable
class TileLostEvent {
  const TileLostEvent({required this.hexLower, required this.receivedAt});
  final String hexLower;
  final DateTime receivedAt;
}

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
  bool _localNotifInitialized = false;

  /// Current FCM token (null until [initialize] completes).
  String? get fcmToken => _fcmToken;

  // ── Public API ──────────────────────────────────────────────────────────

  /// Initialise Firebase, local notifications, and wire handlers.
  /// Does NOT request permission or fetch token — call
  /// [requestPermissionAndStore] for that after the user's first capture.
  /// Fails silently.
  Future<void> initialize() async {
    try {
      await Firebase.initializeApp();
      tz.initializeTimeZones();
      await _ensureLocalNotifInit();
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

  /// Request notification permission, fetch the FCM token, and persist it
  /// if a Supabase user is already signed in. Fails silently.
  Future<void> requestPermissionAndStore() async {
    try {
      await _requestPermission();
      await _fetchToken();
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        await storeToken(userId);
      }
    } catch (e, st) {
      dev.log(
        'requestPermissionAndStore failed: $e',
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
      await Supabase.instance.client.from('player_devices').upsert({
        'player_id': playerId,
        'fcm_token': _fcmToken,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      }, onConflict: 'player_id');
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
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Foreground — show a local notification so user sees something.
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      dev.log(
        'Foreground message: ${message.messageId}',
        name: 'NotificationService',
      );
      _handleDataPayload(message);
      _showLocalNotification(message);
    });

    // Tap on notification while app is in background (but not terminated).
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      dev.log(
        'Notification tap (background): ${message.messageId}',
        name: 'NotificationService',
      );
      // Re-emit so the cache invalidates the moment the user resumes the
      // app via the notification, even if they never went foreground while
      // the push arrived.  The next periodic refresh would also reconcile
      // (FeatureFlags.cacheReconciliationEnabled), but this gives instant
      // visual feedback on resume.
      _handleDataPayload(message);
    });

    // Token refresh — persist to Supabase so push delivery stays valid.
    _messaging.onTokenRefresh.listen((newToken) {
      _fcmToken = newToken;
      dev.log('FCM token refreshed', name: 'NotificationService');
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId != null) {
        storeToken(userId);
      }
    });

    // Auth-state changes — persist token whenever a session appears.
    // Covers the case where requestPermissionAndStore() ran at app launch
    // before anonymous sign-in had completed (so storeToken silently
    // no-op'd at that time).
    Supabase.instance.client.auth.onAuthStateChange.listen((data) {
      final userId = data.session?.user.id;
      if (userId != null && _fcmToken != null) {
        dev.log(
          'Auth state changed (uid=$userId) — persisting FCM token',
          name: 'NotificationService',
        );
        storeToken(userId);
      }
    });
  }

  // ── Private helpers ─────────────────────────────────────────────────────

  Future<void> _ensureLocalNotifInit() async {
    if (_localNotifInitialized) return;
    await _localNotifications.initialize(
      const InitializationSettings(
        android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        iOS: DarwinInitializationSettings(),
      ),
    );

    // Pre-register notification channels so background FCM deliveries and
    // scheduled local notifications land on configured channels (some
    // OEMs silence notifications routed to the unconfigured "Misc" channel).
    final androidImpl = _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        'hextrail_default',
        'HexTrail',
        description: 'HexTrail game notifications',
        importance: Importance.high,
      ),
    );
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        'hextrail_territory',
        'Territory Alerts',
        description: 'Tile capture and defense alerts',
        importance: Importance.high,
      ),
    );

    _localNotifInitialized = true;
  }

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

    // Android 13+ also requires POST_NOTIFICATIONS for the local-notification
    // plugin. firebase_messaging's requestPermission does not cover this for
    // local (non-FCM) notifications such as the scheduled "vulnerable" alert.
    try {
      await _ensureLocalNotifInit();
      final androidImpl = _localNotifications
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();
      if (androidImpl != null) {
        final granted = await androidImpl.requestNotificationsPermission();
        dev.log(
          'Android POST_NOTIFICATIONS granted: $granted',
          name: 'NotificationService',
        );
      }
    } catch (e) {
      dev.log(
        'Android local-notif permission request failed: $e',
        name: 'NotificationService',
      );
    }
  }

  Future<void> _fetchToken() async {
    _fcmToken = await _messaging.getToken();
    dev.log('FCM token: ${_fcmToken ?? 'null'}', name: 'NotificationService');
  }

  /// Parses the FCM `data` payload from the Edge Function (see
  /// `supabase/functions/notify-tile-event/index.ts`) which sends:
  ///   data: { event: 'tile_lost', hexId: '<lowercase-h3>' }
  /// and emits a [TileLostEvent] on [tileLostEvents] so the UI can
  /// invalidate the local cache instantly.  Pure plumbing — never throws.
  void _handleDataPayload(RemoteMessage message) {
    if (!FeatureFlags.fcmTileLostInvalidationEnabled) return;
    try {
      final hexLower = parseTileLostPayload(message.data);
      if (hexLower == null) return;
      tileLostEvents.value = TileLostEvent(
        hexLower: hexLower,
        receivedAt: DateTime.now(),
      );
      dev.log(
        'Emitted tile_lost event for $hexLower',
        name: 'NotificationService',
      );
    } catch (e, st) {
      dev.log(
        '_handleDataPayload failed (silently): $e',
        name: 'NotificationService',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Pure payload parser — accepts the FCM `data` map and returns the
  /// lowercase H3 hex ID iff this is a well-formed `tile_lost` event.
  /// Returns null for any other event type, missing/invalid hex, or
  /// malformed payload.  Never throws.  Exposed for unit tests.
  ///
  /// Edge function contract (see `supabase/functions/notify-tile-event`):
  ///   { event: 'tile_lost', hexId: '<lowercase-h3>' }
  /// Legacy keys `type` / `h3_hex` are also accepted for forward-compat.
  @visibleForTesting
  static String? parseTileLostPayload(Map<String, dynamic> data) {
    try {
      final event = (data['event'] ?? data['type'])?.toString();
      if (event != 'tile_lost') return null;
      final rawHex = (data['hexId'] ?? data['h3_hex'])?.toString();
      if (rawHex == null || rawHex.isEmpty) return null;
      final hexLower = rawHex.toLowerCase();
      if (!RegExp(r'^[0-9a-f]+$').hasMatch(hexLower)) return null;
      return hexLower;
    } catch (_) {
      return null;
    }
  }

  Future<void> _showLocalNotification(RemoteMessage message) async {
    final notification = message.notification;
    if (notification == null) return;
    try {
      await _ensureLocalNotifInit();

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

  // ── Gameplay notification triggers ──────────────────────────────────────

  /// Notify a previous tile owner that their tile was taken (via Edge Function).
  /// Fire-and-forget — never blocks gameplay.
  void notifyTileLost({
    required String previousOwnerId,
    required String h3Hex,
  }) {
    _notifyTileLostAsync(previousOwnerId, h3Hex);
  }

  Future<void> _notifyTileLostAsync(
    String previousOwnerId,
    String h3Hex,
  ) async {
    try {
      await Supabase.instance.client.functions.invoke(
        'notify-tile-event',
        body: {
          'type': 'tile_lost',
          'target_user_id': previousOwnerId,
          'h3_hex': h3Hex,
        },
      );
      dev.log(
        'notifyTileLost sent for $h3Hex → $previousOwnerId',
        name: 'NotificationService',
      );
    } catch (e) {
      dev.log('notifyTileLost failed: $e', name: 'NotificationService');
    }
  }

  /// Schedule a local "tile vulnerable" reminder at [protectedUntil].
  /// Uses a deterministic notification ID per hex so re-captures replace
  /// the previous reminder (anti-spam, once-per-protection-cycle).
  void scheduleVulnerableReminder({
    required String h3Hex,
    required DateTime protectedUntil,
  }) {
    _scheduleVulnerableAsync(h3Hex, protectedUntil);
  }

  Future<void> _scheduleVulnerableAsync(
    String h3Hex,
    DateTime protectedUntil,
  ) async {
    try {
      await _ensureLocalNotifInit();

      final notifId = h3Hex.hashCode.abs() % 2147483647;

      // Cancel any existing reminder for this hex.
      await _localNotifications.cancel(notifId);

      // Don't schedule if already past.
      if (!protectedUntil.isAfter(DateTime.now())) return;

      final scheduledDate = tz.TZDateTime.from(protectedUntil, tz.UTC);

      const androidDetails = AndroidNotificationDetails(
        'hextrail_territory',
        'Territory alerts',
        channelDescription: 'Tile protection and vulnerability alerts',
        importance: Importance.high,
        priority: Priority.high,
      );
      const darwinDetails = DarwinNotificationDetails();
      const details = NotificationDetails(
        android: androidDetails,
        iOS: darwinDetails,
      );

      await _localNotifications.zonedSchedule(
        notifId,
        'Hex vulnerable',
        'One of your hexes can now be taken. Refresh it on the trail.',
        scheduledDate,
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        matchDateTimeComponents: null,
      );

      dev.log(
        'Scheduled vulnerable reminder for $h3Hex at $protectedUntil (id=$notifId)',
        name: 'NotificationService',
      );
    } catch (e) {
      dev.log(
        'scheduleVulnerableReminder failed: $e',
        name: 'NotificationService',
      );
    }
  }
}

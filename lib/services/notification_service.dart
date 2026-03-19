import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:firebase_in_app_messaging/firebase_in_app_messaging.dart';
import 'package:firebase_analytics/firebase_analytics.dart';

/// A service to handle both local and remote (FCM) notifications.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();

  factory NotificationService() {
    return _instance;
  }

  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();
  
  final FirebaseMessaging _fcm = FirebaseMessaging.instance;
  final FirebaseInAppMessaging _fiam = FirebaseInAppMessaging.instance;

  // Stream for cancellation events from notifications
  final StreamController<int> _cancelDownloadController =
      StreamController<int>.broadcast();
  Stream<int> get onCancelDownload => _cancelDownloadController.stream;

  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;

    // 1. Initialize Local Notifications
    const AndroidInitializationSettings initializationSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');

    const InitializationSettings initializationSettings =
        InitializationSettings(android: initializationSettingsAndroid);

    await _notificationsPlugin.initialize(
      settings: initializationSettings,
      onDidReceiveNotificationResponse: (NotificationResponse response) {
        if (response.payload != null &&
            response.actionId == 'cancel_download') {
          final int? id = int.tryParse(response.payload!);
          if (id != null) {
            cancelDownload(id);
          }
        }
      },
    );

    // 2. Initialize FCM
    NotificationSettings settings = await _fcm.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    if (settings.authorizationStatus == AuthorizationStatus.authorized) {
      debugPrint('User granted notification permission');
    }

    // Handle Foreground Messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      debugPrint('FCM Foreground: ${message.notification?.title}');
      _showForegroundNotification(message);
    });

    // Handle Background Click (when app is opened from notification)
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
      debugPrint('FCM Clicked: ${message.notification?.title}');
      // Handle navigation here if needed
    });

    // 3. Initialize Firebase In-App Messaging
    await _fiam.setMessagesSuppressed(false);
    await _fiam.setAutomaticDataCollectionEnabled(true);
    debugPrint('✅ Firebase In-App Messaging Initialized');

    _isInitialized = true;
  }

  /// Triggers a Firebase In-App Messaging event.
  /// Use this to show a message based on a specific user action.
  Future<void> triggerInAppEvent(String eventName) async {
    debugPrint('🚀 Triggering In-App Event: $eventName (via Analytics)');
    await FirebaseAnalytics.instance.logEvent(name: eventName);
  }

  /// Manually suppress or allow In-App Message displays.
  Future<void> setInAppMessagingEnabled(bool enabled) async {
    await _fiam.setMessagesSuppressed(!enabled);
  }

  Future<String?> getFcmToken() async {
    if (!_isInitialized) await init();
    String? token = await _fcm.getToken();
    debugPrint('🚀 FCM Token: $token');
    return token;
  }

  void _showForegroundNotification(RemoteMessage message) {
    RemoteNotification? notification = message.notification;
    AndroidNotification? android = message.notification?.android;
    
    if (notification != null && android != null) {
      _notificationsPlugin.show(
        id: notification.hashCode,
        title: notification.title,
        body: notification.body,
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            'high_importance_channel',
            'High Importance Notifications',
            channelDescription: 'This channel is used for important notifications.',
            importance: Importance.max,
            priority: Priority.high,
          ),
        ),
      );
    }
  }

  /// Shows or updates a download progress notification.
  Future<void> showDownloadProgress({
    required int id,
    required String title,
    required int progress,
    required int maxProgress,
    String? subTitle,
  }) async {
    if (!_isInitialized) await init();

    final AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
          'download_channel',
          'Downloads',
          channelDescription: 'Notifications for file downloads',
          importance: Importance.low,
          priority: Priority.low,
          showProgress: true,
          maxProgress: maxProgress,
          progress: progress,
          onlyAlertOnce: true,
          ongoing: true,
          autoCancel: false,
          actions: <AndroidNotificationAction>[
            const AndroidNotificationAction(
              'cancel_download',
              'Stop',
              showsUserInterface: true,
              cancelNotification: true,
            ),
          ],
        );

    await _notificationsPlugin.show(
      id: id,
      title: 'Downloading Playlist',
      body: subTitle != null ? '$title - $subTitle' : title,
      notificationDetails: NotificationDetails(android: androidDetails),
      payload: id.toString(),
    );
  }

  void cancelDownload(int id) {
    _cancelDownloadController.add(id);
    clearNotification(id);
  }

  Future<void> clearNotification(int id) async {
    if (!_isInitialized) await init();
    await _notificationsPlugin.cancel(id: id);
  }

  void cancel(int id) => clearNotification(id);
  void clear(int id) => clearNotification(id);
}

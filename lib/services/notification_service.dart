import 'dart:async';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// A service to handle background notifications, especially for long-running
/// tasks like playlist downloads.
class NotificationService {
  static final NotificationService _instance = NotificationService._internal();

  factory NotificationService() {
    return _instance;
  }

  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  // Stream for cancellation events from notifications
  final StreamController<int> _cancelDownloadController =
      StreamController<int>.broadcast();
  Stream<int> get onCancelDownload => _cancelDownloadController.stream;

  bool _isInitialized = false;

  Future<void> init() async {
    if (_isInitialized) return;

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

    _isInitialized = true;
  }

  /// Shows or updates a download progress notification.
  ///
  /// [id] is a unique identifier for the notification.
  /// [title] is the title of the item being downloaded.
  /// [progress] is the current progress (0 to maxProgress).
  /// [maxProgress] is the total scale.
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

  /// Triggers a cancellation for a specific download job.
  void cancelDownload(int id) {
    _cancelDownloadController.add(id);
    clearNotification(id);
  }

  /// Clears a notification.
  Future<void> clearNotification(int id) async {
    if (!_isInitialized) await init();
    await _notificationsPlugin.cancel(id: id);
  }

  /// Alias for clearNotification to match usage
  void cancel(int id) => clearNotification(id);
  void clear(int id) => clearNotification(id);
}

import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'notification_service.dart';
import 'backup_service.dart';

class UserSyncService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final DeviceInfoPlugin _deviceInfo = DeviceInfoPlugin();
  final BackupService _backupService;

  UserSyncService(this._backupService);

  Future<void> syncUserInfo() async {
    // Overall timeout for the entire sync process to avoid blocking startup
    try {
      await _performSync().timeout(const Duration(seconds: 15));
    } catch (e) {
      debugPrint('SyncUserInfo timed out or failed: $e');
    }
  }

  Future<void> _performSync() async {
    try {
      final token = await NotificationService().getFcmToken();
      if (token == null) return;

      final packageInfo = await PackageInfo.fromPlatform();
      final deviceData = await _getDeviceInfo();
      final locationData = await _getLocationFromIp();

      final email = _backupService.currentUser?.email;

      // Target document: Users are keyed by their email if signed in, or by their unique device ID
      final docId =
          email ??
          deviceData['deviceId'] ??
          'unknown_device_${DateTime.now().millisecondsSinceEpoch}';

      await _firestore.collection('users').doc(docId).set({
        'fcmToken': token,
        'email': email,
        'lastActive': FieldValue.serverTimestamp(),
        'appVersion': packageInfo.version,
        'buildNumber': packageInfo.buildNumber,
        'platform': defaultTargetPlatform.name,
        'deviceModel': deviceData['model'],
        'deviceName': deviceData['name'],
        'osVersion': deviceData['osVersion'],
        'region': locationData['region'],
        'city': locationData['city'],
        'country': locationData['country'],
        'allFilters': [
          'platform_${defaultTargetPlatform.name}',
          'model_${deviceData['model']}',
          if (locationData['region'] != null)
            'region_${locationData['region']}',
          if (locationData['city'] != null) 'city_${locationData['city']}',
          if (email != null) 'email_$email',
        ],
      }, SetOptions(merge: true));

      // 🔄 Direct Firebase Messaging Topic Subscriptions (No Cloud Functions needed)
      // This allows the admin to send notifications to topics (e.g. topic_city_Milan) from the console.
      final topicsToJoin = [
        'platform_${defaultTargetPlatform.name}',
        'model_${deviceData['model']}',
        if (locationData['region'] != null) 'region_${locationData['region']}',
        if (locationData['city'] != null) 'city_${locationData['city']}',
      ];

      for (final topic in topicsToJoin) {
        // Sanitize for FCM: only [a-zA-Z0-9-_.~%]{1,900}
        final sanitized = topic.replaceAll(RegExp(r'[^a-zA-Z0-9-_.~%]'), '_');
        await FirebaseMessaging.instance.subscribeToTopic('topic_$sanitized');
      }

      debugPrint('User data synced and topics joined for $docId');
    } catch (e) {
      debugPrint('Error syncing user info: $e');
    }
  }

  Future<Map<String, String?>> _getDeviceInfo() async {
    String model = 'Unknown';
    String name = 'Unknown';
    String osVersion = 'Unknown';
    String? deviceId;

    if (defaultTargetPlatform == TargetPlatform.android) {
      final androidInfo = await _deviceInfo.androidInfo;
      model = androidInfo.model;
      name = androidInfo.device;
      osVersion = androidInfo.version.release;
      deviceId = androidInfo.id;
    } else if (defaultTargetPlatform == TargetPlatform.iOS) {
      final iosInfo = await _deviceInfo.iosInfo;
      model = iosInfo.utsname.machine;
      name = iosInfo.name;
      osVersion = iosInfo.systemVersion;
      deviceId = iosInfo.identifierForVendor;
    }

    return {
      'model': model,
      'name': name,
      'osVersion': osVersion,
      'deviceId': deviceId,
    };
  }

  Future<Map<String, String?>> _getLocationFromIp() async {
    try {
      // Using a free IP geolocation API (no GPS permission needed)
      final response = await http
          .get(Uri.parse('http://ip-api.com/json'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return {
          'country': data['country'],
          'region': data['regionName'],
          'city': data['city'],
        };
      }
    } catch (e) {
      debugPrint('Geolocation error: $e');
    }
    return {'country': null, 'region': null, 'city': null};
  }
}

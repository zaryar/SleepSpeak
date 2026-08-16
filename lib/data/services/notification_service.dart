import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  static const MethodChannel _nativeChannel =
      MethodChannel('com.sleeprecorder.app/foreground_service');

  static const int recordingNotificationId = 888;
  static const String channelId = 'sleep_recorder_channel';
  static const String channelName = 'Schlaf-Recorder Dienst';

  Future<void> init() async {
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const initSettings = InitializationSettings(android: androidSettings);

    await _notificationsPlugin.initialize(initSettings);

    final androidPlatformChannelSpecifics = const AndroidNotificationChannel(
      channelId,
      channelName,
      description: 'Benachrichtigung während der laufenden Schlafaufnahme',
      importance: Importance.low, // Silent foreground service notification
      playSound: false,
      enableVibration: false,
    );

    await _notificationsPlugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidPlatformChannelSpecifics);
  }

  Future<void> showRecordingNotification({required String durationText}) async {
    // Start native Android Foreground Service with type MICROPHONE to guarantee screen-off recording
    try {
      await _nativeChannel.invokeMethod('startService', {
        'title': 'Aufnahmedauer: $durationText (Tippen zum Stoppen)',
      });
    } catch (_) {}

    const androidDetails = AndroidNotificationDetails(
      channelId,
      channelName,
      channelDescription: 'Benachrichtigung während der laufenden Schlafaufnahme',
      importance: Importance.low,
      priority: Priority.low,
      ongoing: true,
      autoCancel: false,
      playSound: false,
      enableVibration: false,
      showWhen: true,
    );

    const notificationDetails = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      recordingNotificationId,
      '🌙 Schlaf-Recorder läuft',
      'Aufnahmedauer: $durationText (Tippen zum Stoppen)',
      notificationDetails,
    );
  }

  Future<void> cancelRecordingNotification() async {
    try {
      await _nativeChannel.invokeMethod('stopService');
    } catch (_) {}
    try {
      await _notificationsPlugin.cancel(recordingNotificationId);
    } catch (_) {}
  }
}

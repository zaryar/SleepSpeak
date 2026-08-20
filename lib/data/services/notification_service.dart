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

  static const int backupNotificationId = 999;
  static const String backupChannelId = 'backup_channel';
  static const String backupChannelName = 'Backup & Export';

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

    final backupChannelSpecifics = const AndroidNotificationChannel(
      backupChannelId,
      backupChannelName,
      description: 'Fortschrittsanzeige beim Erstellen von Backups',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
    );

    final androidPlugin = _notificationsPlugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

    await androidPlugin?.createNotificationChannel(androidPlatformChannelSpecifics);
    await androidPlugin?.createNotificationChannel(backupChannelSpecifics);
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

  Future<void> showBackupProgressNotification({
    required int progress,
    required int maxProgress,
    required String statusText,
  }) async {
    final androidDetails = AndroidNotificationDetails(
      backupChannelId,
      backupChannelName,
      channelDescription: 'Fortschrittsanzeige beim Erstellen von Backups',
      importance: Importance.low,
      priority: Priority.low,
      showProgress: true,
      maxProgress: maxProgress,
      progress: progress,
      ongoing: true,
      onlyAlertOnce: true,
      autoCancel: false,
      playSound: false,
      enableVibration: false,
    );

    final notificationDetails = NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
      backupNotificationId,
      '📦 Backup wird erstellt ($progress %)',
      statusText,
      notificationDetails,
    );
  }

  Future<void> cancelBackupNotification() async {
    try {
      await _notificationsPlugin.cancel(backupNotificationId);
    } catch (_) {}
  }
}

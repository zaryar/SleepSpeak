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
  static const int delayedTimerNotificationId = 777;
  static const String channelId = 'sleep_recorder_channel';
  static const String channelName = 'Schlaf-Recorder Dienst';

  static const int backupNotificationId = 999;
  static const String backupChannelId = 'backup_channel';
  static const String backupChannelName = 'Backup & Export';

  Future<void> init() async {
    try {
      const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwinSettings = DarwinInitializationSettings();
      const initSettings = InitializationSettings(
        android: androidSettings,
        iOS: darwinSettings,
        macOS: darwinSettings,
      );

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

      final aiChannelSpecifics = const AndroidNotificationChannel(
        aiChannelId,
        aiChannelName,
        description: 'Live-Fortschritt der KI-Analyse in der Benachrichtigungsleiste',
        importance: Importance.defaultImportance,
        playSound: true,
        enableVibration: true,
      );

      final androidPlugin = _notificationsPlugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

      await androidPlugin?.createNotificationChannel(androidPlatformChannelSpecifics);
      await androidPlugin?.createNotificationChannel(backupChannelSpecifics);
      await androidPlugin?.createNotificationChannel(aiChannelSpecifics);
    } catch (_) {}
  }

  bool _isNativeServiceStarted = false;

  Future<void> startRecordingNotification() async {
    try {
      await _nativeChannel.invokeMethod('startService', {
        'title': '🌙 Schlaf-Recorder läuft',
        'content': 'Aufnahme ist aktiv (Tippen zum Stoppen)',
        'isCountdown': false,
      });
      _isNativeServiceStarted = true;
    } catch (_) {
      _isNativeServiceStarted = false;
    }

    try {
      await _notificationsPlugin.cancel(delayedTimerNotificationId);
    } catch (_) {}

    // Only show fallback notification via plugin if native foreground service is not running
    if (!_isNativeServiceStarted) {
      try {
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
          usesChronometer: true,
        );

        const notificationDetails = NotificationDetails(android: androidDetails);

        await _notificationsPlugin.show(
          recordingNotificationId,
          '🌙 Schlaf-Recorder läuft',
          'Aufnahme ist aktiv (Tippen zum Stoppen)',
          notificationDetails,
        );
      } catch (_) {}
    }
  }

  Future<void> updateRecordingNotification({required String durationText}) async {
    // Native chronometer in SleepRecorderForegroundService updates automatically
  }

  Future<void> showDelayedTimerNotification({
    required int targetEpochMs,
    required String timeRemainingText,
    required String targetStartTime,
  }) async {
    try {
      await _nativeChannel.invokeMethod('startService', {
        'title': '⏳ Einschlaf-Timer aktiv',
        'content': 'Startet in $timeRemainingText (um $targetStartTime Uhr)',
        'isCountdown': true,
        'targetEpochMs': targetEpochMs,
      });
      _isNativeServiceStarted = true;
    } catch (_) {
      _isNativeServiceStarted = false;
    }

    if (!_isNativeServiceStarted) {
      try {
        const androidDetails = AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: 'Einschlaf-Timer vor dem Start der Schlafaufnahme',
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
          delayedTimerNotificationId,
          '⏳ Einschlaf-Timer aktiv',
          'Startet in $timeRemainingText (um $targetStartTime Uhr)',
          notificationDetails,
        );
      } catch (_) {}
    }
  }

  Future<void> cancelDelayedTimerNotification() async {
    try {
      await _nativeChannel.invokeMethod('stopService');
      _isNativeServiceStarted = false;
    } catch (_) {}
    try {
      await _notificationsPlugin.cancel(delayedTimerNotificationId);
    } catch (_) {}
  }

  Future<void> cancelRecordingNotification() async {
    try {
      await _nativeChannel.invokeMethod('stopService');
      _isNativeServiceStarted = false;
    } catch (_) {}
    try {
      await _notificationsPlugin.cancel(recordingNotificationId);
      await _notificationsPlugin.cancel(delayedTimerNotificationId);
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

  static const int aiNotificationId = 1002;
  static const String aiChannelId = 'sleep_recorder_ai_v2';
  static const String aiChannelName = 'KI-Geräuschanalyse';

  Future<void> startAiAnalysisNotification({
    required String title,
    required String content,
    required int progress,
    required int maxProgress,
  }) async {
    try {
      await _nativeChannel.invokeMethod('startAiService', {
        'title': title,
        'content': content,
        'progress': progress,
        'maxProgress': maxProgress,
      });
    } catch (_) {
      // Fallback via plugin
      try {
        final androidDetails = AndroidNotificationDetails(
          aiChannelId,
          aiChannelName,
          channelDescription: 'Live-Fortschritt der KI-Analyse in der Benachrichtigungsleiste',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          showProgress: true,
          maxProgress: maxProgress,
          progress: progress,
          ongoing: true,
          onlyAlertOnce: true,
          autoCancel: false,
          playSound: true,
          enableVibration: true,
        );
        await _notificationsPlugin.show(
          aiNotificationId,
          title,
          content,
          NotificationDetails(android: androidDetails),
        );
      } catch (_) {}
    }
  }

  Future<void> updateAiAnalysisNotification({
    required String title,
    required String content,
    required int progress,
    required int maxProgress,
  }) async {
    try {
      await _nativeChannel.invokeMethod('updateAiProgress', {
        'title': title,
        'content': content,
        'progress': progress,
        'maxProgress': maxProgress,
      });
    } catch (_) {
      try {
        final androidDetails = AndroidNotificationDetails(
          aiChannelId,
          aiChannelName,
          channelDescription: 'Live-Fortschritt der KI-Analyse in der Benachrichtigungsleiste',
          importance: Importance.defaultImportance,
          priority: Priority.defaultPriority,
          showProgress: true,
          maxProgress: maxProgress,
          progress: progress,
          ongoing: true,
          onlyAlertOnce: true,
          autoCancel: false,
          playSound: true,
          enableVibration: true,
        );
        await _notificationsPlugin.show(
          aiNotificationId,
          title,
          content,
          NotificationDetails(android: androidDetails),
        );
      } catch (_) {}
    }
  }

  Future<void> stopAiAnalysisNotification({
    String? completionTitle,
    String? completionContent,
  }) async {
    try {
      await _nativeChannel.invokeMethod('stopAiService', {
        if (completionTitle != null) 'completionTitle': completionTitle,
        if (completionContent != null) 'completionContent': completionContent,
      });
    } catch (_) {
      try {
        if (completionTitle != null) {
          final androidDetails = const AndroidNotificationDetails(
            aiChannelId,
            aiChannelName,
            channelDescription: 'Live-Fortschritt der KI-Analyse in der Benachrichtigungsleiste',
            importance: Importance.defaultImportance,
            priority: Priority.defaultPriority,
            ongoing: false,
            autoCancel: true,
            playSound: true,
            enableVibration: true,
          );
          await _notificationsPlugin.show(
            aiNotificationId,
            completionTitle,
            completionContent ?? '',
            NotificationDetails(android: androidDetails),
          );
        } else {
          await _notificationsPlugin.cancel(aiNotificationId);
        }
      } catch (_) {}
    }
  }
}

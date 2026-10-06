package com.sleeprecorder.sleep_recorder

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat

class SleepRecorderForegroundService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var isForegroundStarted = false
    private var isAiRunning = false
    private var isRecordingRunning = false

    companion object {
        private const val TAG = "SleepRecorderFGS"
        const val CHANNEL_ID = "sleep_recorder_service_channel"
        const val AI_CHANNEL_ID = "sleep_recorder_ai_v2"

        const val NOTIFICATION_ID = 1001
        const val AI_NOTIFICATION_ID = 1002

        const val ACTION_START = "ACTION_START"
        const val ACTION_STOP = "ACTION_STOP"
        const val EXTRA_TITLE = "EXTRA_TITLE"
        const val EXTRA_CONTENT = "EXTRA_CONTENT"
        const val EXTRA_IS_COUNTDOWN = "EXTRA_IS_COUNTDOWN"
        const val EXTRA_TARGET_EPOCH_MS = "EXTRA_TARGET_EPOCH_MS"

        const val ACTION_START_AI = "ACTION_START_AI"
        const val ACTION_UPDATE_AI = "ACTION_UPDATE_AI"
        const val ACTION_STOP_AI = "ACTION_STOP_AI"
        const val EXTRA_AI_TITLE = "EXTRA_AI_TITLE"
        const val EXTRA_AI_CONTENT = "EXTRA_AI_CONTENT"
        const val EXTRA_AI_PROGRESS = "EXTRA_AI_PROGRESS"
        const val EXTRA_AI_MAX_PROGRESS = "EXTRA_AI_MAX_PROGRESS"
        const val EXTRA_AI_COMPLETION_TITLE = "EXTRA_AI_COMPLETION_TITLE"
        const val EXTRA_AI_COMPLETION_CONTENT = "EXTRA_AI_COMPLETION_CONTENT"
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent == null) {
            checkAndStopIfIdle()
            return START_NOT_STICKY
        }

        when (intent.action) {
            ACTION_START -> handleRecordingStart(intent)
            ACTION_STOP -> handleRecordingStop()
            ACTION_START_AI -> handleAiStart(intent)
            ACTION_UPDATE_AI -> handleAiUpdate(intent)
            ACTION_STOP_AI -> handleAiStop(intent)
            else -> checkAndStopIfIdle()
        }

        return START_NOT_STICKY
    }

    private fun handleRecordingStart(intent: Intent) {
        val hasMicPermission = ContextCompat.checkSelfPermission(
            this,
            android.Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED

        if (!hasMicPermission) {
            Log.e(TAG, "Cannot start microphone foreground service: RECORD_AUDIO permission not granted")
            handleRecordingStop()
            return
        }

        val isCountdown = intent.getBooleanExtra(EXTRA_IS_COUNTDOWN, false)
        val defaultTitle = if (isCountdown) "⏳ Einschlaf-Timer aktiv" else "🌙 Schlaf-Recorder läuft"
        val defaultContent = if (isCountdown) "Timer läuft..." else "Aufnahme ist aktiv (Tippen zum Stoppen)"

        val title = intent.getStringExtra(EXTRA_TITLE) ?: defaultTitle
        val content = intent.getStringExtra(EXTRA_CONTENT) ?: defaultContent
        val targetEpochMs = intent.getLongExtra(EXTRA_TARGET_EPOCH_MS, 0L)

        val notification = buildRecordingNotification(title, content, isCountdown, targetEpochMs)
        try {
            if (!isForegroundStarted) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    startForeground(
                        NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    )
                } else {
                    startForeground(NOTIFICATION_ID, notification)
                }
                isForegroundStarted = true
            } else {
                val manager = getSystemService(NotificationManager::class.java)
                manager?.notify(NOTIFICATION_ID, notification)
            }
            isRecordingRunning = true
            acquireWakeLock(10 * 60 * 60 * 1000L) // 10h hold
        } catch (e: Exception) {
            Log.e(TAG, "Fatal startForeground exception for recording: ${e.message}", e)
        }
    }

    private fun handleRecordingStop() {
        isRecordingRunning = false
        val manager = getSystemService(NotificationManager::class.java)
        manager?.cancel(NOTIFICATION_ID)
        checkAndStopIfIdle()
    }

    private fun handleAiStart(intent: Intent) {
        val title = intent.getStringExtra(EXTRA_AI_TITLE) ?: "🤖 KI-Geräuschanalyse läuft"
        val content = intent.getStringExtra(EXTRA_AI_CONTENT) ?: "Initialisiere..."
        val progress = intent.getIntExtra(EXTRA_AI_PROGRESS, 0)
        val maxProgress = intent.getIntExtra(EXTRA_AI_MAX_PROGRESS, 100)

        val notification = buildAiNotification(title, content, progress, maxProgress, isOngoing = true)
        try {
            if (!isForegroundStarted) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    startForeground(
                        AI_NOTIFICATION_ID,
                        notification,
                        ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                    )
                } else {
                    startForeground(AI_NOTIFICATION_ID, notification)
                }
                isForegroundStarted = true
            } else {
                val manager = getSystemService(NotificationManager::class.java)
                manager?.notify(AI_NOTIFICATION_ID, notification)
            }
            isAiRunning = true
            acquireWakeLock(2 * 60 * 60 * 1000L) // 2h max hold for AI
        } catch (e: Exception) {
            Log.e(TAG, "Fatal startForeground exception for AI: ${e.message}", e)
        }
    }

    private fun handleAiUpdate(intent: Intent) {
        val title = intent.getStringExtra(EXTRA_AI_TITLE) ?: "🤖 KI-Geräuschanalyse läuft"
        val content = intent.getStringExtra(EXTRA_AI_CONTENT) ?: ""
        val progress = intent.getIntExtra(EXTRA_AI_PROGRESS, 0)
        val maxProgress = intent.getIntExtra(EXTRA_AI_MAX_PROGRESS, 100)

        val notification = buildAiNotification(title, content, progress, maxProgress, isOngoing = true)
        val manager = getSystemService(NotificationManager::class.java)
        manager?.notify(AI_NOTIFICATION_ID, notification)
    }

    private fun handleAiStop(intent: Intent) {
        isAiRunning = false
        val manager = getSystemService(NotificationManager::class.java)

        val completionTitle = intent.getStringExtra(EXTRA_AI_COMPLETION_TITLE)
        val completionContent = intent.getStringExtra(EXTRA_AI_COMPLETION_CONTENT)

        // Detach from foreground so the final completion notification is swipable
        if (isForegroundStarted && !isRecordingRunning) {
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                    stopForeground(STOP_FOREGROUND_DETACH)
                } else {
                    @Suppress("DEPRECATION")
                    stopForeground(false)
                }
            } catch (_: Exception) {}
            isForegroundStarted = false
        }

        if (completionTitle != null) {
            val doneNotification = buildAiNotification(
                completionTitle,
                completionContent ?: "Erfolgreich beendet",
                100,
                100,
                isOngoing = false
            )
            manager?.notify(AI_NOTIFICATION_ID, doneNotification)
        } else {
            manager?.cancel(AI_NOTIFICATION_ID)
        }

        checkAndStopIfIdle()
    }

    private fun buildRecordingNotification(
        contentTitle: String,
        contentText: String,
        isCountdown: Boolean,
        targetEpochMs: Long
    ): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = if (launchIntent != null) {
            PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        } else null

        val appIcon = applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.ic_btn_speak_now

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(contentTitle)
            .setContentText(contentText)
            .setSmallIcon(appIcon)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setShowWhen(true)

        if (isCountdown && targetEpochMs > System.currentTimeMillis()) {
            builder.setUsesChronometer(true)
                .setChronometerCountDown(true)
                .setWhen(targetEpochMs)
        } else {
            builder.setUsesChronometer(true)
                .setChronometerCountDown(false)
                .setWhen(System.currentTimeMillis())
        }

        if (pendingIntent != null) {
            builder.setContentIntent(pendingIntent)
        }

        return builder.build()
    }

    private fun buildAiNotification(
        contentTitle: String,
        contentText: String,
        progress: Int,
        maxProgress: Int,
        isOngoing: Boolean
    ): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = if (launchIntent != null) {
            PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        } else null

        val appIcon = applicationInfo.icon.takeIf { it != 0 } ?: android.R.drawable.stat_sys_upload

        val builder = NotificationCompat.Builder(this, AI_CHANNEL_ID)
            .setContentTitle(contentTitle)
            .setContentText(contentText)
            .setSmallIcon(appIcon)
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_PROGRESS)
            .setOnlyAlertOnce(true)

        if (isOngoing) {
            builder.setOngoing(true)
            builder.setAutoCancel(false)
            val validMax = if (maxProgress > 0) maxProgress else 100
            val validProgress = progress.coerceIn(0, validMax)
            builder.setProgress(validMax, validProgress, false)
        } else {
            builder.setOngoing(false)
            builder.setAutoCancel(true)
            builder.setProgress(0, 0, false)
        }

        if (pendingIntent != null) {
            builder.setContentIntent(pendingIntent)
        }

        val notification = builder.build()
        if (isOngoing) {
            notification.flags = notification.flags or Notification.FLAG_ONGOING_EVENT or Notification.FLAG_NO_CLEAR
        }
        return notification
    }

    private fun acquireWakeLock(timeoutMs: Long) {
        if (wakeLock == null) {
            try {
                val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                wakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "SleepRecorder::BackgroundActiveWakeLock"
                ).apply {
                    setReferenceCounted(false)
                    acquire(timeoutMs)
                }
                Log.d(TAG, "WakeLock acquired successfully.")
            } catch (e: Exception) {
                Log.w(TAG, "Could not acquire wakelock: ${e.message}")
            }
        }
    }

    private fun releaseWakeLock() {
        if (wakeLock?.isHeld == true) {
            try {
                wakeLock?.release()
            } catch (_: Exception) {}
        }
        wakeLock = null
    }

    private fun checkAndStopIfIdle() {
        if (!isRecordingRunning && !isAiRunning) {
            releaseWakeLock()
            isForegroundStarted = false
            try {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } catch (_: Exception) {}
            stopSelf()
        }
    }

    private fun createNotificationChannels() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val manager = getSystemService(NotificationManager::class.java)

            // Remove legacy silent channel if exists so fresh settings take effect
            try {
                manager?.deleteNotificationChannel("sleep_recorder_ai_channel")
            } catch (_: Exception) {}

            val recChannel = NotificationChannel(
                CHANNEL_ID,
                "Schlaf-Recorder Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Hält die Schlafaufnahme und den Einschlaf-Timer bei gesperrtem Bildschirm aktiv"
                setSound(null, null)
                enableVibration(false)
            }

            val defaultSoundUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
            val audioAttributes = AudioAttributes.Builder()
                .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                .build()

            val aiChannel = NotificationChannel(
                AI_CHANNEL_ID,
                "KI-Geräuschanalyse",
                NotificationManager.IMPORTANCE_DEFAULT
            ).apply {
                description = "Live-Fortschritt der KI-Analyse in der Benachrichtigungsleiste"
                setSound(defaultSoundUri, audioAttributes)
                enableVibration(true)
            }

            manager?.createNotificationChannel(recChannel)
            manager?.createNotificationChannel(aiChannel)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        releaseWakeLock()
        super.onDestroy()
    }
}

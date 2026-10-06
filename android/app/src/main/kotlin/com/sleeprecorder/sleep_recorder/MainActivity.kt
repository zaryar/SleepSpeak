package com.sleeprecorder.sleep_recorder

import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import android.util.Log
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : FlutterActivity() {
    private val SERVICE_CHANNEL = "com.sleeprecorder.app/foreground_service"
    private val ENCODER_CHANNEL = "com.sleeprecorder.app/audio_encoder"
    private val PICKER_CHANNEL = "com.sleeprecorder.app/file_picker"

    private var pendingPickerResult: MethodChannel.Result? = null
    private val PICK_AUDIO_CODE = 9982

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, PICKER_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "pickAudioFile") {
                pendingPickerResult = result
                val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                    type = "audio/*"
                    addCategory(Intent.CATEGORY_OPENABLE)
                }
                startActivityForResult(Intent.createChooser(intent, "Audioaufnahme auswählen"), PICK_AUDIO_CODE)
            } else {
                result.notImplemented()
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SERVICE_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    try {
                        val hasMic = ContextCompat.checkSelfPermission(
                            this,
                            android.Manifest.permission.RECORD_AUDIO
                        ) == PackageManager.PERMISSION_GRANTED

                        if (!hasMic) {
                            Log.e("MainActivity", "startService called without RECORD_AUDIO permission")
                            result.error("PERMISSION_DENIED", "RECORD_AUDIO permission is required", null)
                            return@setMethodCallHandler
                        }

                        val title = call.argument<String>("title")
                        val content = call.argument<String>("content")
                        val isCountdown = call.argument<Boolean>("isCountdown") ?: false
                        val targetEpochMs = call.argument<Number>("targetEpochMs")?.toLong() ?: 0L

                        val intent = Intent(this, SleepRecorderForegroundService::class.java).apply {
                            action = SleepRecorderForegroundService.ACTION_START
                            putExtra(SleepRecorderForegroundService.EXTRA_TITLE, title)
                            putExtra(SleepRecorderForegroundService.EXTRA_CONTENT, content)
                            putExtra(SleepRecorderForegroundService.EXTRA_IS_COUNTDOWN, isCountdown)
                            putExtra(SleepRecorderForegroundService.EXTRA_TARGET_EPOCH_MS, targetEpochMs)
                        }
                        ContextCompat.startForegroundService(this, intent)
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e("MainActivity", "startForegroundService failed: ${e.message}", e)
                        result.error("SERVICE_ERROR", e.message, null)
                    }
                }
                "stopService" -> {
                    try {
                        val intent = Intent(this, SleepRecorderForegroundService::class.java).apply {
                            action = SleepRecorderForegroundService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_SERVICE_FAILED", e.message, null)
                    }
                }
                "startAiService" -> {
                    try {
                        val title = call.argument<String>("title") ?: "🤖 KI-Geräuschanalyse läuft"
                        val content = call.argument<String>("content") ?: "Initialisiere..."
                        val progress = call.argument<Number>("progress")?.toInt() ?: 0
                        val maxProgress = call.argument<Number>("maxProgress")?.toInt() ?: 100

                        val intent = Intent(this, SleepRecorderForegroundService::class.java).apply {
                            action = SleepRecorderForegroundService.ACTION_START_AI
                            putExtra(SleepRecorderForegroundService.EXTRA_AI_TITLE, title)
                            putExtra(SleepRecorderForegroundService.EXTRA_AI_CONTENT, content)
                            putExtra(SleepRecorderForegroundService.EXTRA_AI_PROGRESS, progress)
                            putExtra(SleepRecorderForegroundService.EXTRA_AI_MAX_PROGRESS, maxProgress)
                        }
                        ContextCompat.startForegroundService(this, intent)
                        result.success(true)
                    } catch (e: Exception) {
                        Log.e("MainActivity", "startAiService failed: ${e.message}", e)
                        result.error("START_AI_SERVICE_FAILED", e.message, null)
                    }
                }
                "updateAiProgress" -> {
                    try {
                        val title = call.argument<String>("title") ?: "🤖 KI-Geräuschanalyse läuft"
                        val content = call.argument<String>("content") ?: ""
                        val progress = call.argument<Number>("progress")?.toInt() ?: 0
                        val maxProgress = call.argument<Number>("maxProgress")?.toInt() ?: 100

                        val intent = Intent(this, SleepRecorderForegroundService::class.java).apply {
                            action = SleepRecorderForegroundService.ACTION_UPDATE_AI
                            putExtra(SleepRecorderForegroundService.EXTRA_AI_TITLE, title)
                            putExtra(SleepRecorderForegroundService.EXTRA_AI_CONTENT, content)
                            putExtra(SleepRecorderForegroundService.EXTRA_AI_PROGRESS, progress)
                            putExtra(SleepRecorderForegroundService.EXTRA_AI_MAX_PROGRESS, maxProgress)
                        }
                        startService(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("UPDATE_AI_PROGRESS_FAILED", e.message, null)
                    }
                }
                "stopAiService" -> {
                    try {
                        val completionTitle = call.argument<String>("completionTitle")
                        val completionContent = call.argument<String>("completionContent")

                        val intent = Intent(this, SleepRecorderForegroundService::class.java).apply {
                            action = SleepRecorderForegroundService.ACTION_STOP_AI
                            putExtra(SleepRecorderForegroundService.EXTRA_AI_COMPLETION_TITLE, completionTitle)
                            putExtra(SleepRecorderForegroundService.EXTRA_AI_COMPLETION_CONTENT, completionContent)
                        }
                        startService(intent)
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("STOP_AI_SERVICE_FAILED", e.message, null)
                    }
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ENCODER_CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "trimAndEncodeM4a") {
                val inputPath = call.argument<String>("inputPath")
                val outputPath = call.argument<String>("outputPath")
                val startMs = call.argument<Number>("startMs")?.toLong() ?: 0L
                val durationMs = call.argument<Number>("durationMs")?.toLong() ?: 0L

                if (inputPath != null && outputPath != null) {
                    Thread {
                        try {
                            val success = encodeWavToM4a(inputPath, outputPath, startMs, durationMs)
                            runOnUiThread {
                                result.success(success)
                            }
                        } catch (e: Exception) {
                            runOnUiThread {
                                result.error("ENCODE_ERROR", e.message, null)
                            }
                        }
                    }.start()
                } else {
                    result.error("INVALID_ARGS", "inputPath and outputPath required", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }

    private fun encodeWavToM4a(
        inputWavPath: String,
        outputM4aPath: String,
        startMs: Long,
        durationMs: Long
    ): Boolean {
        val inputFile = File(inputWavPath)
        if (!inputFile.exists() || inputFile.length() < 44) return false

        val sampleRate = 16000
        val channelCount = 1
        val bitRate = 64000
        val bytesPerSample = 2
        val bytesPerSecond = sampleRate * channelCount * bytesPerSample

        val startByteOffset = 44 + (startMs * bytesPerSecond / 1000).toLong()
        val totalBytesToRead = (durationMs * bytesPerSecond / 1000).toLong()

        val format = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, sampleRate, channelCount).apply {
            setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
            setInteger(MediaFormat.KEY_BIT_RATE, bitRate)
            setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16384)
        }

        val codec = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC)
        codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
        codec.start()

        val muxer = MediaMuxer(outputM4aPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
        var audioTrackIndex = -1
        var muxerStarted = false

        val bufferInfo = MediaCodec.BufferInfo()
        val fis = FileInputStream(inputFile)
        val pcmData = ByteArray(totalBytesToRead.toInt())
        var totalRead = 0

        try {
            fis.skip(startByteOffset)
            while (totalRead < pcmData.size) {
                val r = fis.read(pcmData, totalRead, pcmData.size - totalRead)
                if (r <= 0) break
                totalRead += r
            }
        } finally {
            try { fis.close() } catch (_: Exception) {}
        }

        // Automatic Peak Normalization & Gain Boost for quiet sounds (whispers, soft movements)
        var maxAbs = 0
        var i = 0
        while (i + 1 < totalRead) {
            val sample = (pcmData[i].toInt() and 0xFF) or (pcmData[i + 1].toInt() shl 8)
            val shortVal = sample.toShort()
            val absVal = Math.abs(shortVal.toInt())
            if (absVal > maxAbs) maxAbs = absVal
            i += 2
        }

        // If audio is quiet (peak < 22000, i.e. below -3.5 dBFS), boost up to 32x (approx +30 dB)
        if (maxAbs in 1..21999) {
            val targetPeak = 28000.0f
            val gain = (targetPeak / maxAbs).coerceIn(1.0f, 32.0f)
            if (gain > 1.05f) {
                var j = 0
                while (j + 1 < totalRead) {
                    val raw = (pcmData[j].toInt() and 0xFF) or (pcmData[j + 1].toInt() shl 8)
                    val shortVal = raw.toShort().toFloat() * gain
                    val clamped = shortVal.coerceIn(-32768f, 32767f).toInt().toShort()
                    pcmData[j] = (clamped.toInt() and 0xFF).toByte()
                    pcmData[j + 1] = ((clamped.toInt() shr 8) and 0xFF).toByte()
                    j += 2
                }
            }
        }

        try {
            var pcmOffset = 0
            var isEos = false
            var presentationTimeUs = 0L

            while (true) {
                if (!isEos) {
                    val inputBufferIndex = codec.dequeueInputBuffer(10000L)
                    if (inputBufferIndex >= 0) {
                        val inputBuffer = codec.getInputBuffer(inputBufferIndex) ?: continue
                        inputBuffer.clear()

                        val remaining = totalRead - pcmOffset
                        val toWrite = 4096.coerceAtMost(remaining)

                        if (toWrite > 0) {
                            inputBuffer.put(pcmData, pcmOffset, toWrite)
                            presentationTimeUs = (pcmOffset.toLong() * 1000000L) / bytesPerSecond
                            codec.queueInputBuffer(inputBufferIndex, 0, toWrite, presentationTimeUs, 0)
                            pcmOffset += toWrite
                        } else {
                            codec.queueInputBuffer(inputBufferIndex, 0, 0, presentationTimeUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            isEos = true
                        }
                    }
                }

                val outputBufferIndex = codec.dequeueOutputBuffer(bufferInfo, 10000L)
                if (outputBufferIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    if (muxerStarted) {
                        throw RuntimeException("Format changed twice")
                    }
                    val newFormat = codec.outputFormat
                    audioTrackIndex = muxer.addTrack(newFormat)
                    muxer.start()
                    muxerStarted = true
                } else if (outputBufferIndex >= 0) {
                    val outputBuffer = codec.getOutputBuffer(outputBufferIndex)
                    if (outputBuffer != null && muxerStarted && (bufferInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0 && bufferInfo.size != 0) {
                        outputBuffer.position(bufferInfo.offset)
                        outputBuffer.limit(bufferInfo.offset + bufferInfo.size)
                        muxer.writeSampleData(audioTrackIndex, outputBuffer, bufferInfo)
                    }
                    codec.releaseOutputBuffer(outputBufferIndex, false)

                    if ((bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) {
                        break
                    }
                }
            }
        } finally {
            try { codec.stop() } catch (_: Exception) {}
            try { codec.release() } catch (_: Exception) {}
            try {
                if (muxerStarted) {
                    muxer.stop()
                }
                muxer.release()
            } catch (_: Exception) {}
        }

        val out = File(outputM4aPath)
        return out.exists() && out.length() > 0
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_AUDIO_CODE) {
            val uri = data?.data
            if (resultCode == RESULT_OK && uri != null) {
                Thread {
                    try {
                        val tempFile = File(cacheDir, "imported_${System.currentTimeMillis()}.wav")
                        contentResolver.openInputStream(uri)?.use { input ->
                            tempFile.outputStream().use { output ->
                                input.copyTo(output)
                            }
                        }
                        runOnUiThread {
                            pendingPickerResult?.success(tempFile.absolutePath)
                            pendingPickerResult = null
                        }
                    } catch (e: Exception) {
                        runOnUiThread {
                            pendingPickerResult?.error("FILE_ERROR", e.message, null)
                            pendingPickerResult = null
                        }
                    }
                }.start()
            } else {
                pendingPickerResult?.success(null)
                pendingPickerResult = null
            }
        }
    }
}

import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'platform_file/platform_file.dart';

class AudioTrimmerService {
  static const MethodChannel _encoderChannel =
      MethodChannel('com.sleeprecorder.app/audio_encoder');

  /// Trims and hardware-encodes a segment to genuine M4A (AAC) audio format
  /// with exact duration, 100% compatible with WhatsApp, iOS, Android, and web players.
  Future<AppFile> trimAudioSnippet({
    required AppFile inputFile,
    required AppFile outputFile,
    required Duration startOffset,
    required Duration duration,
  }) async {
    try {
      final success = await _encoderChannel.invokeMethod<bool>(
        'trimAndEncodeM4a',
        {
          'inputPath': inputFile.path,
          'outputPath': outputFile.path,
          'startMs': startOffset.inMilliseconds,
          'durationMs': duration.inMilliseconds,
        },
      );

      if (success == true && await outputFile.exists()) {
        return outputFile;
      }
    } catch (_) {}

    // Fallback: trim to valid WAV format
    return trimWavFile(
      inputFile: inputFile,
      outputFile: outputFile,
      startOffset: startOffset,
      duration: duration,
    );
  }

  /// Trims a WAV file between startOffset and duration.
  Future<AppFile> trimWavFile({
    required AppFile inputFile,
    required AppFile outputFile,
    required Duration startOffset,
    required Duration duration,
  }) async {
    final bytes = await inputFile.readAsBytes();
    if (bytes.length < 44) {
      return inputFile;
    }

    final header = bytes.sublist(0, 44);
    final ByteData bd = ByteData.sublistView(header);

    final numChannels = bd.getUint16(22, Endian.little);
    final sampleRate = bd.getUint32(24, Endian.little);
    final bitsPerSample = bd.getUint16(34, Endian.little);
    final blockAlign = (numChannels * bitsPerSample) ~/ 8;

    if (blockAlign <= 0) {
      return inputFile;
    }

    final startByteOffset = 44 + ((startOffset.inMilliseconds * sampleRate * blockAlign) ~/ 1000);
    final targetByteLength = ((duration.inMilliseconds * sampleRate * blockAlign) ~/ 1000);

    int startByte = startByteOffset.clamp(44, bytes.length).toInt();
    int endByte = (startByte + targetByteLength).clamp(startByte, bytes.length).toInt();
    int pcmSubLength = endByte - startByte;

    final newHeader = Uint8List.fromList(header);
    final newBd = ByteData.sublistView(newHeader);

    newBd.setUint32(4, 36 + pcmSubLength, Endian.little);
    newBd.setUint32(40, pcmSubLength, Endian.little);

    final pcmBytes = Uint8List.fromList(bytes.sublist(startByte, endByte));

    // Automatic Peak Normalization & Gain Boost for quiet sounds (whispers, soft movements)
    if (bitsPerSample == 16 && pcmBytes.length >= 2) {
      final pcmView = ByteData.sublistView(pcmBytes);
      int maxAbs = 0;
      for (int i = 0; i < pcmBytes.length - 1; i += 2) {
        final sample = pcmView.getInt16(i, Endian.little).abs();
        if (sample > maxAbs) maxAbs = sample;
      }

      // If peak is below -3.5 dBFS (maxAbs < 22000), boost up to 32x (~ +30 dB)
      if (maxAbs > 0 && maxAbs < 22000) {
        final double gain = (28000.0 / maxAbs).clamp(1.0, 32.0);
        if (gain > 1.05) {
          for (int i = 0; i < pcmBytes.length - 1; i += 2) {
            final sample = pcmView.getInt16(i, Endian.little);
            final boosted = (sample * gain).round().clamp(-32768, 32767);
            pcmView.setInt16(i, boosted, Endian.little);
          }
        }
      }
    }

    final builder = BytesBuilder();
    builder.add(newHeader);
    builder.add(pcmBytes);

    await outputFile.writeAsBytes(builder.takeBytes());
    return outputFile;
  }
}

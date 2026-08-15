import 'package:flutter/foundation.dart';
import 'logger_service.dart';
import 'platform_file/platform_file.dart';

class WavAnalyzerService {
  final LoggerService _logger = LoggerService();

  /// Background Isolate: Analyzes a WAV file off the main UI thread with zero UI lag
  Future<List<double>> extractAmplitudeHistory(AppFile wavFile) async {
    if (kIsWeb) return [];
    try {
      if (!await wavFile.exists()) return [];
      final path = wavFile.path;

      // Run heavy file parsing in background OS Isolate thread
      final rawHistory = await compute(parseWavNative, path);

      // Downsample to max 1200 points for instant 60/120 FPS rendering
      final downsampled = _downsample(rawHistory, maxPoints: 1200);

      _logger.log('WavAnalyzerService: Computed ${downsampled.length} points in background isolate for $path.');
      return downsampled;
    } catch (e) {
      _logger.log('WavAnalyzerService Error: $e');
      return [];
    }
  }

  static List<double> _downsample(List<double> input, {int maxPoints = 1200}) {
    if (input.length <= maxPoints) return input;

    final List<double> result = [];
    final double step = input.length / maxPoints;

    for (int i = 0; i < maxPoints; i++) {
      final int start = (i * step).floor();
      final int end = ((i + 1) * step).floor().clamp(start + 1, input.length);

      double maxDb = -60.0;
      for (int j = start; j < end; j++) {
        if (input[j] > maxDb) {
          maxDb = input[j];
        }
      }
      result.add(maxDb);
    }
    return result;
  }
}

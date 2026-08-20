import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class NativeFilePickerService {
  static const MethodChannel _channel = MethodChannel('com.sleeprecorder.app/file_picker');

  static Future<String?> pickAudioFile() async {
    if (kIsWeb) return null;
    try {
      final String? path = await _channel.invokeMethod('pickAudioFile');
      return path;
    } catch (_) {
      return null;
    }
  }
}

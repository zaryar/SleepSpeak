import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'platform_file/platform_file.dart';

class LoggerService {
  static final LoggerService _instance = LoggerService._internal();
  factory LoggerService() => _instance;
  LoggerService._internal();

  AppFile? _logFile;
  final List<String> _inMemoryLogs = [];

  Future<void> init() async {
    if (!kIsWeb) {
      try {
        final docsDir = await getApplicationDocumentsDirectory();
        _logFile = AppFile(p.join(docsDir.path, 'sleep_recorder_debug.log'));
      } catch (_) {}
    }
    await log('--- Logger initialized (App Started) ---');
  }

  Future<void> log(String message) async {
    try {
      final now = DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(DateTime.now());
      final line = '[$now] $message\n';
      if (kIsWeb) {
        _inMemoryLogs.add(line);
        if (_inMemoryLogs.length > 500) _inMemoryLogs.removeAt(0);
        debugPrint(line);
      } else if (_logFile != null) {
        await _logFile!.writeAsString(line, flush: true, append: true);
      }
    } catch (_) {}
  }

  Future<String> getLogContent() async {
    if (kIsWeb) {
      return _inMemoryLogs.isNotEmpty ? _inMemoryLogs.join() : 'Web Demo Modus - In-Memory Log aktiv.';
    }
    try {
      if (_logFile != null && await _logFile!.exists()) {
        return await _logFile!.readAsString();
      }
    } catch (_) {}
    return 'Kein Logfile gefunden.';
  }

  Future<void> clearLog() async {
    if (kIsWeb) {
      _inMemoryLogs.clear();
      return;
    }
    try {
      if (_logFile != null && await _logFile!.exists()) {
        await _logFile!.writeAsString('--- Log cleared --- \n');
      }
    } catch (_) {}
  }
}

import 'dart:io';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class LoggerService {
  static final LoggerService _instance = LoggerService._internal();
  factory LoggerService() => _instance;
  LoggerService._internal();

  File? _logFile;

  Future<void> init() async {
    final docsDir = await getApplicationDocumentsDirectory();
    _logFile = File(p.join(docsDir.path, 'sleep_recorder_debug.log'));
    await log('--- Logger initialized (App Started) ---');
  }

  Future<void> log(String message) async {
    try {
      final now = DateFormat('yyyy-MM-dd HH:mm:ss.SSS').format(DateTime.now());
      final line = '[$now] $message\n';
      if (_logFile != null) {
        await _logFile!.writeAsString(line, mode: FileMode.append, flush: true);
      }
    } catch (_) {}
  }

  Future<String> getLogContent() async {
    try {
      if (_logFile != null && await _logFile!.exists()) {
        return await _logFile!.readAsString();
      }
    } catch (_) {}
    return 'Kein Logfile gefunden.';
  }

  Future<void> clearLog() async {
    try {
      if (_logFile != null && await _logFile!.exists()) {
        await _logFile!.writeAsString('--- Log cleared --- \n');
      }
    } catch (_) {}
  }
}

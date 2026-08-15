import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'data/repositories/recording_repository.dart';
import 'data/services/logger_service.dart';
import 'ui/core/theme.dart';
import 'ui/features/home/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final logger = LoggerService();
  await logger.init();

  FlutterError.onError = (details) {
    logger.log('FLUTTER ERROR: ${details.exceptionAsString()}\n${details.stack}');
    FlutterError.presentError(details);
  };

  PlatformDispatcher.instance.onError = (error, stack) {
    logger.log('UNCAUGHT PLATFORM ERROR: $error\n$stack');
    return true;
  };

  final repository = RecordingRepository();
  runApp(SleepRecorderApp(repository: repository));
}

class SleepRecorderApp extends StatelessWidget {
  final RecordingRepository repository;

  const SleepRecorderApp({super.key, required this.repository});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SleepSpeak',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: HomeScreen(repository: repository),
    );
  }
}

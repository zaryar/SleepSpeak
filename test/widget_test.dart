import 'package:flutter_test/flutter_test.dart';
import 'package:sleep_recorder/data/repositories/recording_repository.dart';
import 'package:sleep_recorder/main.dart';

void main() {
  testWidgets('App launches successfully', (WidgetTester tester) async {
    final repository = RecordingRepository();
    await tester.pumpWidget(SleepRecorderApp(repository: repository));
    expect(find.text('SleepSpeak'), findsOneWidget);
  });
}

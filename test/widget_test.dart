import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sleep_recorder/data/repositories/recording_repository.dart';
import 'package:sleep_recorder/main.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('App launches and renders SleepSpeak header and action buttons', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final repository = RecordingRepository();
    await tester.pumpWidget(SleepRecorderApp(repository: repository));
    await tester.pump(const Duration(milliseconds: 200));

    expect(find.text('SleepSpeak'), findsOneWidget);
    expect(find.text('SCHLAF AUFNEHMEN'), findsOneWidget);
    expect(find.textContaining('Schlaf in'), findsOneWidget);
  });

  testWidgets('Tapping delay config button opens the bottom sheet with presets', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final repository = RecordingRepository();
    await tester.pumpWidget(SleepRecorderApp(repository: repository));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    // Find and tap the tune icon button to configure delay
    final tuneIconFinder = find.byIcon(Icons.tune);
    expect(tuneIconFinder, findsOneWidget);
    await tester.tap(tuneIconFinder);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    // Modal sheet should be visible with presets and slider
    expect(find.text('Startverzögerung einstellen'), findsOneWidget);
    expect(find.text('1 Min'), findsOneWidget);
    expect(find.text('10 Min'), findsOneWidget);
    expect(find.text('30 Min'), findsOneWidget);
    expect(find.textContaining('starten'), findsOneWidget);

    // Tap button to close sheet and activate timer
    await tester.tap(find.textContaining('starten'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(find.text('Startverzögerung einstellen'), findsNothing);
  });
}

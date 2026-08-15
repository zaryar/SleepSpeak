import 'dart:async';
import 'package:battery_plus/battery_plus.dart';

class BatteryService {
  final Battery _battery = Battery();
  StreamSubscription<int>? _batteryLevelSub;
  Function()? onLowBatteryWarning;

  void startMonitoring({required Function() onLowBattery}) {
    onLowBatteryWarning = onLowBattery;
    _batteryLevelSub = Stream.periodic(const Duration(minutes: 2)).asyncMap((_) async {
      return await _battery.batteryLevel;
    }).listen((level) {
      if (level <= 5) {
        onLowBatteryWarning?.call();
      }
    });
  }

  Future<int> getBatteryLevel() async {
    try {
      return await _battery.batteryLevel;
    } catch (_) {
      return 100;
    }
  }

  void stopMonitoring() {
    _batteryLevelSub?.cancel();
    _batteryLevelSub = null;
  }
}

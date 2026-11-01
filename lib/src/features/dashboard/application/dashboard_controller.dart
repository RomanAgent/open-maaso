import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

class DashboardController extends AppController {
  final batteryLevel = 100.obs;
  final isOnline = true.obs;
  final isBluetoothLinked = false.obs;

  final Battery _battery = Battery();
  final Connectivity _connectivity = Connectivity();
  StreamSubscription? _connSub;

  @override
  void onInit() {
    super.onInit();
    _bootstrap();
  }

  @override
  void onClose() {
    _connSub?.cancel();
    super.onClose();
  }

  Future<void> _bootstrap() async {
    try {
      batteryLevel.value = await _battery.batteryLevel;
    } catch (_) {}
    _connSub = _connectivity.onConnectivityChanged.listen((result) {
      isOnline.value = !result.contains(ConnectivityResult.none);
    });
  }
}

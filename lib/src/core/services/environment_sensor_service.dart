import 'dart:async';
import 'dart:math' as math;

import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:sensors_plus/sensors_plus.dart';

/// Watches the phone's physical / ambient state and fires
/// [SystemStatusEvent]s into the agent EventBus whenever a
/// meaningful threshold crosses.  The agent can choose to react (alert
/// the user, change mood, suggest dark mode, …) — this service stays
/// passive, just sensing.
///
/// Events emitted (triggerType):
///   • app_resumed         (app brought to foreground)
///   • app_paused          (app went to background)
///   • battery_low         (≤ 20%)
///   • battery_critical    (≤ 8%)
///   • battery_charging    (just plugged in)
///   • battery_unplugged   (just unplugged)
///   • network_changed     (online ↔ offline)
///   • motion_high         (sustained acceleration spike: walking → running, drop)
///   • late_night          (00:00–05:00 on first resume in that window)
class EnvironmentSensorService extends AppService with WidgetsBindingObserver {
  final Battery _battery = Battery();
  final Connectivity _connectivity = Connectivity();

  StreamSubscription? _accelSub;
  StreamSubscription? _connectivitySub;
  StreamSubscription<BatteryState>? _batteryStateSub;
  Timer? _batteryPoll;

  // —— state ——
  int _lastBatteryLevel = 100;
  BatteryState _lastBatteryState = BatteryState.unknown;
  bool _wasOnline = true;
  DateTime _lastMotionFire = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _lastLateNightFire = DateTime.fromMillisecondsSinceEpoch(0);

  // —— motion smoothing ——
  static const _motionThresholdG = 1.8; // 1.0g = standing still under gravity
  static const _motionCooldown = Duration(minutes: 2);
  static const _lateNightCooldown = Duration(hours: 6);

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    _wireBattery();
    _wireConnectivity();
    _wireMotion();
    _checkLateNight();
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _accelSub?.cancel();
    _connectivitySub?.cancel();
    _batteryStateSub?.cancel();
    _batteryPoll?.cancel();
    super.onClose();
  }

  // ——————————————————— battery ———————————————————

  Future<void> _wireBattery() async {
    try {
      _lastBatteryLevel = await _battery.batteryLevel;
      _lastBatteryState = await _battery.batteryState;
    } catch (_) {}
    _batteryStateSub = _battery.onBatteryStateChanged.listen((state) {
      if (state == BatteryState.charging &&
          _lastBatteryState != BatteryState.charging) {
        _fire('battery_charging', _lastBatteryLevel);
      } else if (state == BatteryState.discharging &&
          _lastBatteryState == BatteryState.charging) {
        _fire('battery_unplugged', _lastBatteryLevel);
      }
      _lastBatteryState = state;
    });
    // Poll level periodically (no public stream on iOS for level)
    _batteryPoll = Timer.periodic(const Duration(minutes: 1), (_) async {
      try {
        final lvl = await _battery.batteryLevel;
        if (lvl <= 8 && _lastBatteryLevel > 8) {
          _fire('battery_critical', lvl);
        } else if (lvl <= 20 && _lastBatteryLevel > 20) {
          _fire('battery_low', lvl);
        }
        _lastBatteryLevel = lvl;
      } catch (_) {}
    });
  }

  // ——————————————————— connectivity ———————————————————

  void _wireConnectivity() {
    _connectivitySub = _connectivity.onConnectivityChanged.listen((list) {
      final online = !list.contains(ConnectivityResult.none);
      if (online != _wasOnline) {
        _fire(
          online ? 'network_online' : 'network_offline',
          list.map((r) => r.name).toList(),
        );
        _wasOnline = online;
      }
    });
  }

  // ——————————————————— motion ———————————————————

  void _wireMotion() {
    // accelerometer reports m/s² including gravity (~9.81 stationary).
    _accelSub =
        accelerometerEventStream(
          samplingPeriod: const Duration(milliseconds: 200),
        ).listen(
          (e) {
            final mag = math.sqrt(e.x * e.x + e.y * e.y + e.z * e.z) / 9.81;
            if (mag > _motionThresholdG) {
              final now = DateTime.now();
              if (now.difference(_lastMotionFire) > _motionCooldown) {
                _lastMotionFire = now;
                _fire('motion_high', mag.toStringAsFixed(2));
              }
            }
          },
          onError: (_) {
            // sensor unavailable on this device — skip silently
          },
        );
  }

  // ——————————————————— lifecycle ———————————————————

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _fire('app_resumed', null);
      _checkLateNight();
    } else if (state == AppLifecycleState.paused) {
      _fire('app_paused', null);
    }
  }

  // ——————————————————— late-night ———————————————————

  void _checkLateNight() {
    final now = DateTime.now();
    final hour = now.hour;
    if (hour >= 0 && hour < 5) {
      if (now.difference(_lastLateNightFire) > _lateNightCooldown) {
        _lastLateNightFire = now;
        _fire('late_night', hour);
      }
    }
  }

  // ——————————————————— shared fire ———————————————————

  void _fire(String trigger, Object? payload) {
    EventBus().fire(SystemStatusEvent(trigger, payload: payload));
  }
}

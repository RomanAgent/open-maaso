import 'dart:async';
import 'package:flutter/material.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../utils/logger.dart';
import 'event_bus.dart';

// --- Event enum and data structures ---
enum TriggerType {
  appResumed, // user switched back to the app / just unlocked & screen on
  batteryLow, // battery critical (<20%)
  networkDisconnected, // sudden disconnect
  networkRestored, // network restored
}

class SystemEvent {
  final TriggerType type;
  final dynamic data; // extra payload, e.g. the current battery percentage
  SystemEvent(this.type, {this.data});
}

// --- System triggers core class ---
/// Mixes in WidgetsBindingObserver to listen to Flutter engine-level lifecycle.
class SystemTriggers with WidgetsBindingObserver {
  static final SystemTriggers _instance = SystemTriggers._internal();
  factory SystemTriggers() => _instance;
  SystemTriggers._internal();

  final Battery _battery = Battery();
  final Connectivity _connectivity = Connectivity();

  StreamSubscription? _batterySub;
  StreamSubscription? _connectivitySub;
  bool _isInitialized = false;

  /// 🌟 Removed the callback parameter, relying entirely on the EventBus.
  void init() {
    if (_isInitialized) return;

    WidgetsBinding.instance.addObserver(this);

    _batterySub = _battery.onBatteryStateChanged.listen((
      BatteryState state,
    ) async {
      if (state == BatteryState.discharging) {
        final level = await _battery.batteryLevel;
        if (level <= 20) {
          _fireEvent(SystemEvent(TriggerType.batteryLow, data: level));
        }
      }
    });

    _connectivitySub = _connectivity.onConnectivityChanged.listen((
      List<ConnectivityResult> results,
    ) {
      if (results.contains(ConnectivityResult.none)) {
        _fireEvent(SystemEvent(TriggerType.networkDisconnected));
      } else {
        _fireEvent(SystemEvent(TriggerType.networkRestored));
      }
    });

    _isInitialized = true;
    Log.i('📡 [SystemTriggers] Hardware-level system nerve endings activated');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _fireEvent(SystemEvent(TriggerType.appResumed));
    }
  }

  void _fireEvent(SystemEvent event) {
    Log.i('🔔 [SystemTriggers] Captured system event: ${event.type.name}');
    // 🌟 Drop the event onto the global bus.
    EventBus().fire(SystemStatusEvent(event.type.name, payload: event.data));
  }

  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _batterySub?.cancel();
    _connectivitySub?.cancel();
    _isInitialized = false;
  }
}

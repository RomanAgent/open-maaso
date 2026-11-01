import 'dart:convert';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/services/ble/ble_transport_service.dart';
import 'package:maaso/src/core/services/ble/yoturetoys/yoturetoys_device.dart';

/// Parent ("一级") Bluetooth skill: device-agnostic discovery + connection.
///
/// It owns the generic verbs — scan / connect / disconnect / status — and
/// routes them to the right per-device facade. Each supported product is a
/// secondary ("二级") skill (e.g. the Yoturetoys projector) that handles that
/// device's own protocol; this skill just gets the radio connected first.
class BluetoothSkill extends AgentSkill {
  BluetoothSkill({this.agentId});
  final String? agentId;

  @override
  String get skillName => 'Bluetooth';

  @override
  String get description =>
      'Discover and connect Bluetooth (BLE) hardware. Use this to scan for a '
      'nearby device, connect to it, check connection status, or disconnect. '
      'Per-device features (e.g. sending a picture to the AI Drawing Projector) '
      'live in that device\'s own skill — connect here first.';

  BleTransportService get _transport => appServices.find<BleTransportService>();
  YoturetoysDevice get _projector => appServices.find<YoturetoysDevice>();

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'bluetoothScan': (_) => _scan(),
    'bluetoothConnect': _connect,
    'bluetoothDisconnect': (_) => _disconnect(),
    'bluetoothStatus': (_) => _status(),
  };

  @override
  Map<String, Map<String, dynamic>>? get nativeToolSchemas => {
    'bluetoothScan': {'type': 'object', 'properties': {}},
    'bluetoothConnect': {
      'type': 'object',
      'properties': {
        'id': {
          'type': 'string',
          'description': 'Device id from bluetoothScan().',
        },
        'sn': {
          'type': 'string',
          'description': 'Device serial from bluetoothScan().',
        },
      },
    },
    'bluetoothDisconnect': {'type': 'object', 'properties': {}},
    'bluetoothStatus': {'type': 'object', 'properties': {}},
  };

  @override
  Map<String, String> get nativeMethodDescriptions => const {
    'bluetoothScan': 'Scan ~8s for nearby supported Bluetooth devices.',
    'bluetoothConnect':
        'Connect to a scanned device, or omit id/sn to scan and auto-connect the only match.',
    'bluetoothDisconnect': 'Disconnect the current Bluetooth device.',
    'bluetoothStatus':
        'Report adapter + connection state and the connected device.',
  };

  // ─────────────────────────── implementation ───────────────────────────

  Future<String> _scan() {
    return _projector.runAccountOperation(() async {
      // Only one product type is supported today; scan uses its profile.
      await _projector.scan(seconds: 8);
      await Future<void>.delayed(const Duration(seconds: 8));
      final devices = _transport.found.values
          .map(
            (e) => {'id': e.id, 'sn': e.sn, 'label': e.label, 'rssi': e.rssi},
          )
          .toList();
      return jsonEncode({
        'scanning': _transport.isScanning.value,
        'devices': devices,
      });
    });
  }

  Future<String> _connect(List<dynamic> args) {
    return _projector.runAccountOperation(() async {
      try {
        final decoded = args.isEmpty
            ? const {}
            : (args[0] is String ? jsonDecode(args[0] as String) : args[0]);
        final map = decoded is Map ? decoded : const {};
        final id = map['id']?.toString();
        final sn = map['sn']?.toString();

        // Keep scan settling and device selection inside the facade's account
        // operation. A late account-A continuation must never connect through
        // an already activated account-B transport.
        if (_transport.found.isEmpty) {
          if (id == null && sn == null) {
            final entry = await _projector.scanAndAutoConnect(seconds: 8);
            if (entry != null) {
              return jsonEncode({'ok': true, 'id': entry.id, 'sn': entry.sn});
            }
          } else {
            await _projector.scan(seconds: 8);
            await Future<void>.delayed(const Duration(seconds: 8));
          }
        }

        final entries = _transport.found.values.toList();
        if (entries.isEmpty) {
          return jsonEncode({'error': 'projector_not_found'});
        }

        BleScanEntry? target;
        if (id != null) {
          target = entries.where((e) => e.id == id).firstOrNull;
        } else if (sn != null) {
          target = entries.where((e) => e.sn == sn).firstOrNull;
        } else if (entries.length == 1) {
          target = entries.first;
        }
        if (target == null) {
          return jsonEncode({
            'error': 'ambiguous_device',
            'count': entries.length,
          });
        }
        await _transport.connect(target.device);
        return jsonEncode({'ok': true, 'id': target.id, 'sn': target.sn});
      } catch (error) {
        // BLE implementations expose platform-specific error strings; keep the
        // raw diagnostic out of the model-visible result.
        Log.w('[BluetoothSkill] connect failed: $error');
        return jsonEncode({'error': 'connection_failed'});
      }
    });
  }

  Future<String> _disconnect() {
    return _projector.runAccountOperation(() async {
      await _transport.disconnect();
      return jsonEncode({'ok': true});
    });
  }

  Future<String> _status() {
    return _projector.runAccountOperation(() async {
      final info = _projector.info.value;
      return jsonEncode({
        'adapterOn': _transport.adapterState.value.name == 'on',
        'connected': _transport.isConnected.value,
        if (info != null)
          'device': {
            'product': YoturetoysDevice.productName,
            'sn': info.sn,
            'firmware': info.firmwareVersion,
          },
      });
    });
  }
}

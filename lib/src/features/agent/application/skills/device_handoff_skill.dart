import 'dart:convert';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/account_device_lease.dart';
import 'package:maaso/src/core/services/agent_handoff_device_directory.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';

/// Read-only account device awareness. Presentation stays local to each device.
final class DeviceHandoffSkill extends AgentSkill {
  DeviceHandoffSkill({
    this.agentId = 'self',
    AgentHandoffDeviceDirectory? directory,
  }) : _directoryOverride = directory;

  final String agentId;
  final AgentHandoffDeviceDirectory? _directoryOverride;

  AgentHandoffDeviceDirectory? get _directory =>
      _directoryOverride ??
      appServices.maybeFind<AgentHandoffDeviceDirectory>();

  static const emptySchema = <String, dynamic>{
    'type': 'object',
    'properties': <String, dynamic>{},
    'additionalProperties': false,
  };

  @override
  String get skillName => 'DeviceHandoff';
  @override
  String get description =>
      'Read the owner account’s online devices, including this device. The '
      'avatar can appear on every device at once; moving or returning to a '
      'device needs no handoff. Use listDevices for device awareness and '
      'deviceCount; a truncated result is only a lower bound. Never claim a '
      'transfer or hide another device’s avatar.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'listDevices': _listDevices,
  };
  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => const {
    'listDevices': emptySchema,
  };
  @override
  Map<String, String> get nativeMethodDescriptions => const {
    'listDevices': 'Read all online account devices and their count.',
  };

  Future<String> _listDevices(List<dynamic> args) async {
    if (agentId != 'self') return _error('handoff_self_only');
    if (_decode(args, const {}) == null) return _error('invalid_arguments');
    final directory = _directory;
    if (directory == null) return _error('handoff_unavailable');
    try {
      final snapshot = await directory.listDevices();
      if (!identical(directory, _directory)) {
        return _error('handoff_context_changed');
      }
      final devices = <String, AccountDevicePresenceView>{};
      for (final device in snapshot.presences) {
        if (!device.expiresAt.isAfter(snapshot.snapshotAt)) continue;
        final existing = devices[device.installationId];
        if (existing == null ||
            device.lastSeenAt.isAfter(existing.lastSeenAt)) {
          devices[device.installationId] = device;
        }
      }
      return jsonEncode({
        'ok': true,
        'deviceCount': devices.length,
        'truncated': snapshot.truncated || devices.length > 100,
        'targets': devices.values
            .take(100)
            .map(
              (target) => {
                'id': target.presenceSessionId,
                'label': target.deviceLabel,
                'platform': target.platform,
              },
            )
            .toList(growable: false),
      });
    } on Object {
      return _error('handoff_unavailable');
    }
  }

  static Map<dynamic, dynamic>? _decode(List<dynamic> args, Set<String> keys) {
    if (args.length != 1) return null;
    final Object? value;
    try {
      value = args.single is String ? jsonDecode(args.single) : args.single;
    } on FormatException {
      return null;
    }
    if (value is! Map ||
        value.length != keys.length ||
        !value.keys.every(keys.contains)) {
      return null;
    }
    return value;
  }

  static String _error(String code) => jsonEncode({'ok': false, 'error': code});
}

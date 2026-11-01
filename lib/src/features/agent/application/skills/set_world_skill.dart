import 'dart:convert';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/services/world_kb_service.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';

/// Proposes general world / household facts to the unified memory ledger.
class SetWorldSkill extends AgentSkill {
  SetWorldSkill({this.agentId = 'self'});

  final String agentId;

  WorldKBService get _w => appServices.find<WorldKBService>();

  @override
  String get skillName => 'SetWorld';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Propose a general world fact / household rule to the governed memory ledger. '
      'Use for stable facts that are not about yourself (soul.md) or your master '
      '(master.md): names of pets, recurring rituals, rules the master has set for you, '
      'things in their home, etc. Per-conversation events belong in logEpisode, '
      'not here. Read the receipt: pending_review needs owner review; rejected '
      'was not saved. Only accepted-current notes are used as long-term context.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'setWorld': _set,
    'getWorld': _get,
  };

  Future<dynamic> _set(List<dynamic> args) async {
    if (agentId != _w.ownerAgentId) return '{"error":"owner_only"}';
    if (args.length != 1) return '{"error":"invalid_arguments"}';
    Map<String, dynamic> p;
    try {
      final raw = args.single;
      p = Map<String, dynamic>.from(
        (raw is String ? jsonDecode(raw) : raw) as Map,
      );
    } catch (_) {
      return '{"error":"invalid_json"}';
    }
    if (p.length != 1 ||
        (p.keys.single != 'notesAppend' && p.keys.single != 'notesReplace') ||
        p.values.single is! String) {
      return '{"error":"invalid_arguments"}';
    }
    final result = await _w.update(
      notesAppend: p['notesAppend']?.toString(),
      notesReplace: p['notesReplace']?.toString(),
    );
    return jsonEncode(<String, Object?>{
      'status': switch (result.disposition) {
        MemoryWriteDisposition.quarantined => 'pending_review',
        MemoryWriteDisposition.rejected => 'rejected',
        MemoryWriteDisposition.duplicate => 'unchanged',
        _ => 'applied',
      },
      'disposition': result.disposition.name,
      'episodeId': result.episodeId,
      'reason': result.reason,
    });
  }

  dynamic _get(List<dynamic> _) => agentId != _w.ownerAgentId
      ? '{"error":"owner_only"}'
      : jsonEncode({
          'notes': _w.notes.value,
          'legacyMigrationPending': _w.legacyMigrationPending,
          'readOnlyLegacy': _w.readOnlyLegacy,
        });
}

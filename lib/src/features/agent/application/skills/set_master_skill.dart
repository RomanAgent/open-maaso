import 'dart:convert';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/services/master_profile_service.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';

/// Proposes a typed Master Profile update to the unified memory ledger.
/// Accepted-current revisions are materialized by [MasterProfileService];
/// model proposals remain pending until owner review.
class SetMasterSkill extends AgentSkill {
  SetMasterSkill();

  MasterProfileService get _m => appServices.find<MasterProfileService>();

  @override
  String get skillName => 'SetMaster';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Propose a stable Master Profile fact for governed long-term memory. '
      'Use for how to address the user, pronouns, age, family, allergies, '
      'preferences, and important dates. Partial updates are allowed; the '
      'result reports whether the proposal needs owner review.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'setMaster': _set,
    'getMaster': _get,
  };

  Future<dynamic> _set(List<dynamic> args) async {
    if (args.isEmpty) return '{"error":"missing_args"}';
    Map<String, dynamic> p;
    try {
      p = jsonDecode(args[0].toString()) as Map<String, dynamic>;
    } catch (_) {
      return '{"error":"invalid_json"}';
    }
    final result = await _m.update(
      name: p['name']?.toString(),
      pronouns: p['pronouns']?.toString(),
      age: _parseAge(p['age']),
      notesAppend: p['notesAppend']?.toString(),
      notesReplace: p['notesReplace']?.toString(),
    );
    final status = switch (result.disposition) {
      MemoryWriteDisposition.quarantined => 'pending_review',
      MemoryWriteDisposition.rejected => 'rejected',
      MemoryWriteDisposition.duplicate => 'unchanged',
      _ => 'applied',
    };
    return jsonEncode(<String, Object?>{
      'status': status,
      'disposition': result.disposition.name,
      'episodeId': result.episodeId,
      'reason': result.reason,
    });
  }

  int? _parseAge(Object? raw) {
    if (raw == null) return null;
    if (raw is num) return raw.round();
    return int.tryParse(raw.toString());
  }

  dynamic _get(List<dynamic> _) => jsonEncode({
    'name': _m.name.value,
    'pronouns': _m.pronouns.value,
    'age': _m.age.value,
    'notes': _m.notes.value,
  });
}

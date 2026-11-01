import 'dart:convert';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';

/// Lets the agent propose a moment for the governed memory ledger — a
/// beat in "我们之间发生过什么".  Distinct from logEpisode (raw recall): a
/// milestone is an emotionally meaningful node in the *relationship* (first
/// deep talk, a goal the user finished, a bad day you got them through, an
/// inside joke). Proposals go to the memory ledger; they do not grant closeness.
class LogMilestoneSkill extends AgentSkill {
  LogMilestoneSkill();

  RelationshipService get _rel => appServices.find<RelationshipService>();

  @override
  String get skillName => 'LogMilestone';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Propose a meaningful moment between you and them for the memory '
      'ledger. Use when something real happened: a first deep talk, they finished '
      'a goal you helped with, you got them through a low day, a recurring '
      'inside joke was born. Be sparing — not every nice chat is a milestone. '
      'The memory ledger reviews the event against its source. A proposed '
      'event never grants closeness, a nickname, or permission to tease. '
      'Call getRelationship() for the current evidence-based stage.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'logMilestone': _log,
    'getRelationship': _get,
  };

  static const _validTypes = {
    'deep_talk',
    'goal_done',
    'low_weathered',
    'inside_joke',
    'first_meet',
    'anniversary',
    'custom',
  };

  Future<dynamic> _log(List<dynamic> args) async {
    if (args.isEmpty) return '{"error":"missing_args"}';
    Map<String, dynamic> p;
    try {
      p = jsonDecode(args[0].toString()) as Map<String, dynamic>;
    } catch (_) {
      return '{"error":"invalid_json"}';
    }
    final title = p['title']?.toString().trim();
    if (title == null || title.isEmpty) {
      return '{"error":"missing_title"}';
    }
    var type = p['type']?.toString().trim().toLowerCase() ?? 'custom';
    if (!_validTypes.contains(type)) type = 'custom';
    final note = p['note']?.toString().trim() ?? '';
    if (title.runes.length > 160 || note.runes.length > 1200) {
      return '{"error":"milestone_too_long"}';
    }
    final writer = appServices.maybeFind<MemoryWriteCoordinator>();
    if (writer == null || !writer.governanceEnforced || !writer.acceptsWrites) {
      return '{"status":"rejected","reason":"governed_memory_unavailable"}';
    }
    try {
      final source = await writer.currentPersistedUserSource();
      if (source == null || source.agentId != 'self') {
        return '{"status":"rejected","reason":"private_human_source_required"}';
      }
      final result = await writer.writeEpisode(
        Episode(
          when: DateTime.now(),
          what: note.isEmpty ? title : '$title — $note',
          kind: EpisodeKind.relationship,
          salience: 0.6,
        ),
      );
      final status = switch (result.disposition) {
        MemoryWriteDisposition.quarantined => 'pending_review',
        MemoryWriteDisposition.accepted => 'applied',
        MemoryWriteDisposition.duplicate => 'unchanged',
        _ => 'rejected',
      };
      return jsonEncode({
        'status': status,
        'episodeId': result.episodeId,
        'type': type,
        'reason': result.reason,
      });
    } on Object {
      return '{"status":"rejected","reason":"memory_write_failed"}';
    }
  }

  Future<dynamic> _get(List<dynamic> _) async {
    final writer = appServices.maybeFind<MemoryWriteCoordinator>();
    final source = await writer?.currentPersistedUserSource();
    if (source == null || source.agentId != 'self') {
      return '{"error":"private_human_source_required"}';
    }
    final s = _rel.state.value;
    if (s == null) return '{"error":"relationship_not_ready"}';
    return jsonEncode({
      'stage': _rel.effectiveStage.key,
      'stageEn': _rel.effectiveStage.labelEn,
      'daysKnown': s.daysKnown(),
      'policyVersion': _rel.policyVersion,
    });
  }
}

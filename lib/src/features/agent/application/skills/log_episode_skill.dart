import 'dart:convert';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';

/// Lets the agent write a single L2 long-term episodic memory.
///
/// The agent decides what's worth remembering — call this at the *end* of a
/// noteworthy turn with a short summary, the salient entities, the felt
/// emotion, and a 0..1 salience score.  Future turns will surface the
/// episode in the memory-recall preamble when the new user message is
/// keyword-similar.
class LogEpisodeSkill extends AgentSkill {
  LogEpisodeSkill();

  MemoryBus get _bus => appServices.find<MemoryBus>();

  @override
  String get skillName => 'LogEpisode';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      'Save a one-line memory of *this scene* into your long-term episodic store. '
      'Use sparingly — only when the conversation contained something you would want '
      'to recall weeks later (a confession, a plan, an emotional moment, a decision). '
      'Skip for small talk. Stable facts about master/world belong in setMaster/setWorld, '
      'not here — episodes are about *events*, not *facts*. '
      'Read the write receipt before claiming it was remembered: pending_review '
      'requires owner review, rejected was not saved, and unchanged means an '
      'accepted memory already exists.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'logEpisode': _log,
  };

  Future<dynamic> _log(List<dynamic> args) async {
    if (args.isEmpty) return '{"error":"missing_args"}';
    Map<String, dynamic> p;
    try {
      p = jsonDecode(args[0].toString()) as Map<String, dynamic>;
    } catch (_) {
      return '{"error":"invalid_json"}';
    }
    final what = p['what']?.toString().trim();
    if (what == null || what.isEmpty) {
      return '{"error":"missing_what"}';
    }
    final entities =
        (p['entities'] as List?)
            ?.map((e) => e.toString())
            .where((s) => s.isNotEmpty)
            .toList() ??
        const <String>[];
    final salience = (p['salience'] is num)
        ? (p['salience'] as num).toDouble().clamp(0.0, 1.0)
        : 0.5;
    final emotion = p['emotion']?.toString();

    final result = await _bus.writeEpisodeWithResult(
      Episode(
        when: DateTime.now(),
        what: what,
        entities: entities,
        emotion: emotion,
        salience: salience,
      ),
    );
    final episodeId = result.episodeId;
    final reviewState = result.episode?.reviewState;
    final status =
        episodeId == null ||
            result.disposition == MemoryWriteDisposition.rejected ||
            reviewState == EpisodeReviewState.rejected ||
            reviewState == EpisodeReviewState.tombstoned
        ? 'rejected'
        : result.disposition == MemoryWriteDisposition.quarantined ||
              reviewState == EpisodeReviewState.pending
        ? 'pending_review'
        : result.disposition == MemoryWriteDisposition.duplicate
        ? 'unchanged'
        : 'ok';
    return jsonEncode(<String, Object?>{
      'status': status,
      'disposition': result.disposition.name,
      'reviewState': reviewState?.name,
      'created': result.created,
      'projected': result.projected,
      if (episodeId != null) 'id': episodeId,
      if (result.reason != null) 'reason': result.reason,
    });
  }
}

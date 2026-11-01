import 'dart:convert';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/features/agent/application/skills/app_control_skill.dart';

import 'agent_skill.dart';

class MemorySkill extends AgentSkill {
  MemorySkill({this.agentId = 'self', AppControlSkill? appControl})
    : _appControlOverride = appControl;

  final String agentId;
  final AppControlSkill? _appControlOverride;

  @override
  String get skillName => 'MemoryControl';

  @override
  String get namespace => 'skill'; // explicit namespace

  @override
  String get description =>
      'Manage long-term memory. You MUST call remember when the user '
      'tells you important personal info. Read the write receipt before claiming '
      'it was remembered: pending_review requires owner review, rejected was not '
      'saved, and unchanged means an accepted memory already exists. forget '
      'opens the Memory Ledger for owner review; it does not delete memory. '
      'Deletion uses the exact visible revision and owner confirmation there.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'remember': _remember,
    'forget': _forget,
  };

  Future<dynamic> _remember(List<dynamic> args) async {
    final arguments = _parseObjectArgument(args);
    if (arguments == null ||
        arguments.length != 1 ||
        !arguments.containsKey('fact')) {
      return jsonEncode(<String, String>{'error': 'invalid_arguments'});
    }
    final rawFact = arguments['fact'];
    if (rawFact is! String || rawFact.trim().isEmpty) {
      return jsonEncode(<String, String>{'error': 'invalid_fact'});
    }

    final result = await appServices.find<MemoryBus>().writeEpisodeWithResult(
      Episode(
        when: DateTime.now().toUtc(),
        what: rawFact.trim(),
        kind: EpisodeKind.fact,
        salience: 0.7,
        retentionClass: EpisodeRetentionClass.durable,
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
        : 'success';
    final output = <String, Object?>{
      'status': status,
      'disposition': result.disposition.name,
      'reviewState': reviewState?.name,
      'created': result.created,
      'projected': result.projected,
    };
    if (episodeId != null) output['episodeId'] = episodeId;
    final reason = result.reason;
    if (reason != null) output['reason'] = reason;
    return jsonEncode(output);
  }

  Future<dynamic> _forget(List<dynamic> args) async {
    if (agentId != 'self') return '{"error":"owner_only"}';
    Map<String, dynamic> navigation;
    try {
      final control = _appControlOverride ?? AppControlSkill(agentId: agentId);
      final receipt = await Future<dynamic>.sync(
        () => control.methods['execute']!(<dynamic>[
          <String, Object?>{'page': 'memory_ledger'},
        ]),
      );
      navigation = jsonDecode(receipt.toString()) as Map<String, dynamic>;
    } on Object {
      navigation = <String, dynamic>{'error': 'navigation_unavailable'};
    }
    final opened =
        navigation['status'] == 'ok' && navigation['page'] == 'memory_ledger';
    return jsonEncode(<String, Object?>{
      'status': 'review_required',
      'reason': opened ? 'memory_ledger_opened' : 'memory_ledger_not_opened',
      'opened': opened,
      'deleted': false,
      'page': 'memory_ledger',
      'nextAction': 'delete_memory',
      'confirmationRequired': true,
      'requiredRevisionFields': <String>[
        'episodeId',
        'expectedHeadEpisodeId',
        'expectedRevision',
        'expectedMemory',
      ],
      if (!opened)
        'navigationError': navigation['error'] ?? 'navigation_failed',
    });
  }

  Map<String, Object?>? _parseObjectArgument(List<dynamic> args) {
    if (args.length != 1) return null;
    Object? decoded = args.single;
    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } on FormatException {
        return null;
      }
    }
    if (decoded is! Map) return null;
    try {
      return Map<String, Object?>.from(decoded);
    } on Object {
      return null;
    }
  }
}

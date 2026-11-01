import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast.dart';

abstract interface class SkillMasteryGateway {
  Future<MasteryEvidenceResult> recordMasteryEvidence({
    required String agentId,
    required String eventId,
    required int skillVersionId,
    required SkillTrainingSource source,
    required int quality,
    required String digest,
    required DateTime occurredAt,
  });
}

class OpaqueSkillTrainingEvent {
  const OpaqueSkillTrainingEvent({
    required this.eventId,
    required this.agentId,
    required this.skillVersionId,
    required this.source,
    required this.quality,
    required this.digest,
    required this.occurredAt,
  });

  final String eventId;
  final String agentId;
  final int skillVersionId;
  final SkillTrainingSource source;
  final int quality;
  final String digest;
  final DateTime occurredAt;

  Map<String, Object?> toJson() => {
    'eventId': eventId,
    'agentId': agentId,
    'skillVersionId': skillVersionId,
    'source': source.wireValue,
    'quality': quality,
    'digest': digest,
    'occurredAt': occurredAt.toUtc().toIso8601String(),
  };

  factory OpaqueSkillTrainingEvent.fromJson(Map<String, Object?> json) {
    final source = switch (json['source']?.toString()) {
      'behavior' => SkillTrainingSource.behavior,
      'trial' => SkillTrainingSource.trial,
      _ => SkillTrainingSource.conversation,
    };
    return OpaqueSkillTrainingEvent(
      eventId: json['eventId']?.toString() ?? '',
      agentId: json['agentId']?.toString() ?? '',
      skillVersionId:
          int.tryParse(json['skillVersionId']?.toString() ?? '') ?? 0,
      source: source,
      quality: int.tryParse(json['quality']?.toString() ?? '') ?? 1,
      digest: json['digest']?.toString() ?? '',
      occurredAt:
          DateTime.tryParse(json['occurredAt']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

/// Reliable outbox for opaque training evidence. Network failures only defer
/// an event; they cannot block an Agent turn or cause raw conversation data to
/// be persisted.
class SkillTrainingService {
  SkillTrainingService({
    required DBService database,
    required InstalledSkillRegistry registry,
    required SkillMasteryGateway gateway,
  }) : _database = database,
       _registry = registry,
       _gateway = gateway;

  static final _outbox = StoreRef<String, Map<String, Object?>>(
    'skill_training_outbox',
  );

  final DBService _database;
  final InstalledSkillRegistry _registry;
  final SkillMasteryGateway _gateway;

  Future<void> record(OpaqueSkillTrainingEvent event) async {
    await _outbox.record(event.eventId).put(_database.raw, event.toJson());
    await flush();
  }

  Future<void> flush() async {
    final records = await _outbox.find(
      _database.raw,
      finder: Finder(sortOrders: [SortOrder('occurredAt')]),
    );
    for (final record in records) {
      final event = OpaqueSkillTrainingEvent.fromJson(record.value);
      try {
        final result = await _gateway.recordMasteryEvidence(
          agentId: event.agentId,
          eventId: event.eventId,
          skillVersionId: event.skillVersionId,
          source: event.source,
          quality: event.quality,
          digest: event.digest,
          occurredAt: event.occurredAt,
        );
        await _registry.updateMastery(
          agentId: event.agentId,
          skillVersionId: event.skillVersionId,
          mastery: result.bucket,
        );
        await _outbox.record(record.key).delete(_database.raw);
      } catch (_) {
        // Keep the opaque event for the next authenticated/online flush.
        break;
      }
    }
  }
}

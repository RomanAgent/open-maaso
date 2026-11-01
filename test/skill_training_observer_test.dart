import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/features/skills/data/skill_training_observer.dart';
import 'package:maaso/src/features/skills/data/skill_training_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
  });

  tearDown(appServices.reset);

  test(
    'conversation training sends only an opaque digest once per minute',
    () async {
      final db = appServices.put(DBService());
      await db.init(factory: databaseFactoryMemory, path: 'skill-training.db');
      final registry = InstalledSkillRegistry();
      await registry.upsert(agentId: 'self', skill: _skill());
      final gateway = _RecordingGateway();
      final training = SkillTrainingService(
        database: db,
        registry: registry,
        gateway: gateway,
      );
      var now = DateTime.utc(2026, 7, 15, 10);
      final observer = SkillTrainingObserver(
        registry: registry,
        training: training,
        now: () => now,
      );

      await observer.observeConversation(agentId: 'self', completed: true);
      await observer.observeConversation(agentId: 'self', completed: true);
      now = now.add(const Duration(minutes: 1));
      await observer.observeConversation(agentId: 'self', completed: true);

      expect(gateway.events, hasLength(2));
      expect(
        gateway.events.every((event) => event.digest.length == 64),
        isTrue,
      );
      expect(
        gateway.events.every((event) => event.digest.contains(' ')),
        isFalse,
      );
      expect(
        gateway.events.map((event) => event.source),
        everyElement(SkillTrainingSource.conversation),
      );
    },
  );
}

MarketplaceSkill _skill() => MarketplaceSkill.fromJson({
  'skillVersionId': 42,
  'submissionId': 7,
  'skillKey': 'trail-observer',
  'title': 'Trail Observer',
  'summary': 'Collects evidence.',
  'publisherId': 'author-1',
  'versionName': '1.0.0',
  'category': 'observation',
  'instruction': 'Check visible facts first.',
  'examples': ['Name two clues.'],
  'permissions': ['conversation.read'],
  'manifestDigest': List<String>.filled(64, 'a').join(),
  'isFree': true,
});

class _RecordingGateway implements SkillMasteryGateway {
  final events = <OpaqueSkillTrainingEvent>[];

  @override
  Future<MasteryEvidenceResult> recordMasteryEvidence({
    required String agentId,
    required String eventId,
    required int skillVersionId,
    required SkillTrainingSource source,
    required int quality,
    required String digest,
    required DateTime occurredAt,
  }) async {
    events.add(
      OpaqueSkillTrainingEvent(
        eventId: eventId,
        agentId: agentId,
        skillVersionId: skillVersionId,
        source: source,
        quality: quality,
        digest: digest,
        occurredAt: occurredAt,
      ),
    );
    return const MasteryEvidenceResult(bucket: MasteryBucket.growing);
  }
}

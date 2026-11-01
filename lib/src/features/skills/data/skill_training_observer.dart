import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/skills/data/installed_skill_registry.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/features/skills/data/skill_training_service.dart';

/// Deterministic local-only observer. It receives completion metadata, never
/// user text, assistant replies, action arguments, or memory content.
class SkillTrainingObserver {
  SkillTrainingObserver({
    required InstalledSkillRegistry registry,
    required SkillTrainingService training,
    DateTime Function()? now,
  }) : _registry = registry,
       _training = training,
       _now = now ?? DateTime.now;

  final InstalledSkillRegistry _registry;
  final SkillTrainingService _training;
  final DateTime Function() _now;
  final Map<String, DateTime> _lastConversationByCategory = {};

  Future<void> observeConversation({
    required String agentId,
    required bool completed,
  }) async {
    if (!completed) return;
    final cards = await _registry.installedForAgent(agentId);
    if (cards.isEmpty) return;
    final card = cards.first;
    final now = _now().toUtc();
    final rateKey = '$agentId:${card.skill.category.wireValue}';
    final previous = _lastConversationByCategory[rateKey];
    if (previous != null &&
        now.difference(previous) < const Duration(minutes: 1)) {
      return;
    }
    _lastConversationByCategory[rateKey] = now;
    await _training.record(
      OpaqueSkillTrainingEvent(
        eventId: _eventID(agentId, card.skill.skillVersionId, now),
        agentId: agentId,
        skillVersionId: card.skill.skillVersionId,
        source: SkillTrainingSource.conversation,
        quality: 2,
        digest: _digest(
          'conversation|${card.skill.category.wireValue}|completed',
        ),
        occurredAt: now,
      ),
    );
  }

  Future<void> observeBehavior({
    required String agentId,
    required bool succeeded,
  }) async {
    if (!succeeded) return;
    final cards = await _registry.installedForAgent(agentId);
    if (cards.isEmpty) return;
    final card = cards.first;
    final now = _now().toUtc();
    await _training.record(
      OpaqueSkillTrainingEvent(
        eventId: _eventID(agentId, card.skill.skillVersionId, now),
        agentId: agentId,
        skillVersionId: card.skill.skillVersionId,
        source: SkillTrainingSource.behavior,
        quality: 1,
        digest: _digest('behavior|${card.skill.category.wireValue}|success'),
        occurredAt: now,
      ),
    );
  }
}

String _digest(String descriptor) =>
    sha256.convert(descriptor.codeUnits).toString();

String _eventID(String agentId, int skillVersionId, DateTime now) =>
    'skill-${sha256.convert('$agentId|$skillVersionId|${now.microsecondsSinceEpoch}'.codeUnits).toString().substring(0, 48)}';

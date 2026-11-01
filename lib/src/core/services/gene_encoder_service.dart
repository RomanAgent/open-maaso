import 'dart:convert';

import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/core/models/agent_gene.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/episode_store.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/learned_skill_service.dart';
import 'package:maaso/src/core/services/memory_bus.dart';

class GeneEncoderService extends AppService {
  Future<GeneEncoderService> init() async => this;

  Future<AgentGene?> encode() async {
    try {
      if (!appServices.isRegistered<AgentCoreController>()) return null;
      final core = appServices.find<AgentCoreController>();
      final profile = core.profile.value;
      if (profile == null) return null;

      final memoryDigest = await _compressMemories();
      final skills = await _exportSkills();
      final keyEpisodes = await _topEpisodes();

      final gene = AgentGene(
        agentToken: profile.agentToken,
        name: profile.nickname,
        gender: profile.gender,
        voiceId: profile.voiceId,
        birthDate: profile.birthDate ?? DateTime.now(),
        deathDate: DateTime.now(),
        memoryDigest: memoryDigest,
        skills: skills,
        personalityTraits: profile.personalityTraits,
        keyEpisodes: keyEpisodes,
        signature: _sign(profile.agentToken, memoryDigest),
      );

      Log.i(
        '🧬 [GeneEncoder] encoded gene for ${profile.nickname} '
        '(${memoryDigest.length} chars, ${skills.length} skills, ${keyEpisodes.length} episodes)',
      );
      return gene;
    } catch (e) {
      Log.w('🧬 [GeneEncoder] encode failed: $e');
      return null;
    }
  }

  Future<String> _compressMemories() async {
    final parts = <String>[];

    if (appServices.isRegistered<MemoryBus>()) {
      final bus = appServices.find<MemoryBus>();
      final l3 = bus.exportableL3Block();
      if (l3.isNotEmpty) parts.add(l3);
    }

    if (parts.isEmpty) {
      return AgentPromptCatalog.text('app.memory.gene.no_memories');
    }

    final raw = parts.join('\n\n');
    if (raw.length < 500) return raw;

    try {
      if (!appServices.isRegistered<LLMProxyService>()) {
        return raw.substring(0, 500);
      }
      final llm = appServices.find<LLMProxyService>();
      final result = await llm.chat(
        AgentPromptCatalog.text(
          'app.memory.gene.compress',
          params: <String, Object?>{'memory': raw},
        ),
      );
      return result.trim().isEmpty ? raw.substring(0, 500) : result.trim();
    } catch (_) {
      return raw.substring(0, 500);
    }
  }

  Future<List<GeneSkillEntry>> _exportSkills() async {
    if (!appServices.isRegistered<LearnedSkillService>()) return [];
    final learned = appServices.find<LearnedSkillService>();
    return learned.skills.map((s) {
      final data = s.toJson();
      return GeneSkillEntry(
        id: data['id']?.toString() ?? '',
        name: data['name']?.toString() ?? '',
        summary: data['summary']?.toString() ?? '',
        triggers:
            (data['triggers'] as List?)?.map((e) => e.toString()).toList() ??
            [],
        // Skills always originate from this agent now that peer-to-peer skill
        // transfer is gone.
        sourceAgent: 'self',
      );
    }).toList();
  }

  Future<List<Map<String, Object?>>> _topEpisodes({int limit = 5}) async {
    if (!appServices.isRegistered<EpisodeStore>()) return [];
    final store = appServices.find<EpisodeStore>();
    final episodes = await store.recallEligibleRecent(limit: 100);
    episodes.sort((a, b) => b.salience.compareTo(a.salience));
    return episodes
        .take(limit)
        .map(
          (e) => {
            'what': e.what,
            'emotion': e.emotion ?? '',
            'salience': e.salience,
            'when': e.when.toIso8601String(),
          },
        )
        .toList();
  }

  String _sign(String token, String digest) {
    final combined = '$token:$digest';
    final bytes = utf8.encode(combined);
    var hash = 0;
    for (final b in bytes) {
      hash = ((hash << 5) - hash + b) & 0xFFFFFFFF;
    }
    return hash.toRadixString(16).padLeft(8, '0');
  }
}

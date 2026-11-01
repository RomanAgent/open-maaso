import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_gene.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/learned_skill_service.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';

class GeneInheritanceService extends AppService {
  Future<GeneInheritanceService> init() async => this;

  Future<bool> receiveGene(AgentGene gene) async {
    try {
      if (!_verifySignature(gene)) {
        Log.w(
          '🧬 [Inheritance] gene legacy checksum or envelope invalid — rejecting',
        );
        return false;
      }
      final preparedMemories = _prepareImportedMemories(gene);

      Log.i(
        '🧬 [Inheritance] receiving gene from ${gene.name} '
        '(born ${gene.birthDate.toIso8601String()})',
      );

      if (preparedMemories.isNotEmpty &&
          !appServices.isRegistered<MemoryBus>()) {
        throw StateError('memory_write_boundary_unavailable');
      }

      if (appServices.isRegistered<MemoryBus>()) {
        final bus = appServices.find<MemoryBus>();
        for (final prepared in preparedMemories) {
          final result = await bus.writeImportedEpisode(
            prepared.episode,
            sourceKind: 'gene',
            sourceKey: prepared.sourceKey,
            canonicalMaterial: prepared.canonicalMaterial,
          );
          if (result.disposition == MemoryWriteDisposition.rejected) {
            throw StateError(result.reason ?? 'gene_memory_import_rejected');
          }
        }
      }

      if (appServices.isRegistered<LearnedSkillService>()) {
        for (final skill in gene.skills) {
          Log.i(
            '🧬 [Inheritance] inherited skill: ${skill.name} from ${skill.sourceAgent}',
          );
        }
      }

      Log.i('🧬 [Inheritance] gene from ${gene.name} integrated successfully');
      return true;
    } catch (e) {
      Log.w('🧬 [Inheritance] receive failed: $e');
      return false;
    }
  }

  bool _verifySignature(AgentGene gene) {
    if (gene.agentToken.isEmpty ||
        gene.agentToken.trim() != gene.agentToken ||
        gene.agentToken.runes.length > 256 ||
        gene.memoryDigest.trim().isEmpty ||
        gene.memoryDigest.runes.length > _maxGeneDigestLength ||
        gene.deathDate.isBefore(gene.birthDate) ||
        gene.keyEpisodes.length > _maxGeneKeyEpisodes) {
      return false;
    }
    if (!RegExp(r'^[a-f0-9]{8}$').hasMatch(gene.signature)) return false;
    final combined = '${gene.agentToken}:${gene.memoryDigest}';
    final bytes = utf8.encode(combined);
    var hash = 0;
    for (final b in bytes) {
      hash = ((hash << 5) - hash + b) & 0xFFFFFFFF;
    }
    final expected = hash.toRadixString(16).padLeft(8, '0');
    return expected == gene.signature;
  }
}

List<_PreparedGeneMemory> _prepareImportedMemories(AgentGene gene) {
  final prepared = <_PreparedGeneMemory>[];
  final inheritedDigest = Episode(
    when: gene.deathDate.toUtc(),
    what: '[Inherited summary from ${gene.name}] ${gene.memoryDigest}',
    salience: 0.4,
    entities: <String>['inherited', gene.name],
    kind: EpisodeKind.reflection,
  );
  prepared.add(
    _prepareGeneMemory(
      gene: gene,
      payloadKind: 'memoryDigest',
      episode: inheritedDigest,
      sourceKey: '${gene.agentToken}:${gene.signature}:digest',
      sourcePayload: gene.memoryDigest,
    ),
  );

  for (var index = 0; index < gene.keyEpisodes.length; index++) {
    final sourcePayload = gene.keyEpisodes[index];
    final what = sourcePayload['what'];
    if (what is! String ||
        what.trim().isEmpty ||
        what.runes.length > _maxGeneEpisodeTextLength) {
      throw const FormatException('invalid AgentGene key episode text');
    }
    final whenValue = sourcePayload['when'];
    final when = whenValue == null
        ? gene.deathDate.toUtc()
        : whenValue is String
        ? DateTime.tryParse(whenValue)
        : null;
    if (when == null) {
      throw const FormatException('invalid AgentGene key episode timestamp');
    }
    final salienceValue = sourcePayload['salience'];
    if (salienceValue != null && salienceValue is! num) {
      throw const FormatException('invalid AgentGene key episode salience');
    }
    final salience = (salienceValue as num?)?.toDouble() ?? 0.3;
    if (!salience.isFinite || salience < 0 || salience > 1) {
      throw const FormatException('invalid AgentGene key episode salience');
    }
    final emotionValue = sourcePayload['emotion'];
    if (emotionValue != null && emotionValue is! String) {
      throw const FormatException('invalid AgentGene key episode emotion');
    }
    final episode = Episode(
      when: when.toUtc(),
      what: '[Inherited from ${gene.name}] $what',
      emotion: emotionValue as String?,
      salience: salience,
      entities: <String>['inherited', gene.name],
    );
    prepared.add(
      _prepareGeneMemory(
        gene: gene,
        payloadKind: 'keyEpisode',
        episode: episode,
        sourceKey: '${gene.agentToken}:${gene.signature}:episode:$index',
        sourcePayload: sourcePayload,
        episodeIndex: index,
      ),
    );
  }
  return prepared;
}

_PreparedGeneMemory _prepareGeneMemory({
  required AgentGene gene,
  required String payloadKind,
  required Episode episode,
  required String sourceKey,
  required Object sourcePayload,
  int? episodeIndex,
}) {
  final canonicalMaterial = _canonicalImportedEpisodeMaterial(
    gene: gene,
    payloadKind: payloadKind,
    episode: episode,
    sourcePayload: sourcePayload,
    episodeIndex: episodeIndex,
  );
  if (canonicalMaterial.runes.length > _maxCanonicalImportLength) {
    throw const FormatException('AgentGene import material is too large');
  }
  final materialDigest = sha256
      .convert(utf8.encode(canonicalMaterial))
      .toString();
  return _PreparedGeneMemory(
    episode: episode,
    // The historical checksum is not an authenticity signature. Binding the
    // local source identity to the complete item material prevents a modified
    // first import from occupying the canonical key needed by the original.
    sourceKey: '$sourceKey:$materialDigest',
    canonicalMaterial: canonicalMaterial,
  );
}

final class _PreparedGeneMemory {
  const _PreparedGeneMemory({
    required this.episode,
    required this.sourceKey,
    required this.canonicalMaterial,
  });

  final Episode episode;
  final String sourceKey;
  final String canonicalMaterial;
}

const int _maxGeneDigestLength = 32768;
const int _maxGeneKeyEpisodes = 100;
const int _maxGeneEpisodeTextLength = 4096;
const int _maxCanonicalImportLength = 65536;

String _canonicalImportedEpisodeMaterial({
  required AgentGene gene,
  required String payloadKind,
  required Episode episode,
  required Object sourcePayload,
  int? episodeIndex,
}) => jsonEncode(<String, Object?>{
  'agentToken': gene.agentToken,
  'signature': gene.signature,
  'payloadKind': payloadKind,
  'name': gene.name,
  'deathDate': gene.deathDate.toUtc().toIso8601String(),
  'episodeIndex': ?episodeIndex,
  'sourcePayload': sourcePayload,
  'derivedEpisode': <String, Object?>{
    'when': episode.when.toUtc().toIso8601String(),
    'what': episode.what,
    'emotion': episode.emotion,
    'salience': episode.salience,
    'entities': episode.entities,
    'kind': episode.kind.name,
    'retentionClass': episode.retentionClass.name,
  },
});

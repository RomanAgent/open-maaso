part of 'memory_ledger_service.dart';

final _liveMemoryOrigins = intMapStoreFactory.store('live_memory_origins.v1');
final _liveMemoryMirrors = stringMapStoreFactory.store(
  'live_memory_mirrors.v1',
);
final _liveMemoryQueues = Expando<Future<void>>(
  'memory online synchronization',
);

String _canonicalLiveMemoryMaterial(Object? value) {
  Object? canonical(Object? item) {
    if (item is Map) {
      final keys = item.keys.cast<String>().toList()..sort();
      return <String, Object?>{
        for (final key in keys) key: canonical(item[key]),
      };
    }
    if (item is List) return item.map(canonical).toList();
    return item;
  }

  return jsonEncode(canonical(value));
}

/// Reviewed records enter through the existing writer. Remote master.md/soul.md
/// files and active projections are never installed by this transport.
extension MemoryLedgerOnlineSync on MemoryLedgerService {
  String _liveMirrorKey(String id) => '$_accountScopeDigest:$id';

  // Serialize imports with their resulting local export notifications. Tracking
  // the waiting operations also makes account retirement drain the entire queue.
  Future<T> _trackOnlineMemory<T>(Future<T> Function() operation) {
    final previous = _liveMemoryQueues[this] ?? Future<void>.value();
    final next = _track(() async {
      await previous;
      if (!acceptsRequests) throw StateError('memory_ledger_retired');
      return operation();
    });
    _liveMemoryQueues[this] = next.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return next;
  }

  Future<Map<String, Object?>?> exportOnlineMemoryChange(
    int episodeId,
    String Function() newId,
  ) => _trackOnlineMemory(() async {
    if (_effectiveMode() != FeatureRolloutMode.enforce) return null;
    final detail = await getDetail(episodeId);
    if (detail == null || !detail.entry.isHead) return null;
    final entry = detail.entry, episode = detail.entry.episode;
    final removed =
        episode.reviewState == EpisodeReviewState.tombstoned ||
        episode.reviewState == EpisodeReviewState.rejected;
    if (!removed &&
        (!entry.current ||
            episode.reviewState != EpisodeReviewState.accepted ||
            episode.sourceRefs.isEmpty)) {
      return null;
    }
    var origin = await _liveMemoryOrigins
        .record(entry.lineageId)
        .get(_database);
    if (origin?['lastHead'] == episodeId) return null;
    final id = origin?['id'] as String? ?? newId();
    final version = (origin?['revision'] as int? ?? 0) + 1;
    if (!RegExp(r'^[A-Za-z0-9._:-]{8,64}$').hasMatch(id) ||
        version < 1 ||
        version > 0x1fffffffffffff) {
      throw const FormatException('invalid_live_memory_origin');
    }
    final sources = <Map<String, Object?>>[];
    if (!removed) {
      if (episode.what.runes.length > 4096 || episode.sourceRefs.length > 4) {
        return null;
      }
      for (final source in episode.sourceRefs) {
        final transcript = await sourceTranscript(source);
        if (transcript.status != MemorySourceTranscriptStatus.verified ||
            transcript.content == null ||
            transcript.content!.runes.length > 12000) {
          return null;
        }
        sources.add({
          'sourceId': source.sourceId,
          'hash': source.contentHash,
          'material': transcript.content,
        });
      }
    }
    if (!acceptsRequests) throw StateError('memory_ledger_retired');
    origin = {'id': id, 'revision': version, 'lastHead': episodeId};
    await _liveMemoryOrigins.record(entry.lineageId).put(_database, origin);
    final payload = <String, Object?>{
      'id': id,
      'revision': version,
      'state': removed ? 'tombstoned' : 'accepted',
      if (!removed) 'what': episode.what,
      if (!removed) 'when': episode.when.toUtc().toIso8601String(),
      if (!removed) 'kind': episode.kind.name,
      if (!removed) 'sources': sources,
    };
    await _liveMemoryMirrors.record(_liveMirrorKey(id)).put(_database, {
      'revision': version,
      'hash': _digest(_canonicalLiveMemoryMaterial(payload)),
      'deleted': removed,
      'episodeId': episodeId,
    });
    return payload;
  });

  Future<void> importOnlineMemoryChange(
    Map<String, Object?> payload, {
    required String sourceInstallationId,
    required bool sourceIsOwner,
    required bool Function() isCurrent,
  }) => _trackOnlineMemory(() async {
    void check() {
      if (!acceptsRequests || !isCurrent()) {
        throw StateError('memory_live_account_changed');
      }
    }

    check();
    if (_effectiveMode() != FeatureRolloutMode.enforce) return;
    final id = payload['id'],
        version = payload['revision'],
        state = payload['state'];
    if (id is! String ||
        !RegExp(r'^[A-Za-z0-9._:-]{8,64}$').hasMatch(id) ||
        version is! int ||
        version < 1 ||
        version > 0x1fffffffffffff ||
        !const {'accepted', 'tombstoned'}.contains(state) ||
        !RegExp(r'^[A-Za-z0-9._:-]{8,128}$').hasMatch(sourceInstallationId)) {
      throw const FormatException('invalid_live_memory');
    }
    final removed = state == 'tombstoned';
    if (payload.length != (removed ? 3 : 7) ||
        payload.keys.any(
          (key) => !const {
            'id',
            'revision',
            'state',
            'what',
            'when',
            'kind',
            'sources',
          }.contains(key),
        )) {
      throw const FormatException('invalid_live_memory_fields');
    }
    final material = _canonicalLiveMemoryMaterial(payload);
    if (material.runes.length > 65536) {
      throw const FormatException('live_memory_too_large');
    }
    final hash = _digest(material);
    final existing = await _liveMemoryMirrors
        .record(_liveMirrorKey(id))
        .get(_database);
    check();
    final priorVersion = existing?['revision'] as int? ?? 0;
    if (version < priorVersion || !removed && existing?['deleted'] == true) {
      return;
    }
    if (version == priorVersion) {
      if (existing?['hash'] != hash) {
        throw const FormatException('live_memory_revision_changed');
      }
      if (!removed) return;
      // A previous call may have persisted the tombstone and crashed before
      // the governance deletion. Replays must finish that deletion.
    }
    final oldId = existing?['episodeId'] as int?;
    Future<void> deleteOld() async {
      if (oldId == null) return;
      for (var attempt = 0; attempt < 3; attempt++) {
        final detail = await getDetail(oldId);
        check();
        if (detail == null ||
            detail.entry.expectedHeadEpisodeId == null ||
            detail.entry.expectedHeadRevision == null) {
          return;
        }
        final head = await getDetail(detail.entry.expectedHeadEpisodeId!);
        check();
        if (head == null ||
            head.entry.episode.reviewState == EpisodeReviewState.tombstoned ||
            head.entry.episode.reviewState == EpisodeReviewState.rejected) {
          return;
        }
        final result = await _coordinator.review(
          MemoryGovernanceCommand(
            action: MemoryGovernanceAction.delete,
            targetEpisodeId: detail.entry.expectedHeadEpisodeId!,
            expectedHeadEpisodeId: detail.entry.expectedHeadEpisodeId!,
            expectedRevision: detail.entry.expectedHeadRevision!,
          ),
        );
        check();
        if (result.status == MemoryGovernanceStatus.applied ||
            result.status == MemoryGovernanceStatus.notFound) {
          return;
        }
        if (result.status != MemoryGovernanceStatus.conflict) break;
      }
      throw StateError('live_memory_delete_failed');
    }

    if (removed) {
      await _liveMemoryMirrors.record(_liveMirrorKey(id)).put(_database, {
        'revision': version,
        'hash': hash,
        'deleted': true,
        'episodeId': ?oldId,
      });
      check();
      await deleteOld();
      return;
    }
    if (!sourceIsOwner ||
        payload['what'] is! String ||
        (payload['what'] as String).trim().isEmpty ||
        (payload['what'] as String).runes.length > 4096 ||
        payload['sources'] is! List ||
        (payload['sources'] as List).isEmpty ||
        (payload['sources'] as List).length > 4) {
      throw const FormatException('unreviewed_live_memory');
    }
    final sourceIds = <String>{};
    for (final source in payload['sources'] as List) {
      if (source is! Map ||
          source.length != 3 ||
          source['sourceId'] is! String ||
          (source['sourceId'] as String).trim().isEmpty ||
          (source['sourceId'] as String).length > 256 ||
          !sourceIds.add(source['sourceId'] as String) ||
          source['material'] is! String ||
          (source['material'] as String).trim().isEmpty ||
          (source['material'] as String).runes.length > 12000 ||
          source['hash'] != _digest(source['material'] as String)) {
        throw const FormatException('live_memory_source_integrity');
      }
    }
    if (payload['when'] is! String || payload['kind'] is! String) {
      throw const FormatException('invalid_live_memory_content');
    }
    final when = DateTime.tryParse(payload['when'] as String);
    if (when == null ||
        !when.isUtc ||
        !EpisodeKind.values.any((kind) => kind.name == payload['kind'])) {
      throw const FormatException('invalid_live_memory_content');
    }
    check();
    final result = await _coordinator.writeEpisode(
      Episode(
        when: when,
        what: payload['what'] as String,
        kind: EpisodeKind.values.byName(payload['kind'] as String),
      ),
      source: MemoryWriteSource.imported(
        sourceKind: 'companion_online_v1',
        sourceKey: '$id:$version',
        canonicalMaterial: material,
      ),
      authority: MemoryWriteAuthority.verifiedHost,
    );
    check();
    if (result.episodeId == null ||
        !const {
          MemoryWriteDisposition.accepted,
          MemoryWriteDisposition.duplicate,
        }.contains(result.disposition)) {
      throw StateError('live_memory_write_failed');
    }
    if (oldId != result.episodeId) await deleteOld();
    final detail = await getDetail(result.episodeId!);
    check();
    await _liveMemoryMirrors.record(_liveMirrorKey(id)).put(_database, {
      'revision': version,
      'hash': hash,
      'deleted': false,
      'episodeId': result.episodeId,
      'sourceInstallationId': sourceInstallationId,
    });
    if (detail != null) {
      await _liveMemoryOrigins.record(detail.entry.lineageId).put(_database, {
        'id': id,
        'revision': version,
        'lastHead': result.episodeId,
      });
    }
  });
}

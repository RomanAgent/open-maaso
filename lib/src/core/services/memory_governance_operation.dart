import 'package:maaso/src/core/models/episode.dart';

enum MemoryGovernanceAction { accept, edit, reject, delete, restore }

enum MemoryGovernanceStatus { applied, conflict, notFound, invalid }

final class MemoryEpisodeEdit {
  const MemoryEpisodeEdit({required this.what});

  final String what;
}

final class MemoryGovernanceCommand {
  MemoryGovernanceCommand({
    required this.action,
    required this.targetEpisodeId,
    required this.expectedHeadEpisodeId,
    required this.expectedRevision,
    this.edit,
  }) {
    if (targetEpisodeId < 1 || targetEpisodeId > _maxSafeStoredInt) {
      throw ArgumentError.value(targetEpisodeId, 'targetEpisodeId');
    }
    if (expectedHeadEpisodeId < 1 ||
        expectedHeadEpisodeId > _maxSafeStoredInt) {
      throw ArgumentError.value(expectedHeadEpisodeId, 'expectedHeadEpisodeId');
    }
    if (expectedRevision < 1 || expectedRevision > _maxSafeStoredInt) {
      throw ArgumentError.value(expectedRevision, 'expectedRevision');
    }
    if ((action == MemoryGovernanceAction.edit) != (edit != null)) {
      throw ArgumentError(
        action == MemoryGovernanceAction.edit
            ? 'edit payload is required for edit'
            : 'edit payload is only valid for edit',
      );
    }
    final editText = edit?.what.trim();
    if (editText != null &&
        (editText.isEmpty || editText.runes.length > 4096)) {
      throw ArgumentError.value(edit?.what, 'edit.what');
    }
  }

  static const int _maxSafeStoredInt = 0x1fffffffffffff;

  final MemoryGovernanceAction action;
  final int targetEpisodeId;
  final int expectedHeadEpisodeId;
  final int expectedRevision;
  final MemoryEpisodeEdit? edit;
}

final class MemoryGovernanceResult {
  const MemoryGovernanceResult({
    required this.status,
    required this.action,
    required this.previousEpisodeId,
    required this.episode,
    this.reason,
    this.projected = false,
  });

  const MemoryGovernanceResult.failure({
    required this.status,
    required this.action,
    required this.reason,
    this.previousEpisodeId,
  }) : episode = null,
       projected = false;

  final MemoryGovernanceStatus status;
  final MemoryGovernanceAction action;
  final int? previousEpisodeId;
  final Episode? episode;
  final String? reason;
  final bool projected;

  int? get episodeId => episode?.id;

  int? get revision => episode?.revision;
}

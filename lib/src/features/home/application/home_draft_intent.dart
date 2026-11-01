import 'package:maaso/src/features/project_build/domain/project_build_edit_target.dart';

/// A process-local, account-scoped request to prepare a draft or owned edit.
/// Consuming an intent never starts a turn or sends the draft.
final class HomeDraftIntent {
  HomeDraftIntent.gameCreation({required this.scopeKey, required this.prompt})
    : _projectEdit = null;

  HomeDraftIntent.projectBuildEditing(ProjectBuildEditTarget target)
    : scopeKey = target.appletScopeKey,
      prompt = '',
      _projectEdit = target;

  final ProjectBuildEditTarget? _projectEdit;

  /// A cold Home route carries a native object, never a URL or model JSON.
  ProjectBuildEditTarget? consumeProjectBuildEdit({
    required String currentScopeKey,
  }) {
    final target = _projectEdit;
    if (target == null || _consumed) return null;
    _consumed = true;
    if (currentScopeKey != scopeKey || !target.isCurrent) return null;
    return target;
  }

  final String scopeKey;
  final String prompt;
  bool _consumed = false;

  /// Keeps an existing draft and prevents replay, including after a scope miss.
  String? consume({
    required String currentScopeKey,
    required String existingDraft,
  }) {
    if (_consumed) return null;
    _consumed = true;
    if (scopeKey.isEmpty ||
        currentScopeKey != scopeKey ||
        prompt.trim().isEmpty) {
      return null;
    }
    if (existingDraft.contains(prompt)) return existingDraft;
    if (existingDraft.isEmpty) return prompt;
    return '$existingDraft\n\n$prompt';
  }
}

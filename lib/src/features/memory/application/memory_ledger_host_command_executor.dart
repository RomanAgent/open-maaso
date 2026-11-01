import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/memory_governance_operation.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';

import 'memory_ledger_controller.dart';
import 'memory_ledger_page_adapter.dart';

/// Account-owned Host executor for consequential Memory Ledger operations.
///
/// The mounted page contributes visibility only. Every durable write continues
/// through the typed account-scoped governance gateway.
final class MemoryLedgerHostCommandExecutor extends AppService
    implements AppControlHostCommandExecutor {
  MemoryLedgerHostCommandExecutor({MemoryLedgerReviewGateway? gateway})
    : _gatewayOverride = gateway;

  static const String acceptCommandActionId =
      'app_control.memory_ledger.${MemoryLedgerPageAdapter.acceptMemoryAction}';
  static const String editCommandActionId =
      'app_control.memory_ledger.${MemoryLedgerPageAdapter.editMemoryAction}';
  static const String rejectCommandActionId =
      'app_control.memory_ledger.${MemoryLedgerPageAdapter.rejectMemoryAction}';
  static const String deleteCommandActionId =
      'app_control.memory_ledger.${MemoryLedgerPageAdapter.deleteMemoryAction}';
  static const String restoreCommandActionId =
      'app_control.memory_ledger.${MemoryLedgerPageAdapter.restoreMemoryAction}';

  final MemoryLedgerReviewGateway? _gatewayOverride;
  int _nextRegistrationId = 0;
  _MemoryLedgerAttachment? _attachment;

  MemoryLedgerHostCommandRegistration? attachVisibleAdapter(
    MemoryLedgerPageAdapter adapter,
  ) {
    if (isClosed) {
      throw StateError('The Memory Ledger Host executor is closed.');
    }
    if (!adapter.isMounted) return null;
    final registrationId = ++_nextRegistrationId;
    _attachment = _MemoryLedgerAttachment(
      registrationId: registrationId,
      adapter: adapter,
    );
    return MemoryLedgerHostCommandRegistration._(
      executor: this,
      registrationId: registrationId,
    );
  }

  @override
  bool supports(AppControlHostCommand command) {
    final attachment = _attachment;
    final gateway = _readGateway();
    final parsed = _parseCommand(command);
    if (isClosed ||
        attachment == null ||
        !_isCurrent(attachment.registrationId, attachment.adapter) ||
        gateway == null ||
        !gateway.isAvailable ||
        parsed == null) {
      return false;
    }
    return attachment.adapter.canApplyVisibleMemoryAction(
      action: parsed.command.action,
      episodeId: parsed.command.targetEpisodeId,
      expectedHeadEpisodeId: parsed.command.expectedHeadEpisodeId,
      expectedRevision: parsed.command.expectedRevision,
      expectedMemory: parsed.expectedMemory,
    );
  }

  @override
  Future<AgentUiControlResult<Map<String, Object?>>> execute({
    required AppControlHostCommand command,
    required AppControlActionExecutionContext executionContext,
  }) async {
    final attachment = _attachment;
    final gateway = _readGateway();
    final parsed = _parseCommand(command);
    if (attachment == null ||
        gateway == null ||
        parsed == null ||
        !supports(command)) {
      return _pageNotReady();
    }
    final registrationId = attachment.registrationId;
    final authorityToken = gateway.authorityToken;
    executionContext.checkpoint();

    final result = await executionContext.guardedCall(() async {
      final currentGateway = _readGateway();
      if (!_isCurrent(registrationId, attachment.adapter) ||
          currentGateway == null ||
          !currentGateway.isAvailable ||
          !identical(currentGateway.authorityToken, authorityToken) ||
          !supports(command)) {
        throw const AppControlActionExecutionException('approval_stale');
      }
      executionContext.beginHostCommit();
      return gateway.review(parsed.command);
    });

    final episode = result.episode;
    final episodeId = result.episodeId;
    final revision = result.revision;
    if (result.status != MemoryGovernanceStatus.applied ||
        episode == null ||
        episodeId == null ||
        revision == null ||
        result.action != parsed.command.action) {
      return AgentUiControlResult<Map<String, Object?>>.failure(
        AgentUiControlResultStatus.executionFailed,
        message: result.reason ?? 'The Memory Ledger change was not applied.',
      );
    }

    attachment.adapter.requestRefresh();
    return AgentUiControlResult<Map<String, Object?>>.success(<String, Object?>{
      'status': 'applied',
      'action': result.action.name,
      'episodeId': episodeId,
      'revision': revision,
      'reviewState': episode.reviewState.name,
    });
  }

  MemoryLedgerReviewGateway? _readGateway() =>
      _gatewayOverride ?? resolveRegisteredMemoryLedgerReviewGateway();

  bool _isCurrent(int registrationId, MemoryLedgerPageAdapter adapter) {
    final current = _attachment;
    return !isClosed &&
        current?.registrationId == registrationId &&
        identical(current?.adapter, adapter) &&
        adapter.isMounted;
  }

  bool _detach(int registrationId) {
    if (_attachment?.registrationId != registrationId) return false;
    _attachment = null;
    return true;
  }

  @override
  void onClose() {
    _attachment = null;
    super.onClose();
  }

  static AgentUiControlResult<Map<String, Object?>> _pageNotReady() =>
      const AgentUiControlResult<Map<String, Object?>>.failure(
        AgentUiControlResultStatus.pageNotReady,
        message: 'The exact visible Memory Ledger revision is not ready.',
      );
}

final class MemoryLedgerHostCommandRegistration {
  MemoryLedgerHostCommandRegistration._({
    required MemoryLedgerHostCommandExecutor executor,
    required this.registrationId,
  }) : _executor = executor;

  final MemoryLedgerHostCommandExecutor _executor;
  final int registrationId;
  bool _closed = false;

  bool get isCurrent =>
      !_closed && _executor._attachment?.registrationId == registrationId;

  bool unregister() {
    if (_closed) return false;
    _closed = true;
    return _executor._detach(registrationId);
  }
}

final class _MemoryLedgerAttachment {
  const _MemoryLedgerAttachment({
    required this.registrationId,
    required this.adapter,
  });

  final int registrationId;
  final MemoryLedgerPageAdapter adapter;
}

final class _ParsedMemoryLedgerCommand {
  const _ParsedMemoryLedgerCommand(this.command, this.expectedMemory);

  final MemoryGovernanceCommand command;
  final String expectedMemory;
}

_ParsedMemoryLedgerCommand? _parseCommand(AppControlHostCommand raw) {
  if (raw.targetRoute != MemoryLedgerPageAdapter.routePath ||
      raw.target !=
          '${raw.targetRoute}#${raw.pageActionId}:'
              '${MemoryLedgerPageAdapter.semanticTarget}') {
    return null;
  }
  final action = switch ((raw.actionId, raw.pageActionId)) {
    (
      MemoryLedgerHostCommandExecutor.acceptCommandActionId,
      MemoryLedgerPageAdapter.acceptMemoryAction,
    ) =>
      MemoryGovernanceAction.accept,
    (
      MemoryLedgerHostCommandExecutor.editCommandActionId,
      MemoryLedgerPageAdapter.editMemoryAction,
    ) =>
      MemoryGovernanceAction.edit,
    (
      MemoryLedgerHostCommandExecutor.rejectCommandActionId,
      MemoryLedgerPageAdapter.rejectMemoryAction,
    ) =>
      MemoryGovernanceAction.reject,
    (
      MemoryLedgerHostCommandExecutor.deleteCommandActionId,
      MemoryLedgerPageAdapter.deleteMemoryAction,
    ) =>
      MemoryGovernanceAction.delete,
    (
      MemoryLedgerHostCommandExecutor.restoreCommandActionId,
      MemoryLedgerPageAdapter.restoreMemoryAction,
    ) =>
      MemoryGovernanceAction.restore,
    _ => null,
  };
  if (action == null) return null;

  final expectedKeys = <String>{
    'episodeId',
    'expectedHeadEpisodeId',
    'expectedRevision',
    'expectedMemory',
    if (action == MemoryGovernanceAction.edit) 'exactText',
  };
  if (raw.arguments.length != expectedKeys.length ||
      !raw.arguments.keys.toSet().containsAll(expectedKeys)) {
    return null;
  }
  final episodeId = _positiveSafeInt(raw.arguments['episodeId']);
  final expectedHeadEpisodeId = _positiveSafeInt(
    raw.arguments['expectedHeadEpisodeId'],
  );
  final expectedRevision = _positiveSafeInt(raw.arguments['expectedRevision']);
  final expectedMemory = _boundedVisibleMemory(raw.arguments['expectedMemory']);
  if (episodeId == null ||
      expectedHeadEpisodeId == null ||
      expectedRevision == null ||
      expectedMemory == null) {
    return null;
  }

  MemoryEpisodeEdit? edit;
  if (action == MemoryGovernanceAction.edit) {
    final exactText = _boundedExactText(raw.arguments['exactText']);
    if (exactText == null) return null;
    edit = MemoryEpisodeEdit(what: exactText);
  }
  try {
    return _ParsedMemoryLedgerCommand(
      MemoryGovernanceCommand(
        action: action,
        targetEpisodeId: episodeId,
        expectedHeadEpisodeId: expectedHeadEpisodeId,
        expectedRevision: expectedRevision,
        edit: edit,
      ),
      expectedMemory,
    );
  } on ArgumentError {
    return null;
  }
}

int? _positiveSafeInt(Object? value) =>
    value is int && value > 0 && value <= 9007199254740991 ? value : null;

String? _boundedExactText(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value != value.trim() ||
      value.runes.length > 4096 ||
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]').hasMatch(value)) {
    return null;
  }
  return value;
}

String? _boundedVisibleMemory(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value != value.trim() ||
      value.runes.length > 32768 ||
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F-\x9F]').hasMatch(value)) {
    return null;
  }
  return value;
}

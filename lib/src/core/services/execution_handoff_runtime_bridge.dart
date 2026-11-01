import 'package:maaso/src/core/models/account_device_handoff.dart';
import 'package:maaso/src/core/services/agent_handoff_service.dart';
import 'package:maaso/src/core/services/avatar_selection_contract.dart';

/// Creates the transfer identity from the authoritative selection, never from
/// a stale local picker. Retired products cannot be revived by a handoff.
HandoffAvatarIdentity handoffAvatarIdentityFor(
  AvatarSelectionSnapshot snapshot,
) {
  if (!snapshot.selectionAvailable || snapshot.asset.isRetiredOfficial) {
    throw StateError('handoff_model_identity_unavailable');
  }
  return HandoffAvatarIdentity(
    modelId: snapshot.asset.modelKey,
    revision: snapshot.selection.version.toString(),
  );
}

/// Transfers execution only. Local Avatar presentation is never a participant.
final class ExecutionHandoffRuntimeBridge implements AgentHandoffRuntimeBridge {
  ExecutionHandoffRuntimeBridge({
    required this.accountContext,
    required this.readModelIdentity,
    required this.isSource,
    required this.isTarget,
    required this.quiesceExecution,
    required this.retireExecution,
    required this.mountExecution,
    required this.restoreExecution,
    this.prepareExecutionRequest,
  });

  final HandoffAccountContext? Function() accountContext;
  final Future<HandoffAvatarIdentity> Function(HandoffAccountContext)
  readModelIdentity;
  final bool Function(AccountDeviceHandoff) isSource, isTarget;
  final Future<void> Function() quiesceExecution, retireExecution;
  final Future<bool> Function() mountExecution, restoreExecution;
  final Future<void> Function(HandoffAccountContext)? prepareExecutionRequest;
  HandoffAccountContext? _sourceContext, _targetContext;
  String? _sourceId, _targetId;
  Object? _targetPreparation;
  bool _sourceQuiesced = false, _sourceRetired = false, _sourceRestored = false;
  bool _targetVerified = false, _targetMounted = false;

  @override
  bool get isAvailable => accountContext() != null;

  HandoffAccountContext _account() {
    final current = accountContext();
    if (current == null) throw StateError('handoff_account_unavailable');
    return current;
  }

  void _current(HandoffAccountContext captured) {
    if (accountContext()?.matches(captured) != true) {
      throw StateError('handoff_account_changed');
    }
  }

  @override
  Future<HandoffAvatarIdentity> currentAvatar() async {
    final captured = _account();
    final prepare = prepareExecutionRequest;
    if (prepare != null) {
      await prepare(captured);
      _current(captured);
    }
    final identity = await readModelIdentity(captured);
    _current(captured);
    return identity;
  }

  @override
  Future<void> prepareTarget(AccountDeviceHandoff handoff) async {
    final captured = _account();
    if (!isTarget(handoff)) throw StateError('handoff_target_mismatch');
    if (_targetId == handoff.handoffId && _targetContext != null) {
      _current(_targetContext!);
    } else {
      _targetMounted = false;
    }
    _targetContext = captured;
    _targetId = handoff.handoffId;
    _targetVerified = false;
    final token = _targetPreparation = Object();
    final identity = await readModelIdentity(captured);
    _current(captured);
    if (!identical(token, _targetPreparation)) {
      throw StateError('handoff_preparation_changed');
    }
    if (!identity.matches(handoff.avatarModel)) {
      throw StateError('handoff_model_selection_changed');
    }
    _requireTarget(handoff);
    _targetVerified = true;
  }

  Future<void> _prepareSource(AccountDeviceHandoff handoff) async {
    final captured = _account();
    if (!isSource(handoff)) throw StateError('handoff_source_mismatch');
    if (_sourceId == handoff.handoffId && _sourceContext != null) {
      _current(_sourceContext!);
    } else {
      _sourceQuiesced = false;
      _sourceRetired = false;
      _sourceRestored = false;
    }
    // Cancellation may follow a rejected model read before execution drained.
    // Retain this account fence so rollback can still validate its source.
    _sourceContext = captured;
    _sourceId = handoff.handoffId;
    final identity = await readModelIdentity(captured);
    _requireSource(handoff);
    if (!identity.matches(handoff.avatarModel)) {
      throw StateError('handoff_model_selection_changed');
    }
  }

  @override
  Future<void> quiesceSource(AccountDeviceHandoff handoff) async {
    await _prepareSource(handoff);
    if (_sourceQuiesced) return;
    await quiesceExecution();
    _requireSource(handoff);
    _sourceQuiesced = true;
  }

  void _requireSource(AccountDeviceHandoff handoff) {
    final captured = _sourceContext;
    if (captured == null || _sourceId != handoff.handoffId) {
      throw StateError('handoff_source_changed');
    }
    _current(captured);
    if (!isSource(handoff)) throw StateError('handoff_source_mismatch');
  }

  void _requireTarget(AccountDeviceHandoff handoff) {
    final captured = _targetContext;
    if (captured == null || _targetId != handoff.handoffId) {
      throw StateError('handoff_target_changed');
    }
    _current(captured);
    if (!isTarget(handoff)) throw StateError('handoff_target_mismatch');
  }

  Future<void> _ensureTarget(AccountDeviceHandoff handoff) async {
    if (_targetId == handoff.handoffId && _targetContext != null) {
      _requireTarget(handoff);
      if (_targetVerified) return;
    }
    // A restarted worker can first discover the canonical committed transfer.
    // Failed committed work is cancelled locally before a retry, so it also
    // needs a fresh readonly identity receipt without loading any renderer.
    if (!handoff.isCommitted) throw StateError('handoff_target_changed');
    await prepareTarget(handoff);
  }

  @override
  Future<void> exitSource(AccountDeviceHandoff handoff) async {
    _requireSource(handoff);
  }

  @override
  Future<void> retireSource(AccountDeviceHandoff handoff) async {
    if (_sourceContext == null || _sourceId != handoff.handoffId) {
      if (!handoff.isCommitted) throw StateError('handoff_source_changed');
      await _prepareSource(handoff);
    }
    _requireSource(handoff);
    if (_sourceRetired) return;
    await retireExecution();
    _requireSource(handoff);
    _sourceRetired = true;
  }

  @override
  Future<void> mountTarget(AccountDeviceHandoff handoff) async {
    await _ensureTarget(handoff);
    if (_targetMounted) return;
    if (!await mountExecution()) {
      throw StateError('handoff_target_runtime_mount_failed');
    }
    _requireTarget(handoff);
    _targetMounted = true;
  }

  @override
  Future<void> enterTarget(AccountDeviceHandoff handoff) async {
    await _ensureTarget(handoff);
    _requireTarget(handoff);
    // Completion acknowledgements can be lost. Keep the verified context and
    // execution receipt so another valid retry never depends on an animation.
    _targetPreparation = null;
  }

  @override
  Future<void> restoreSource(AccountDeviceHandoff handoff) async {
    _requireSource(handoff);
    if (_sourceRestored) return;
    if (!await restoreExecution()) {
      throw StateError('handoff_source_restore_failed');
    }
    _requireSource(handoff);
    _sourceRestored = true;
  }

  @override
  Future<void> cancelTarget(AccountDeviceHandoff handoff) async {
    if (_targetId != null && _targetId != handoff.handoffId) return;
    _targetPreparation = null;
    _targetVerified = false;
    if (handoff.isCommitted) return;
    _targetContext = null;
    _targetId = null;
    _targetMounted = false;
  }
}

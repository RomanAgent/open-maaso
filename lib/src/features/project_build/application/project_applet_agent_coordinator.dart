import 'dart:async';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/surface_play/data/surface_companion_call_ledger.dart';
import 'project_applet_agent_driver.dart';
import 'project_applet_control_service.dart';

/// Account-owned listener for a user's native "allow Agent" operation. It
/// reuses the mounted runtime, provider and turn lane without another chat().
final class ProjectAppletAgentCoordinator extends AppService {
  ProjectAppletAgentCoordinator({
    required this.control,
    required this.calls,
    required AgentRuntime? Function(String) runtimeForAgent,
    required bool Function() isCurrent,
  }) : _runtimeForAgent = runtimeForAgent,
       _isCurrent = isCurrent;
  final ProjectAppletControlService control;
  final SurfaceCompanionCallLedger calls;
  final AgentRuntime? Function(String) _runtimeForAgent;
  final bool Function() _isCurrent;
  StreamSubscription<ProjectAppletGrant>? _grants;
  ProjectAppletAgentDriver? _driver;
  final _workers = <Worker>[];
  final _pending = <Future<void>>{};
  final status = 'idle'.obs;
  bool _closed = false;
  Future<void>? _drain;
  Future<void> _transition = Future<void>.value();
  int _grantGeneration = 0;

  void start() {
    _grants ??= control.onGranted.listen(_granted);
  }

  void _granted(ProjectAppletGrant grant) {
    final generation = ++_grantGeneration;
    final previous = _driver;
    if (previous != null) _track(previous.close());
    _transition = _transition
        .then((_) async {
          await previous?.close();
          if (_closed || generation != _grantGeneration || !grant.isCurrent) {
            return;
          }
          _attach(grant);
        })
        .catchError((Object _, StackTrace _) {
          if (!_closed && generation == _grantGeneration) {
            status.value = 'stopped';
          }
        });
  }

  void _attach(ProjectAppletGrant grant) {
    final previous = _driver;
    _driver = null;
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    if (previous != null) _track(previous.close());
    final runtime = _runtimeForAgent(grant.agentId);
    if (_closed || !_isCurrent() || runtime == null || !grant.isCurrent) return;
    bool current() =>
        !_closed &&
        _isCurrent() &&
        grant.isCurrent &&
        identical(_runtimeForAgent(grant.agentId), runtime);
    final driver = ProjectAppletAgentDriver(
      control: control,
      grant: grant,
      calls: calls,
      client: runtime.llmClient,
      runInLane: (generate) =>
          runtime.runGameCommentaryDecision(generate, isCurrent: current),
      canRun: () => current() && runtime.canAcceptSurfacePlayDecision,
      canDispatch: () => current() && runtime.isCurrentSurfacePlayDecision,
    );
    _driver = driver;
    void wake() {
      if (identical(_driver, driver)) driver.notifyAvailabilityChanged();
    }

    _workers.addAll([
      runtime.turn.state.listen((_) => wake()),
      runtime.isSpeaking.listen((_) => wake()),
      runtime.surfacePlayAvailabilityRevision.listen((_) => wake()),
    ]);
    driver.statuses.listen((value) {
      if (!_closed && identical(_driver, driver)) status.value = value;
    });
    driver.start();
  }

  void _track(Future<void> future) {
    _pending.add(future);
    unawaited(
      future.then<void>(
        (_) => _pending.remove(future),
        onError: (Object _, StackTrace _) {
          _pending.remove(future);
        },
      ),
    );
  }

  Future<void> deactivateAndDrain() {
    _closed = true;
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    return _drain ??= () async {
      await _grants?.cancel();
      await _transition;
      await _driver?.close();
      await Future.wait(_pending.toList());
    }();
  }

  @override
  void onClose() {
    unawaited(deactivateAndDrain());
    super.onClose();
  }
}

import 'package:flutter/services.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_behavior_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_background_task_work.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_lookup_phone_controller.dart';
export 'package:maaso/src/features/agent/application/avatar/avatar_background_task_work.dart'
    show AvatarBackgroundTaskWorkOwner;
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';

typedef ApplyAvatarAct = Future<AvatarBehaviorResult> Function(AvatarAct act);

class AgentBodyController {
  AgentBodyController({
    String agentId = 'self',
    ApplyAvatarAct? applyAct,
    AvatarBehaviorDirector? director,
    AvatarBackgroundTaskWorkController? backgroundTaskWork,
    AvatarLookupPhoneController? lookupPhone,
  }) : _applyAct =
           applyAct ??
           (director ?? AvatarBehaviorDirector(agentId: agentId)).applyAct,
       _lookupPhone =
           lookupPhone ?? AvatarLookupPhoneController(agentId: agentId) {
    _backgroundTaskWork =
        backgroundTaskWork ??
        AvatarBackgroundTaskWorkController(
          agentId: agentId,
          isTemporarilyBlocked: _lookupPhone.isReleasingFor,
        );
  }

  final ApplyAvatarAct _applyAct;
  late final AvatarBackgroundTaskWorkController _backgroundTaskWork;
  final AvatarLookupPhoneController _lookupPhone;

  void Function()? beginLookupPhone({
    required bool Function() isCurrent,
    Future<void>? cancelled,
  }) {
    if (_backgroundTaskWork.hasCurrentWork) return null;
    return _lookupPhone.begin(
      isCurrent: () => !_backgroundTaskWork.hasCurrentWork && isCurrent(),
      cancelled: cancelled,
    );
  }

  AvatarBackgroundTaskWorkOwner? get shareableBackgroundTaskWorkOwner =>
      _backgroundTaskWork.shareableOwner;

  /// Returns immediately: the generation worker does not await a walk or
  /// renderer. Call after a job is admitted, and retain this exact owner.
  AvatarBackgroundTaskWorkOwner? beginBackgroundTaskWork({
    required String jobId,
    required int attempt,
    required String scopeKey,
    required bool Function() isCurrent,
  }) {
    final owner = _backgroundTaskWork.begin(
      jobId: jobId,
      attempt: attempt,
      scopeKey: scopeKey,
      isCurrent: isCurrent,
    );
    if (owner != null) _lookupPhone.cancelCurrent();
    return owner;
  }

  Future<void> endBackgroundTaskWork(AvatarBackgroundTaskWorkOwner? owner) =>
      _backgroundTaskWork.end(owner);

  Future<void> waitForBackgroundTaskWorkIdle() =>
      _backgroundTaskWork.waitForIdle();

  Future<void> dispose() => Future.wait<void>([
    _lookupPhone.dispose(),
    _backgroundTaskWork.dispose(),
  ]).then((_) {});

  Future<AvatarBehaviorResult> reactToTurnStart(AgentTurnPlan plan) async {
    final act = intentForTurnStart(plan);
    if (act == null) {
      return const AvatarBehaviorResult(
        applied: false,
        reason: 'no local body intent',
      );
    }
    return _applyActWhenReady(act);
  }

  Future<AvatarBehaviorResult> reactToTaskCompleted(AgentTaskJob job) async {
    final act = intentForTaskCompleted(job);
    if (act == null) {
      return const AvatarBehaviorResult(
        applied: false,
        reason: 'no task completion body intent',
      );
    }
    return _applyActWhenReady(act);
  }

  Future<AvatarBehaviorResult> reactToTaskFailed(AgentTaskJob job) async {
    final act = intentForTaskFailed(job);
    if (act == null) {
      return const AvatarBehaviorResult(
        applied: false,
        reason: 'no task failure body intent',
      );
    }
    return _applyActWhenReady(act);
  }

  Future<AvatarBehaviorResult> applyRemoteIntent(Map<dynamic, dynamic> json) {
    final act = AvatarAct.fromJson(json);
    if (act.mood == 'none' &&
        act.gesture == 'none' &&
        act.gaze == 'none' &&
        act.posture == 'none') {
      return Future.value(
        const AvatarBehaviorResult(
          applied: false,
          reason: 'empty remote body intent',
        ),
      );
    }
    return _applyActWhenReady(act);
  }

  Future<AvatarBehaviorResult> _applyActWhenReady(AvatarAct act) async {
    if (_backgroundTaskWork.hasCurrentWork) {
      return const AvatarBehaviorResult(
        applied: false,
        reason: 'background task work owns the body presentation',
      );
    }
    try {
      return await _applyAct(act);
    } on PlatformException catch (error) {
      if (error.code != 'not_ready') rethrow;
      return const AvatarBehaviorResult(
        applied: false,
        reason: 'avatar renderer not ready',
      );
    }
  }

  AvatarAct? intentForTurnStart(AgentTurnPlan plan) {
    return switch (plan.route) {
      AgentTurnRoute.simpleQa => const AvatarAct(
        mood: 'thinking',
        gesture: 'think',
        gaze: 'down',
        style: 'subtle',
        intensity: 0.52,
        durationMs: 1050,
      ),
      AgentTurnRoute.chitchat => AvatarAct(
        mood: _friendlyMood(plan.mood),
        gesture: 'listen',
        gaze: 'user',
        style: 'subtle',
        intensity: 0.45,
        durationMs: 950,
      ),
      AgentTurnRoute.ambiguousTask => const AvatarAct(
        mood: 'confused',
        gesture: 'shrug',
        gaze: 'user',
        style: 'subtle',
        intensity: 0.55,
        durationMs: 1100,
      ),
      AgentTurnRoute.riskyAction => const AvatarAct(
        mood: 'serious',
        gesture: 'listen',
        gaze: 'user',
        style: 'subtle',
        intensity: 0.5,
        durationMs: 1000,
      ),
      AgentTurnRoute.explicitTask =>
        plan.requiresBackgroundJob
            ? const AvatarAct(
                mood: 'thinking',
                gesture: 'think',
                gaze: 'down',
                style: 'subtle',
                intensity: 0.58,
                durationMs: 1300,
              )
            : null,
      AgentTurnRoute.structured => null,
    };
  }

  AvatarAct? intentForTaskCompleted(AgentTaskJob job) {
    return switch (job.taskKind) {
      AgentTaskKind.gameGeneration ||
      AgentTaskKind.surfaceGeneration => const AvatarAct(
        mood: 'excited',
        gesture: 'explain',
        gaze: 'surface',
        style: 'normal',
        intensity: 0.68,
        durationMs: 1400,
      ),
      AgentTaskKind.skillTask || AgentTaskKind.none => const AvatarAct(
        mood: 'calm',
        gesture: 'nod',
        gaze: 'user',
        style: 'subtle',
        intensity: 0.5,
        durationMs: 1000,
      ),
    };
  }

  AvatarAct? intentForTaskFailed(AgentTaskJob job) {
    return switch (job.taskKind) {
      AgentTaskKind.gameGeneration ||
      AgentTaskKind.surfaceGeneration ||
      AgentTaskKind.skillTask ||
      AgentTaskKind.none => const AvatarAct(
        mood: 'confused',
        gesture: 'shrug',
        gaze: 'user',
        style: 'subtle',
        intensity: 0.56,
        durationMs: 1200,
      ),
    };
  }

  static String _friendlyMood(String mood) {
    final normalized = mood.trim().toLowerCase();
    if (normalized.isEmpty ||
        normalized == 'neutral' ||
        normalized == 'attentive') {
      return 'calm';
    }
    return normalized;
  }
}

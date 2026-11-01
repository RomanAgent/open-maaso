import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_recovery_service.dart';
import 'package:maaso/src/features/widgets_hub/presentation/widgets_hub_page.dart'
    show openAppInvocationTarget;
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_turn_input.dart';
import 'dart:async';
import 'home_composer_submission.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_catalog.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_compatibility.dart';
import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';
import 'package:maaso/src/features/auth/application/login_doorway_coordinator.dart';
import 'package:maaso/src/core/services/live_companion_sync_service.dart';
import 'dart:convert';
import 'dart:typed_data';
import 'package:maaso/src/features/agent/application/conversation/conversation_reply_coordinator.dart'
    show newConversationTurnId;
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';
import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/agent/application/project_build/project_reference_input.dart';
import 'package:maaso/src/features/chat/data/chat_video.dart';

import 'package:flutter/material.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/agent_runtime.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_turn_controller.dart';
import 'package:maaso/src/features/agent/application/orchestration/agent_turn_orchestrator.dart';
import 'package:maaso/src/features/agent/application/local_agent_runtime.dart';
import 'package:maaso/src/features/agent/application/local_brain_service.dart';
import 'package:maaso/src/features/agent/application/local_host_skill_candidate_activator.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/local_model_action_planner.dart';
import 'package:maaso/src/features/agent/application/local_skill_invoker.dart';
import 'package:maaso/src/features/agent/application/local_skill_retriever.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/features/agent/application/companion/agent_initiated_response.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/application/reflex_engine.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_context.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_style_prompt.dart';
import 'package:maaso/src/features/agent/application/persona/conversation_delivery_policy.dart';
import 'package:maaso/src/features/agent/application/maaso_tts_plugin.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';
import 'package:maaso/src/features/agent/application/skills/app_navigate_skill.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/agent/application/turn_router_gateway.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_boot_controller.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_card_controller.dart';
import 'package:maaso/src/features/settings/application/llm_config_controller.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/hosted_llm_failure.dart';
import 'package:maaso/src/features/skills/data/skill_training_observer.dart';
import 'package:maaso/src/core/widgets/agent_cards.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/services/agent_behavior_config.dart';
import 'package:maaso/src/core/services/agent_presence_service.dart';
import 'package:maaso/src/core/services/cloud_llm_health_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/debug_stats_service.dart';
import 'package:maaso/src/core/utils/text_filters.dart';
import 'package:maaso/src/core/services/delayed_choice_executor.dart';
import 'package:maaso/src/core/services/emotion_sensor_service.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/local_llm_service.dart';
import 'package:maaso/src/core/services/maaso_agent_mode_service.dart';
import 'package:maaso/src/core/services/master_profile_service.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/core/services/outreach_feedback_collector.dart';
import 'package:maaso/src/core/services/conversation_memory_service.dart';
import 'package:maaso/src/core/services/conversation_preference_service.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/services/soul_service.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/core/services/voice_prosody_service.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/widgets/widget_stage_controller.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/project_build/data/project_build_v2_repository.dart';
import 'package:maaso/src/features/project_build/application/project_build_v2_tasks.dart';
import 'package:maaso/src/features/project_build/domain/project_reference_selection.dart';
import 'package:maaso/src/features/agent/application/surface/surface_creation_authority.dart';
import 'package:maaso/src/features/agent/application/surface_intent.dart';

/// Drives the 3D avatar screen.
///
/// State surface:
/// * [latestBubble] — most recent AI reply, shown as a floating bubble over
///   the 3D avatar.  Stays until the next reply replaces it.
/// * [isThinking]   — show typing indicator inside / next to the bubble.
/// * [input] / [send] — drive the bottom chat bar.
class HomeController extends AppController {
  final DBService _db = appServices.find<DBService>();
  final AgentRuntimeRegistry _registry = appServices
      .find<AgentRuntimeRegistry>();

  /// Reflex layer for the local-only fallback path.  When no cloud key is
  /// configured there is no [AgentRuntime] to own a [ReflexEngine], so the
  /// home controller carries its own — this is what gives the local
  /// fallback the same route + emotion preemit + IntentWave + WorkingMemory
  /// sweep the cloud path gets.
  late final ReflexEngine _fallbackReflex = ReflexEngine(agentId: 'self');
  // Only the runtime-less fallback owns this session. No private boundary is
  // persisted or shared with another runtime/controller/account.
  final ConversationStyleSession _fallbackConversationStyle =
      ConversationStyleSession();
  String? _fallbackConversationStyleScope;
  Worker? _fallbackPolicyWorker;
  Worker? _fallbackSettingsWorker;
  Worker? _fallbackContactWorker;
  Timer? _fallbackPolicyExpiry;
  ConversationStyleSnapshot? _fallbackDeliveryStyle;
  AppCapabilitySnapshotService? get _capabilitySnapshots =>
      appServices.maybeFind<AppCapabilitySnapshotService>();
  late final LocalHostSkillCandidateActivator _localHostSkills =
      LocalHostSkillCandidateActivator(
        agentId: 'self',
        specs: SkillCatalog.all,
        capabilitySnapshotService: _capabilitySnapshots,
      );
  ScopedLocalSkillRetrieverCache<AppLocale>? _localSkillRetrievers;
  int _localSkillAvailabilityGeneration = -1;

  final selectedAppInvocation = Rxn<AppInvocationSelection>();
  final selectingAppInvocation = false.obs;
  AppInvocationCatalog? get invocationCatalog =>
      appServices.maybeFind<AppInvocationCatalog>();
  Object _composerOwner = Object();
  String? _composerScope;
  Object? _composerMount;
  int? _composerMountGeneration;
  int _composerRevision = 0, _selectionGeneration = 0;
  int _openInvocationGeneration = 0;
  final List<Worker> _composerWorkers = [];
  TextEditingValue? _observedComposerValue;
  List<PreparedChatMedia> _observedComposerMedia = const [];
  Object? _observedInvocation, _observedProjectEdit, _observedAppletEdit;
  bool? _observedPlan;

  Object get composerOwnerToken {
    _refreshComposerOwner();
    return _composerOwner;
  }

  int get composerDraftRevision {
    _refreshComposerOwner();
    final media = pendingMedia.toList(growable: false);
    final changed =
        _observedComposerValue != inputController.value ||
        media.length != _observedComposerMedia.length ||
        media.indexed.any(
          (e) => !identical(e.$2, _observedComposerMedia[e.$1]),
        ) ||
        !identical(_observedInvocation, selectedAppInvocation.value) ||
        !identical(_observedProjectEdit, projectBuildEditTarget.value) ||
        !identical(_observedAppletEdit, appletEditReference.value) ||
        _observedPlan != planRequested.value;
    if (changed) {
      _composerRevision++;
      _observedComposerValue = inputController.value;
      _observedComposerMedia = media;
      _observedInvocation = selectedAppInvocation.value;
      _observedProjectEdit = projectBuildEditTarget.value;
      _observedAppletEdit = appletEditReference.value;
      _observedPlan = planRequested.value;
    }
    return _composerRevision;
  }

  void _refreshComposerOwner() {
    if (isClosed) return;
    final scope = AppletLocalOwnership.currentScopeKey();
    final mount = _accountLifecycle?.activeMount;
    final generation = _accountLifecycle?.generation;
    if (_composerScope == scope &&
        identical(_composerMount, mount) &&
        _composerMountGeneration == generation) {
      return;
    }
    final initialized = _composerScope != null;
    _composerScope = scope;
    _composerMount = mount;
    _composerMountGeneration = generation;
    _composerOwner = Object();
    _composerRevision++;
    _selectionGeneration++;
    if (initialized) {
      selectedAppInvocation.value = null;
      selectingAppInvocation.value = false;
      inputController.clear();
      pendingMedia.clear();
    }
  }

  Future<AppInvocationResolution?> selectAppInvocation(
    AppInvocationCatalogEntry entry, {
    bool Function()? canContinue,
  }) async {
    final catalog = invocationCatalog;
    if (isClosed || catalog == null || canContinue?.call() == false) {
      return null;
    }
    final owner = composerOwnerToken;
    final generation = ++_selectionGeneration;
    selectingAppInvocation.value = true;
    try {
      final result = await catalog.resolveSelection(entry);
      if (isClosed ||
          generation != _selectionGeneration ||
          canContinue?.call() == false ||
          !identical(owner, composerOwnerToken) ||
          !identical(catalog, invocationCatalog)) {
        return null;
      }
      if (result.selection != null &&
          (result.status ==
                  AppInvocationCompatibilityStatus.pendingVerification ||
              result.status == AppInvocationCompatibilityStatus.compatible) &&
          result.descriptor?.actions.isNotEmpty == true) {
        clearProjectBuildEditTarget();
        clearAppletEditReference();
        selectedAppInvocation.value = result.selection;
      }
      return result;
    } finally {
      if (!isClosed &&
          generation == _selectionGeneration &&
          identical(owner, composerOwnerToken)) {
        selectingAppInvocation.value = false;
      }
    }
  }

  void clearAppInvocation() {
    _selectionGeneration++;
    selectedAppInvocation.value = null;
    selectingAppInvocation.value = false;
  }

  /// Explicitly opening a work leaves the text, attachments and invocation
  /// selection untouched. The picker supplies a guard for its pending request.
  Future<bool> openAppInvocation(
    AppInvocationCatalogEntry entry, {
    required bool Function() canContinue,
  }) async {
    final catalog = invocationCatalog;
    if (isClosed || catalog == null || !canContinue()) return false;
    final owner = composerOwnerToken;
    final generation = ++_openInvocationGeneration;
    bool ownerCurrent() =>
        !isClosed &&
        identical(owner, composerOwnerToken) &&
        identical(catalog, invocationCatalog);
    final target = await catalog.resolveOpen(entry);
    if (!ownerCurrent() ||
        generation != _openInvocationGeneration ||
        !canContinue() ||
        !target.isCurrent) {
      return false;
    }
    return presentAppInvocationTarget(target, canContinue: ownerCurrent);
  }

  @protected
  Future<bool> presentAppInvocationTarget(
    AppInvocationOpenTarget target, {
    required bool Function() canContinue,
  }) => openAppInvocationTarget(target, canContinue: canContinue);

  /// Explicit receipt-only recovery never consumes the visible typed draft.
  Future<void> recoverInvocation(AppInvocationChatReference reference) async {
    final service = appServices.maybeFind<AppInvocationRecoveryService>();
    if (isClosed ||
        service == null ||
        _analyzingMedia ||
        preparingMedia.value) {
      return;
    }
    final owner = composerOwnerToken;
    final generation = ++_sendGeneration;
    bool current() =>
        !isClosed &&
        identical(owner, composerOwnerToken) &&
        generation == _sendGeneration &&
        identical(
          service,
          appServices.maybeFind<AppInvocationRecoveryService>(),
        );
    final locale = AgentPromptCatalog.currentLocale;
    try {
      await _registry.runAccountOperation(() async {
        final recovery = await service.prepareRecovery(
          reference,
          sessionId: 'self',
          isOwnerCurrent: current,
        );
        final runtime = _runtime ?? await _safeAttach();
        if (!current() ||
            !_canExecuteHere ||
            runtime?.usesConversationTurns != true) {
          return;
        }
        final text = locale.name.startsWith('zh')
            ? '取回${reference.sourceTitle}的调用结果'
            : 'Retrieve the result from ${reference.sourceTitle}';
        final submission = HomeComposerSubmission(
          token: newConversationTurnId(),
          ownerToken: owner,
          isOwnerCurrent: current,
          scopeKey: reference.scopeKey,
          locale: locale,
          text: text,
        );
        await _sendConversation(
          runtime!,
          text,
          generation: generation,
          submission: submission,
          onAccepted: () {},
          onFailed: () {},
          appletScopeKey: reference.scopeKey,
          recovery: recovery,
        );
      });
    } catch (_) {
      if (current()) {
        _mediaIssue(
          '暂时无法取回结果，原动作没有重复执行',
          'The result is unavailable. The original action was not repeated.',
        );
      }
    }
  }

  Future<void> restoreInvocationDraft(
    AppInvocationChatReference reference,
  ) async {
    final service = appServices.maybeFind<AppInvocationRecoveryService>();
    if (isClosed ||
        service == null ||
        _analyzingMedia ||
        preparingMedia.value) {
      return;
    }
    final selected = selectedAppInvocation.value;
    if (inputController.text.isNotEmpty ||
        pendingMedia.isNotEmpty ||
        projectBuildEditTarget.value != null ||
        appletEditReference.value != null ||
        planRequested.value ||
        selectingAppInvocation.value ||
        (selected != null &&
            (selected.identity.sourceId != reference.sourceId ||
                selected.identity.revisionId != reference.revisionId ||
                selected.identity.sourceDigest != reference.sourceDigest))) {
      _mediaIssue(
        '请先发送或清空当前草稿，再恢复这次输入',
        'Send or clear the current draft before restoring this input.',
      );
      return;
    }
    final owner = composerOwnerToken;
    final revision = composerDraftRevision;
    bool current() =>
        !isClosed &&
        identical(owner, composerOwnerToken) &&
        revision == composerDraftRevision &&
        identical(
          service,
          appServices.maybeFind<AppInvocationRecoveryService>(),
        );
    try {
      final draft = await service.loadDraft(
        reference,
        sessionId: 'self',
        isOwnerCurrent: current,
      );
      if (!current() || !draft.isCurrent) return;
      _selectionGeneration++;
      inputController.value = TextEditingValue(
        text: draft.text,
        selection: TextSelection.collapsed(offset: draft.text.length),
      );
      pendingMedia.assignAll(draft.images);
      selectedAppInvocation.value = draft.selection;
      if (draft.sourceUnavailable) {
        _mediaIssue(
          '已恢复文字和图片；原作品版本不可用，请重新选择',
          'Text and images restored. Select a work again; the original version is unavailable.',
        );
      }
    } catch (_) {
      if (current()) {
        _mediaIssue('这份输入暂时无法恢复', 'This input cannot be restored right now.');
      }
    }
  }

  HomeComposerSubmission _captureComposerSubmission({String? voiceText}) {
    final owner = composerOwnerToken;
    final revision = composerDraftRevision;
    final locale = AgentPromptCatalog.currentLocale;
    final raw = voiceText ?? inputController.text;
    final text = raw.trim().isNotEmpty
        ? raw.trim()
        : (locale.name.startsWith('zh')
              ? '看看这个附件'
              : 'Take a look at this attachment');
    return HomeComposerSubmission(
      token: newConversationTurnId(),
      ownerToken: owner,
      isOwnerCurrent: () => !isClosed && identical(owner, composerOwnerToken),
      scopeKey: AppletLocalOwnership.currentScopeKey(),
      locale: locale,
      text: text,
      draftRevision: voiceText == null ? revision : null,
      draftValue: voiceText == null ? inputController.value : null,
      media: voiceText == null ? pendingMedia.toList() : const [],
      invocation: voiceText == null ? selectedAppInvocation.value : null,
      projectEdit: voiceText == null ? projectBuildEditTarget.value : null,
      appletEdit: voiceText == null ? appletEditReference.value : null,
      planRequested: voiceText == null && planRequested.value,
    );
  }

  HomeComposerDraftReceipt? _consumeComposerDraft(
    HomeComposerSubmission submission,
  ) {
    if (submission.isVoice ||
        !submission.isOwnerCurrent() ||
        composerDraftRevision != submission.draftRevision) {
      return null;
    }
    inputController.clear();
    if (submission.planRequested) planRequested.value = false;
    return HomeComposerDraftReceipt(
      submissionToken: submission.token,
      ownerToken: submission.ownerToken,
      revision: composerDraftRevision,
    );
  }

  void _restoreComposerDraft(
    HomeComposerSubmission submission,
    HomeComposerDraftReceipt? receipt,
  ) {
    if (receipt == null ||
        submission.isVoice ||
        !submission.isOwnerCurrent() ||
        receipt.submissionToken != submission.token ||
        !identical(receipt.ownerToken, composerOwnerToken) ||
        receipt.revision != composerDraftRevision) {
      return;
    }
    inputController.value = submission.draftValue!;
  }

  final projectBuildEditTarget = Rxn<ProjectBuildEditTarget>();

  bool beginProjectBuildEditing(ProjectBuildEditTarget target) {
    if (isClosed ||
        _chatOnlyExperimentEnabled ||
        !_canExecuteHere ||
        !target.isCurrent ||
        target.appletScopeKey != AppletLocalOwnership.currentScopeKey()) {
      return false;
    }
    _sendGeneration++;
    if (_analyzingMedia) {
      _analyzingMedia = false;
      isThinking.value = false;
    }
    unawaited(_conversationHandle?.cancel());
    clearAppletEditReference();
    clearAppInvocation();
    projectBuildEditTarget.value = target;
    return true;
  }

  void clearProjectBuildEditTarget() {
    if (projectBuildEditTarget.value == null) return;
    projectBuildEditTarget.value = null;
    _sendGeneration++;
    if (_analyzingMedia) {
      _analyzingMedia = false;
      isThinking.value = false;
    }
    unawaited(_conversationHandle?.cancel());
  }

  final pendingMedia = <PreparedChatMedia>[].obs;
  final preparingMedia = false.obs;
  bool _analyzingMedia = false;
  final inputController = TextEditingController();
  final isThinking = false.obs;
  final conversationActive = false.obs;
  final conversationRevision = 0.obs;
  AccountSessionLifecycleService? _accountLifecycle;
  Worker? _liveSyncRevisionWorker;
  bool _attachingRuntime = false;
  bool _localRuntimeAvailable = false;
  bool get _canExecuteHere =>
      _registry.canHostExecution && (_accountLifecycle?.canChatLocally ?? true);
  ConversationTurnHandle? _conversationHandle;
  StreamSubscription<ChatMessage>? _conversationMessages;
  AgentRuntime? _conversationMessageRuntime;
  String _lastInputText = '';
  int _sendGeneration = 0;

  /// Latest AI reply text — voice-first UI doesn't render this in a bubble
  /// anymore (response is heard, not read), but we still keep it cached so
  /// future "show last reply" affordances (e.g. long-press avatar) can
  /// surface it without re-querying the DB.
  final Rxn<String> latestBubble = Rxn<String>();
  DateTime? latestBubbleAt;
  String? _latestBubbleOutreachId;

  /// Recent agent-made widgets/applets/blogs, newest first — drives the home
  /// screen depth stack (small background windows the agent can pull forward).
  /// Capped to keep the background atmospheric instead of crowded.
  final RxList<AgentWidget> dockWidgets = <AgentWidget>[].obs;
  final List<Worker> _appletScopeWorkers = <Worker>[];
  String _appletScopeKey = '';
  int _dockGeneration = 0;

  /// Presentation cleanup follows the durable task tombstone. Only typed
  /// project task cards and this project's v2 widget caches are affected.
  void purgeDeletedProjectTaskCards(
    ProjectBuildV2DeletionProof proof,
    Set<String> localTaskIds, {
    required String expectedAppletScopeKey,
    required String expectedProjectBuildScopeKey,
  }) {
    if (isClosed ||
        !proof.isScopeCurrent ||
        proof.scopeKey != expectedProjectBuildScopeKey ||
        expectedAppletScopeKey != AppletLocalOwnership.currentScopeKey() ||
        localTaskIds.any(
          (id) => !_taskJobs.isTaskDeleted(
            id,
            expectedScopeKey: expectedAppletScopeKey,
          ),
        )) {
      throw StateError('project_build_scope_changed');
    }
    _dockGeneration++;
    bool matches(AgentWidget value) =>
        AppletLocalOwnership.isVisible(
          value,
          scopeKey: expectedAppletScopeKey,
        ) &&
        value.spec['rendering'] == 'projectBundle' &&
        value.spec['surfaceId'] == proof.projectId;
    dockWidgets.removeWhere(matches);
    final task = latestTaskJob.value;
    if (task != null &&
        task.appletScopeKey == expectedAppletScopeKey &&
        localTaskIds.contains(task.taskId)) {
      latestTaskJob.value = _latestTaskJobForCurrentScope(_taskJobs);
    }
    conversationRevision.value++;
  }

  /// Refresh the home dock from storage. Cheap (a single indexed read) and
  /// safe to call after any turn that may have produced a new widget.
  Future<void> loadDock() => _registry.runAccountOperation(_loadDockActive);

  Future<void> _loadDockActive() async {
    if (isClosed) return;
    final generation = ++_dockGeneration;
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    try {
      final all = await _db.getAllWidgets();
      if (isClosed ||
          generation != _dockGeneration ||
          scopeKey != AppletLocalOwnership.currentScopeKey()) {
        return;
      }
      dockWidgets.assignAll(
        all
            .where(
              (item) =>
                  AppletLocalOwnership.isVisible(item, scopeKey: scopeKey) &&
                  item.spec['cloudDelete'] == null &&
                  !isAppletPresentationPending(item),
            )
            .take(6)
            .toList(),
      );
    } catch (_) {
      /* dock is best-effort cosmetic surface */
    }
  }

  /// Mark a dock item seen (stops its "new" glow) and refresh the rail.
  /// Called when the user opens a dock tab.
  Future<void> markDockSeen(AgentWidget item) async {
    final id = item.id;
    if (id == null) return;
    try {
      await _db.markWidgetSeen(id);
      await loadDock();
    } catch (_) {
      /* best-effort */
    }
  }

  /// Latest "// thinking: …" line during multi-step iterative chat.
  /// Home page renders a transient thought bubble above the avatar.
  /// Cleared automatically a few seconds after the last update.
  final RxnString latestThought = RxnString();
  Timer? _thoughtClearTimer;

  /// Latest background task job generated by the agent. Home renders this as
  /// a compact status strip so async game/widget generation is visible without
  /// asking "生成好了吗" in chat.
  final Rxn<AgentTaskJob> latestTaskJob = Rxn<AgentTaskJob>();
  StreamSubscription<AgentTaskJobEvent>? _taskJobSub;

  /// One-shot flag set by the 🧭 Plan-mode button.  Next [send] prefixes
  /// the user message with planning instructions and forces multi-step on
  /// for that turn (then reverts the toggle if the user had it off).
  final RxBool planRequested = false.obs;

  /// Whether a chat is currently in flight in the attached runtime.
  /// Mirrored from [AgentRuntime.isProcessing] so the home UI can show
  /// the Stop chip without reaching into the runtime each frame.
  final RxBool isProcessing = false.obs;
  final RxBool isIterating = false.obs;
  final RxBool isSpeaking = false.obs;
  Worker? _processingWatcher;
  Worker? _iteratingWatcher;
  Worker? _speakingWatcher;

  /// The agent is "busy" (generating a reply OR speaking it) — the input bar
  /// turns its send button into a pause/interrupt button while this is true.
  bool get busy => isThinking.value || isProcessing.value || isSpeaking.value;

  AgentCoreController get core => appServices.find<AgentCoreController>();

  AgentPresenceService? get _presence =>
      appServices.isRegistered<AgentPresenceService>()
      ? appServices.find<AgentPresenceService>()
      : null;

  bool get _chatOnlyExperimentEnabled => _pipelineMode.pureChatOnly;

  AgentRuntime? _runtime;
  Worker? _profileWatcher;
  Worker? _startupLocalReadyWatcher;
  Worker? _startupCloudKeyWatcher;
  Worker? _startupCloudEnabledWatcher;
  Worker? _startupCloudHealthWatcher;
  Timer? _startupGreetingTimer;
  StreamSubscription<String>? _proactiveSub;
  StreamSubscription<AgentInitiatedResponse>? _committedProactiveSub;
  StreamSubscription<String>? _thinkingSub;
  bool _startupGreetingDone = false;
  bool _startupGreetingInFlight = false;

  @override
  void onInit() {
    super.onInit();
    _accountLifecycle = appServices.maybeFind<AccountSessionLifecycleService>();
    _accountLifecycle?.addListener(_reconcileAgentLocation);
    _refreshComposerOwner();
    _accountLifecycle?.addListener(_refreshComposerOwner);
    _composerWorkers.addAll(
      AppletLocalOwnership.watchScope(_refreshComposerOwner),
    );
    void observeComposer() {
      composerDraftRevision;
    }

    _composerWorkers.addAll([
      pendingMedia.listen((_) => observeComposer()),
      selectedAppInvocation.listen((_) => observeComposer()),
      projectBuildEditTarget.listen((_) => observeComposer()),
      appletEditReference.listen((_) => observeComposer()),
      planRequested.listen((_) => observeComposer()),
    ]);
    final liveSync = appServices.maybeFind<LiveCompanionSyncService>();
    _liveSyncRevisionWorker = liveSync?.revision.listen((_) {
      // Imported rows are already durable. Refreshing the visible conversation
      // performs no writes and cannot echo them to the other device.
      if (!isClosed && liveSync.isCurrent) conversationRevision.value++;
    });
    _reconcileAgentLocation();
    inputController.addListener(_observeConversationInput);
    _profileWatcher = ever(core.profile, (profile) {
      if (profile == null) return;
      _attachRuntime();
    });
    if (core.profile.value != null) _attachRuntime();
    // Kick off front-camera emotion sensing now that we're on the main
    // screen.  Fire-and-forget — failures (no permission, no camera) just
    // leave the sensor dormant; agent still functions.
    if (_canExecuteHere && appServices.isRegistered<EmotionSensorService>()) {
      final sensor = appServices.find<EmotionSensorService>();
      if (sensor.userEnabled.value) sensor.start();
    }
    // Hand the boot controller a callback it can use to *speak* through
    // our chat surface (bubble + persisted message), then trigger the
    // first-launch ceremony (kick LLM + voice loads, wire ready listeners).
    if (_canExecuteHere && appServices.isRegistered<AgentBootController>()) {
      final boot = appServices.find<AgentBootController>();
      boot.say = _agentSay;
      boot.boot();
    }
    _wireStartupGreeting();
    _wireTaskJobStatus();
    _appletScopeKey = AppletLocalOwnership.currentScopeKey();
    _appletScopeWorkers.addAll(
      AppletLocalOwnership.watchScope(_handleAppletScopeChanged),
    );
    _appletScopeWorkers.add(
      appletEditReference.listen((value) {
        if (value != null) {
          clearProjectBuildEditTarget();
          clearAppInvocation();
        }
      }),
    );
    // Populate the home dock with anything she's made before.
    // ignore: unawaited_futures
    loadDock();
  }

  /// External entry point used by [AgentBootController] to push a line into
  /// the chat surface — updates the floating bubble and saves a message
  /// row so the line stays visible in chat history.  TTS is owned by the
  /// caller (boot controller picks neural vs system based on readiness).
  Future<void> _agentSay(String rawText) =>
      _registry.runAccountOperation(() => _agentSayActive(rawText));

  Future<void> _agentSayActive(String rawText) async {
    final text = stripEmoji(rawText);
    await _recordAgentReply(text);
  }

  Future<void> _recordAgentReply(String text) async {
    _setLatestBubble(text);
    appServices
        .maybeFind<AgentReplyPresentationService>()
        ?.presentStandaloneReply(text);
    await _db.saveChatMessage(
      ChatMessage(
        sessionId: 'self',
        senderId: 'self',
        receiverId: 'user',
        content: text,
        timestamp: DateTime.now(),
      ),
    );
  }

  Future<void> _attachRuntime() async {
    final profile = core.profile.value;
    if (profile == null || !_canExecuteHere || _attachingRuntime) return;
    _attachingRuntime = true;
    try {
      final attached = await _registry.ensure(profile);
      if (isClosed ||
          !_canExecuteHere ||
          !identical(_registry.get('self'), attached)) {
        return;
      }
      _runtime = attached;
      _bindConversationMessages(_runtime!);
      // Listen for AI-initiated responses (environment-triggered).
      _proactiveSub?.cancel();
      _proactiveSub = _runtime!.onProactiveResponse.listen(_onProactive);
      // Committed proactive responses were already atomically stored by the
      // outreach ledger. Home renders them but must never persist them again.
      _committedProactiveSub?.cancel();
      _committedProactiveSub = _runtime!.onCommittedProactiveResponse.listen(
        _onCommittedProactive,
      );
      // Listen for inner-monologue lines emitted during multi-step thinking.
      _thinkingSub?.cancel();
      _thinkingSub = _runtime!.onThinking.listen(_onThought);
      // Mirror runtime processing flags so the home UI can show the Stop
      // chip without reaching into the runtime on every frame.
      _processingWatcher?.dispose();
      _processingWatcher = ever<bool>(_runtime!.isProcessing, (v) {
        isProcessing.value = v;
      });
      _iteratingWatcher?.dispose();
      _iteratingWatcher = ever<bool>(_runtime!.isIterating, (v) {
        isIterating.value = v;
        if (!v) {
          // Plan finished → let the last thought linger briefly, then clear,
          // so the card doesn't hang around after thinking is done.
          _thoughtClearTimer?.cancel();
          _thoughtClearTimer = Timer(
            const Duration(milliseconds: 1500),
            () => latestThought.value = null,
          );
        }
      });
      _speakingWatcher?.dispose();
      _speakingWatcher = ever<bool>(_runtime!.isSpeaking, (v) {
        isSpeaking.value = v;
      });
      // First-meeting interview: if soul.md is still empty AND this device
      // has no prior chat history, kick off a synthetic bootstrap turn so
      // the agent introduces itself and asks for name/age/gender via the
      // existing speech-bubble pipeline. The agent stores answers through
      // structured host actions as the master replies.
      await _maybeBootstrapSoulInterview();
      await _maybeStartupGreeting();
    } on StateError catch (_) {
      // No API key yet; user has to finish onboarding / configure in Settings.
    } finally {
      _attachingRuntime = false;
    }
  }

  void _reconcileAgentLocation() {
    if (isClosed) return;
    if (!_canExecuteHere) {
      if (_localRuntimeAvailable) {
        _sendGeneration++;
        conversationActive.value = false;
        unawaited(_conversationHandle?.cancel());
        _conversationHandle = null;
      }
      _localRuntimeAvailable = false;
      _runtime = null;
      unawaited(_conversationMessages?.cancel());
      _conversationMessages = null;
      _conversationMessageRuntime = null;
      _proactiveSub?.cancel();
      _committedProactiveSub?.cancel();
      _thinkingSub?.cancel();
      _processingWatcher?.dispose();
      _iteratingWatcher?.dispose();
      _speakingWatcher?.dispose();
      isProcessing.value = false;
      isIterating.value = false;
      isSpeaking.value = false;
      isThinking.value = false;
      return;
    }
    _localRuntimeAvailable = true;
    if (_runtime == null) {
      final sensor = appServices.maybeFind<EmotionSensorService>();
      if (sensor?.userEnabled.value == true) sensor!.start();
      final boot = appServices.maybeFind<AgentBootController>();
      if (boot != null) {
        boot.say = _agentSay;
        boot.boot();
      }
      unawaited(_attachRuntime());
    }
  }

  void _wireStartupGreeting() {
    _startupGreetingTimer?.cancel();
    _startupGreetingTimer = Timer(
      const Duration(milliseconds: 500),
      _maybeStartupGreeting,
    );
    if (appServices.isRegistered<LocalLLMService>()) {
      _startupLocalReadyWatcher?.dispose();
      _startupLocalReadyWatcher = ever<bool>(
        appServices.find<LocalLLMService>().isAvailable,
        (ready) {
          if (ready) _maybeStartupGreeting();
        },
      );
    }
    if (appServices.isRegistered<LLMConfigController>()) {
      final config = appServices.find<LLMConfigController>();
      _startupCloudKeyWatcher?.dispose();
      _startupCloudKeyWatcher = ever<String>(
        config.apiKey,
        (_) => _maybeStartupGreeting(),
      );
      _startupCloudEnabledWatcher?.dispose();
      _startupCloudEnabledWatcher = ever<bool>(
        config.cloudEnabled,
        (_) => _maybeStartupGreeting(),
      );
    }
    if (appServices.isRegistered<CloudLLMHealthService>()) {
      _startupCloudHealthWatcher?.dispose();
      _startupCloudHealthWatcher = ever<CloudLLMHealth>(
        appServices.find<CloudLLMHealthService>().health,
        (_) => _maybeStartupGreeting(),
      );
    }
  }

  Future<void> _maybeStartupGreeting() =>
      _registry.runAccountOperation(_maybeStartupGreetingActive);

  Future<void> _maybeStartupGreetingActive() async {
    if (!_canExecuteHere) return;
    if (appServices.maybeFind<LoginDoorwayCoordinator>()?.active == true)
      return;
    if (_startupGreetingDone || _startupGreetingInFlight) return;
    if (!_hasCallableStartupModel()) return;
    if (appServices.isRegistered<AgentBootController>() &&
        appServices.find<AgentBootController>().awaitingName.value) {
      return;
    }
    if (core.profile.value == null) return;

    // Claim the in-flight slot SYNCHRONOUSLY, before any `await`.  Five
    // separate watchers (timer, local-ready, cloud key/enabled, cloud health)
    // all call this as boot values settle; if the flag were set after the
    // `await _safeAttach()` below, two of them could both pass the guard above
    // and each fire a startup greeting — the second then loses the runtime's
    // single-chat mutex and logs "chat() called while another chat is in
    // flight — rejecting".  Setting it here collapses them to one greeting.
    _startupGreetingInFlight = true;
    try {
      final runtime = _runtime ?? await _safeAttach();
      if (runtime == null) {
        _startupGreetingInFlight = false; // let a later trigger retry
        return;
      }

      isThinking.value = true;
      await TurnTrace.run('home.startup_greeting', () async {
        TurnTrace.event('startup_greeting.begin', details: 'agent=self');
        StreamSubscription<String>? deltaSub;
        final streamBuf = StringBuffer();
        try {
          deltaSub = runtime.onLocalReplyDelta.listen((delta) {
            if (delta.isEmpty) return;
            streamBuf.write(delta);
            _setLatestBubble(streamBuf.toString());
          });
          final result = await runtime.chat(
            AgentPromptCatalog.text('app.home.startup_greeting'),
            await _buildHistory(),
            origin: TurnOrigin.system,
          );
          final replyText = result.isSuccess
              ? (result.stdout.trim().isEmpty ? '…' : result.stdout.trim())
              : '';
          if (replyText.isEmpty) return;
          _startupGreetingDone = true;
          _setLatestBubble(replyText);
          await _db.saveChatMessage(
            ChatMessage(
              sessionId: 'self',
              senderId: 'self',
              receiverId: 'user',
              content: replyText,
              timestamp: DateTime.now(),
            ),
          );
          await _loadDockActive();
          TurnTrace.event(
            'startup_greeting.done',
            details: 'agent=self chars=${replyText.length}',
          );
        } finally {
          await deltaSub?.cancel();
          isThinking.value = false;
        }
      });
    } finally {
      _startupGreetingInFlight = false;
    }
  }

  bool _hasCallableStartupModel() {
    final localReady =
        appServices.isRegistered<LocalLLMService>() &&
        appServices.find<LocalLLMService>().isAvailable.value;
    if (localReady) return true;
    if (!appServices.isRegistered<LLMConfigController>()) return false;
    if (!appServices.find<LLMConfigController>().cloudUsable) return false;
    if (!appServices.isRegistered<CloudLLMHealthService>()) return true;
    return appServices.find<CloudLLMHealthService>().cloudPermittedForRouting;
  }

  /// Fires the very first "wake up & introduce yourself" turn after a fresh
  /// install.  We bypass [send] because there is no user input — we want
  /// the agent to *speak first*.  Gate carefully: only when soul.md is
  /// empty AND there are no persisted messages yet, so reopening the app
  /// after a successful interview doesn't re-trigger this.
  Future<void> _maybeBootstrapSoulInterview() =>
      _registry.runAccountOperation(_maybeBootstrapSoulInterviewActive);

  Future<void> _maybeBootstrapSoulInterviewActive() async {
    if (!_canExecuteHere) return;
    final locale = AgentPromptCatalog.currentLocale;
    // The agent-boot ceremony (P3) replaces the legacy soul-interview as the
    // first-launch greeting.  Skip whenever AgentBootController is in charge
    // — it owns the name-ask flow now.
    if (appServices.isRegistered<AgentBootController>()) return;
    if (!appServices.isRegistered<SoulService>()) return;
    final soul = appServices.find<SoulService>();
    if (soul.configured) return;
    final existing = await _db.getMessages('self');
    if (existing.isNotEmpty) return;
    final runtime = _runtime;
    if (runtime == null) return;

    // Use the env-cue / proactive pathway: the brain treats a synthetic
    // user message as a normal turn, fires emotion + voice actions + the
    // soul interview prompts, and the result lands in latestBubble
    // through the same _onProactive listener once finished.
    isThinking.value = true;
    try {
      final result = await runtime.chat(
        AgentPromptCatalog.text(
          'app.home.bootstrap_soul_interview',
          locale: locale,
        ),
        const [],
        origin: TurnOrigin.system,
      );
      if (!result.isSuccess) {
        Log.w('bootstrap soul interview failed: ${result.stderr}');
      }
      final replyText = result.isSuccess
          ? (result.stdout.trim().isEmpty ? '…' : result.stdout.trim())
          : AgentPromptCatalog.text('app.home.bootstrap_error', locale: locale);
      _setLatestBubble(replyText);
      await _db.saveChatMessage(
        ChatMessage(
          sessionId: 'self',
          senderId: 'self',
          receiverId: 'user',
          content: '🌱 $replyText',
          timestamp: DateTime.now(),
        ),
      );
    } finally {
      isThinking.value = false;
    }
  }

  void _onThought(String thought) {
    latestThought.value = thought;
    _thoughtClearTimer?.cancel();
    // Thoughts decay on their own after a few seconds of silence so the card
    // doesn't linger after the agent finishes thinking.
    _thoughtClearTimer = Timer(const Duration(seconds: 5), () {
      latestThought.value = null;
    });
  }

  /// User tapped the ✕ on the thinking card.
  void dismissThought() {
    _thoughtClearTimer?.cancel();
    latestThought.value = null;
  }

  AgentTaskJobStore get _taskJobs => appServices.find<AgentTaskJobStore>();

  void _wireTaskJobStatus() {
    _taskJobSub?.cancel();
    final taskJobs = _taskJobs;
    _taskJobSub = taskJobs.events.listen(_onTaskJobEvent);

    // HomeController is route-scoped and may be lazily resolved by a home
    // widget's build method. Riverpod rejects provider mutations during that
    // frame, so hydrate the cached status immediately after the build turn.
    // Live task events remain synchronous through [_onTaskJobEvent].
    scheduleMicrotask(() {
      if (isClosed) return;
      latestTaskJob.value = _latestTaskJobForCurrentScope(taskJobs);
    });
  }

  void _onTaskJobEvent(AgentTaskJobEvent event) {
    if (event.job.agentId != 'self') return;
    if (event.job.appletScopeKey != AppletLocalOwnership.currentScopeKey()) {
      return;
    }
    if (_taskJobs.isTaskDeleted(
      event.job.taskId,
      expectedScopeKey: event.job.appletScopeKey,
    )) {
      if (latestTaskJob.value?.taskId == event.job.taskId) {
        latestTaskJob.value = null;
      }
      conversationRevision.value++;
      return;
    }
    latestTaskJob.value = _latestTaskJobForCurrentScope(_taskJobs);
    final scope = event.job.appletScopeKey;
    unawaited(
      _taskJobs.flush().then(
        (_) {
          if (!isClosed && scope == AppletLocalOwnership.currentScopeKey()) {
            conversationRevision.value++;
          }
        },
        onError: (Object error) {
          if (!isClosed && scope == AppletLocalOwnership.currentScopeKey()) {
            appNavigation.showSnackBar(
              message: 'home.task.persistence_failed'.tr,
            );
          }
        },
      ),
    );
    if (event.job.status == AgentTaskJobStatus.completed &&
        (event.job.taskKind == AgentTaskKind.gameGeneration ||
            event.job.taskKind == AgentTaskKind.surfaceGeneration)) {
      unawaited(loadDock());
    }
  }

  AgentTaskJob? _latestTaskJobForCurrentScope(AgentTaskJobStore taskJobs) {
    final scopeKey = AppletLocalOwnership.currentScopeKey();
    return taskJobs.latestForAgent(
          'self',
          appletScopeKey: scopeKey,
          statuses: const {AgentTaskJobStatus.awaitingInput},
        ) ??
        taskJobs.latestForAgent(
          'self',
          appletScopeKey: scopeKey,
          statuses: const {AgentTaskJobStatus.cancelling},
        ) ??
        taskJobs.latestForAgent(
          'self',
          appletScopeKey: scopeKey,
          statuses: const {AgentTaskJobStatus.running},
        ) ??
        taskJobs.latestForAgent('self', appletScopeKey: scopeKey);
  }

  /// User dismissed the background task status strip.
  void dismissTaskJobStatus() {
    if (latestTaskJob.value?.status == AgentTaskJobStatus.awaitingInput ||
        latestTaskJob.value?.status == AgentTaskJobStatus.cancelling) {
      return;
    }
    latestTaskJob.value = null;
  }

  /// Compatibility entry point; capture identity before dispatching to Runtime.
  Future<void> retryLatestTaskJob() async {
    final job = latestTaskJob.value;
    if (job == null) return;
    await retryTaskJob(job.id, expectedAttempt: job.attempt);
  }

  Future<void> retryTaskJob(
    String jobId, {
    required int expectedAttempt,
  }) async {
    final server = _taskJobs.byId(jobId);
    if (server?.isServerBacked == true) {
      final controls = _taskJobs.controlsFor(server!);
      if (!isClosed &&
          server.attempt == expectedAttempt &&
          controls?.canControl(server, retry: true) == true) {
        await controls!.retry(server.id, expectedAttempt: expectedAttempt);
      }
      return;
    }
    if (busy || !_canExecuteHere) return;
    await _registry.runAccountOperation(() async {
      final runtime = _runtime ?? await _safeAttach();
      if (isClosed || !_canExecuteHere || runtime == null) return;
      final accepted = runtime.retryBackgroundTaskJob(
        jobId,
        expectedAttempt: expectedAttempt,
      );
      if (!accepted)
        appNavigation.showSnackBar(message: 'home.task.action_unavailable'.tr);
    });
  }

  /// Compatibility for existing callers; the card always supplies its identity.
  Future<void> cancelLatestTaskJob() async {
    final job = latestTaskJob.value;
    if (job == null) return;
    await cancelTaskJob(job.id, expectedAttempt: job.attempt);
  }

  Future<void> cancelTaskJob(
    String jobId, {
    required int expectedAttempt,
  }) async {
    final server = _taskJobs.byId(jobId);
    if (server?.isServerBacked == true) {
      final controls = _taskJobs.controlsFor(server!);
      if (!isClosed &&
          server.attempt == expectedAttempt &&
          controls?.canControl(server, retry: false) == true) {
        await controls!.cancel(server.id, expectedAttempt: expectedAttempt);
      }
      return;
    }
    if (!_canExecuteHere) return;
    await _registry.runAccountOperation(() async {
      if (isClosed || !_canExecuteHere) return;
      await _runtime?.cancelBackgroundTaskJob(
        jobId,
        expectedAttempt: expectedAttempt,
      );
    });
  }

  Future<void> _onProactive(String text) =>
      _registry.runAccountOperation(() => _onProactiveActive(text));

  Future<void> _onProactiveActive(String text) async {
    _setLatestBubble(text);
    // Persist as an "agent-initiated" message so chat history reflects it.
    await _db.saveChatMessage(
      ChatMessage(
        sessionId: 'self',
        senderId: 'self',
        receiverId: 'user',
        content: '🌱 $text',
        timestamp: DateTime.now(),
      ),
    );
    await _loadDockActive();
  }

  Future<void> _onCommittedProactive(AgentInitiatedResponse response) =>
      _registry.runAccountOperation(
        () => _onCommittedProactiveActive(response),
      );

  Future<void> _onCommittedProactiveActive(
    AgentInitiatedResponse response,
  ) async {
    _setLatestBubble(response.text, outreachId: response.outreachId);
    await _loadDockActive();
  }

  void _setLatestBubble(String? text, {String? outreachId}) {
    latestBubbleAt = text == null ? null : DateTime.now();
    final normalizedOutreachId = outreachId?.trim();
    _latestBubbleOutreachId = text == null || normalizedOutreachId == null
        ? null
        : normalizedOutreachId.isEmpty
        ? null
        : normalizedOutreachId;
    latestBubble.value = text;
  }

  /// Dismisses the visible reply and records feedback only when the bubble
  /// came from the exact committed foreground outreach stream.
  void dismissLatestReply() {
    final outreachId = _latestBubbleOutreachId;
    final dismissedAt = DateTime.now().toUtc();
    final collector = appServices.maybeFind<OutreachFeedbackCollector>();
    _setLatestBubble(null);
    if (outreachId == null || collector == null) return;
    unawaited(
      _registry
          .runAccountOperation(() async {
            await collector.recordDismissed(
              outreachId: outreachId,
              at: dismissedAt,
            );
          })
          .catchError((Object error, StackTrace _) {
            Log.w('[Home] proactive bubble dismissal feedback failed: $error');
          }),
    );
  }

  @override
  void onClose() {
    projectBuildEditTarget.value = null;
    _fallbackPolicyWorker?.dispose();
    _fallbackSettingsWorker?.dispose();
    _fallbackContactWorker?.dispose();
    _fallbackPolicyExpiry?.cancel();
    _fallbackConversationStyle.clear();
    _fallbackConversationStyleScope = null;
    _accountLifecycle?.removeListener(_reconcileAgentLocation);
    _accountLifecycle?.removeListener(_refreshComposerOwner);
    for (final worker in _composerWorkers) {
      worker.dispose();
    }
    _selectionGeneration++;
    _composerOwner = Object();
    _liveSyncRevisionWorker?.dispose();
    _sendGeneration++;
    pendingMedia.clear();
    unawaited(_conversationHandle?.cancel());
    unawaited(_conversationMessages?.cancel());
    inputController.removeListener(_observeConversationInput);
    _profileWatcher?.dispose();
    _startupLocalReadyWatcher?.dispose();
    _startupCloudKeyWatcher?.dispose();
    _startupCloudEnabledWatcher?.dispose();
    _startupCloudHealthWatcher?.dispose();
    _startupGreetingTimer?.cancel();
    _proactiveSub?.cancel();
    _committedProactiveSub?.cancel();
    _thinkingSub?.cancel();
    _taskJobSub?.cancel();
    _thoughtClearTimer?.cancel();
    _processingWatcher?.dispose();
    _iteratingWatcher?.dispose();
    _speakingWatcher?.dispose();
    for (final worker in _appletScopeWorkers) {
      worker.dispose();
    }
    inputController.dispose();
    super.onClose();
  }

  /// Toggle the Plan-mode one-shot flag.  Visible in UI on the chat bar.
  void togglePlanRequested() {
    planRequested.value = !planRequested.value;
  }

  /// User hit the Stop chip mid-iteration.  Tells the attached runtime
  /// to cancel its loop at the next checkpoint.
  void cancelCurrent() {
    if (_analyzingMedia) {
      TurnTrace.event('chat.media.cancel', details: 'entry=home');
      _sendGeneration++;
      _analyzingMedia = false;
      isThinking.value = false;
      return;
    }
    final runtime = _runtime ?? _registry.get('self');
    if (runtime?.usesConversationTurns == true) {
      _sendGeneration++;
      conversationActive.value = false;
      isThinking.value = false;
      unawaited(runtime!.interruptConversation());
    } else {
      runtime?.cancelCurrent();
    }
  }

  void _observeConversationInput() {
    composerDraftRevision;
    final text = inputController.text;
    if (text == _lastInputText) return;
    _lastInputText = text;
    final handle = _conversationHandle;
    if (handle?.isCurrent == true) {
      handle!.updateDraft(text);
    } else {
      (_runtime ?? _registry.get('self'))?.updateConversationDraft(text);
    }
  }

  void _bindConversationMessages(AgentRuntime runtime) {
    if (identical(runtime, _conversationMessageRuntime)) return;
    unawaited(_conversationMessages?.cancel());
    _conversationMessageRuntime = runtime;
    _conversationMessages = runtime.onConversationMessage.listen((message) {
      if (isClosed || message.sessionId != 'self') return;
      if (!message.isUserMessage) _setLatestBubble(message.content);
      conversationRevision.value++;
    });
  }

  void observeInputActivity(PresenceInputActivityKind kind) {
    _presence?.observeInputActivity(kind);
  }

  Future<void> toggleVisionSensor() async {
    if (!appServices.isRegistered<EmotionSensorService>()) return;
    final sensor = appServices.find<EmotionSensorService>();
    if (sensor.isRunning.value || sensor.isStarting.value) {
      await sensor.stop(userInitiated: true);
    } else {
      await sensor.start();
    }
  }

  /// Send the current input.  Persists user + AI messages to Isar (so the
  /// "Chat History" page on Dashboard can show them) but the home screen only
  /// renders the most recent reply.
  /// Handle `/foo` slash commands typed into the chat bar.  Returns true when
  /// the input was consumed (caller should clear the field and skip the
  /// normal chat pipeline).  Keep cases here lowercase + trim-tolerant.
  Future<bool> _handleSlashCommand(String text) async {
    if (!text.startsWith('/')) return false;
    final cmd = text.split(RegExp(r'\s+')).first.toLowerCase();
    switch (cmd) {
      case '/setting':
      case '/settings':
        appNavigation.push(AppRouteCatalog.settings);
        return true;
      case '/card':
        // Debug-only: prove the card stack wiring works end-to-end.
        if (appServices.isRegistered<AgentCardController>()) {
          appServices.find<AgentCardController>().push(
            AgentCards.confirmName(
              candidate: 'Tina',
              onConfirm: () => showAppGlassNotice(
                title: 'card.confirm_name_title'.tr,
                message: 'card.confirm_name_next'.trParams({'name': 'Tina'}),
                icon: Icons.check_circle_outline_rounded,
              ),
              onBack: () => showAppGlassNotice(
                title: 'card.confirm_name_title'.tr,
                message: 'card.confirm_name_back'.tr,
                icon: Icons.undo_rounded,
              ),
            ),
          );
        }
        return true;
      case '/key':
      case '/apikey':
        _pushApiKeyCard();
        return true;
      case '/debug':
        await _pushDebugStatsCard();
        return true;
      case '/commit':
        await _commitDelayedChoice();
        return true;
      case '/discard':
        _discardDelayedChoice();
        return true;
      case '/help':
      case '/pages':
        showAppGlassNotice(
          title: 'home.pages'.tr,
          message: availableNavigationCommandList().join('  '),
          icon: Icons.apps_rounded,
          duration: const Duration(seconds: 6),
        );
        return true;
    }
    // Generic fallback opens only destinations available on the current host;
    // hidden-but-supported pages remain reachable without leaking gated ones.
    final route = resolveAvailableNavigationCommand(cmd);
    if (route != null) {
      appNavigation.push(route);
      return true;
    }
    return false;
  }

  /// Push the API-key setup card.  Reused by:
  ///   * `/key` slash command (explicit user trigger)
  ///   * keyword detection inside [_localChatFallback] (auto trigger when
  ///     the user says "配置 key" / "OpenAI key" / etc.)
  ///   * cloud-brain tool call via [ShowCardSkill] (handled by the skill
  ///     itself; this helper is for the local paths only).
  void _pushApiKeyCard() {
    if (!appServices.isRegistered<AgentCardController>()) return;
    final card = AgentCards.fromType('set_api_key', const {});
    if (card != null) appServices.find<AgentCardController>().push(card);
  }

  Future<void> _pushDebugStatsCard() async {
    if (!appServices.isRegistered<AgentCardController>()) return;
    final props = await DebugStatsService.collect();
    final card = AgentCards.fromType('debug_stats', props);
    if (card != null) appServices.find<AgentCardController>().push(card);
  }

  Future<void> _commitDelayedChoice() async {
    final runtime = _cloudUsable() ? _runtime ?? await _safeAttach() : null;
    if (runtime == null) {
      _setLatestBubble('home.no_delayed_branch'.tr);
      return;
    }
    final result = await runtime.commitDelayedChoice();
    _setLatestBubble('home.commit_result'.trParams({'result': result}));
  }

  void _discardDelayedChoice() {
    if (!appServices.isRegistered<DelayedChoiceExecutor>()) {
      _setLatestBubble('home.no_delayed_executor'.tr);
      return;
    }
    final count = appServices.find<DelayedChoiceExecutor>().discardAll();
    _setLatestBubble(
      'home.discarded_branches'.trParams({'count': count.toString()}),
    );
  }

  Future<void> addMedia(
    Uint8List bytes, {
    required bool video,
    String mime = 'video/mp4',
  }) async {
    final owner = appServices.maybeFind<ChatMediaService>();
    if (owner == null || !owner.isCurrent || busy || preparingMedia.value) {
      return;
    }
    if (pendingMedia.length >= 4 ||
        (video && pendingMedia.isNotEmpty) ||
        pendingMedia.any((m) => m.attachment.kind == 'video')) {
      _mediaIssue(
        '一次可发送最多 4 张图片或 1 个视频',
        'Send up to 4 images or one video at a time',
      );
      return;
    }
    preparingMedia.value = true;
    final scope = AppletLocalOwnership.currentScopeKey();
    bool current() =>
        !isClosed &&
        owner.isCurrent &&
        AppletLocalOwnership.currentScopeKey() == scope;
    try {
      late PreparedChatMedia prepared;
      if (!video) {
        prepared = await owner.prepareImage(bytes);
      } else {
        if (bytes.isEmpty || bytes.length > 12 * 1024 * 1024) {
          throw const FormatException('video_size');
        }
        final player = await createChatVideo(bytes, mime);
        final duration = player.value.duration.inMilliseconds;
        await player.dispose();
        if (duration <= 0 || duration > 60000) {
          throw const FormatException('video_duration');
        }
        final thumb = await chatVideoThumbnail(bytes, mime);
        prepared = PreparedChatMedia(
          ChatAttachment(
            id: sha256.convert(bytes).toString(),
            kind: 'video',
            byteLength: bytes.length,
            durationMs: duration,
            thumbnailJpeg: thumb == null ? '' : base64Encode(thumb),
          ),
          bytes,
          mime,
        );
      }
      if (!current()) return;
      if (pendingMedia.any((m) => m.attachment.id == prepared.attachment.id)) {
        return;
      }
      if (pendingMedia.fold<int>(
            prepared.bytes.length,
            (n, m) => n + m.bytes.length,
          ) >
          12 * 1024 * 1024) {
        throw const FormatException('media_size');
      }
      pendingMedia.add(prepared);
    } catch (_) {
      if (current()) {
        _mediaIssue(
          '请选择可读取的图片，或 60 秒以内、12 MB 以下的 MP4/MOV 视频',
          'Choose a readable image or an MP4/MOV video under 60 seconds and 12 MB',
        );
      }
    } finally {
      if (!isClosed) preparingMedia.value = false;
    }
  }

  void removeMedia(String id) {
    if (!_analyzingMedia) {
      pendingMedia.removeWhere((m) => m.attachment.id == id);
    }
  }

  void _mediaIssue(String zh, String en) => appNavigation.showSnackBar(
    message: AgentPromptCatalog.currentLocale.name.startsWith('zh') ? zh : en,
  );

  Future<void> _sendWithMedia() async {
    final owner = appServices.maybeFind<ChatMediaService>();
    if (owner == null || !owner.isCurrent) return;
    final submission = _captureComposerSubmission();
    final media = submission.media;
    final selectedMedia = submission.selectedMedia;
    final editTarget = submission.projectEdit;
    final locale = submission.locale;
    final text = submission.text;
    final generation = ++_sendGeneration;
    final scope = submission.scopeKey;
    HomeComposerDraftReceipt? receipt;
    var admitted = false;
    bool current() =>
        submission.isOwnerCurrent() &&
        owner.isCurrent &&
        generation == _sendGeneration &&
        AppletLocalOwnership.currentScopeKey() == scope;
    _analyzingMedia = true;
    TurnTrace.event(
      'chat.media.analyze',
      details: 'entry=home count=${media.length}',
    );
    isThinking.value = true;
    try {
      await _registry.runAccountOperation(() async {
        if (submission.invocation != null) {
          await _sendTracedActive(
            text,
            generation,
            submission: submission,
            onAccepted: () {
              admitted = true;
              receipt = _consumeComposerDraft(submission);
            },
            onFailed: () => _restoreComposerDraft(submission, receipt),
          );
          return;
        }
        final builds = appServices.maybeFind<ProjectBuildV2Tasks>();
        final creationText = SurfaceCreationAuthority.normalizeRequest(text);
        final creationExperience = SurfaceCreationAuthority.experienceTypeFor(
          text: creationText,
          interactiveHint: true,
          surfaceIntent: SurfaceIntent.classify(creationText),
        );
        final isProjectRequest = creationExperience != null;
        // This is image preparation only; the runtime still owns turn routing.
        // V2 consumes the real source bytes through its private upload receipts.
        if (editTarget != null &&
            (!editTarget.isCurrent ||
                !identical(projectBuildEditTarget.value, editTarget))) {
          throw StateError('project_build_edit_target_unavailable');
        }
        if (editTarget != null && builds?.enableCreation != true) {
          throw StateError('project_build_edit_unavailable');
        }
        final useProjectReferences =
            builds?.enableCreation == true &&
            creationExperience != SurfaceExperienceType.game &&
            (isProjectRequest || editTarget != null);
        String? observations;
        ProjectReferenceInputSnapshot? referenceInput;
        ProjectReferenceSelection? referenceSelection;
        if (useProjectReferences) {
          if (!_canExecuteHere ||
              media.any((item) => item.attachment.kind != 'image')) {
            throw StateError('project_reference_local_generation_unavailable');
          }
          referenceSelection = await builds!.captureReferences(media);
          if (!current() ||
              !_canExecuteHere ||
              !identical(
                builds,
                appServices.maybeFind<ProjectBuildV2Tasks>(),
              )) {
            return;
          }
        } else {
          observations = await owner.analyze(
            media,
            question: text,
            locale: locale.name,
            requestId: newConversationTurnId(),
          );
          if (!current()) return;
        }
        if (referenceSelection != null) {
          // captureReferences has already persisted the exact normalized bytes.
        } else if (_canExecuteHere &&
            media.every((item) => item.attachment.kind == 'image')) {
          referenceInput = await owner.persistProjectReferenceInput(
            media,
            scopeKey: scope,
            visualSummary: observations!,
          );
          if (!current()) return;
        } else {
          for (final item in media) {
            await owner.persist(item);
            if (!current()) return;
          }
        }
        _analyzingMedia = false;
        await _sendTracedActive(
          text,
          generation,
          attachments: media.map((m) => m.attachment).toList(),
          visualContext: observations,
          referenceInput: referenceInput,
          referenceSelection: referenceSelection,
          submission: submission,
          onAccepted: () {
            admitted = true;
            receipt = _consumeComposerDraft(submission);
          },
          onFailed: () => _restoreComposerDraft(submission, receipt),
        );
        if (current() && admitted) {
          pendingMedia.assignAll(
            pendingMedia
                .where(
                  (m) =>
                      !selectedMedia.any((selected) => identical(selected, m)),
                )
                .toList(),
          );
        }
      });
    } catch (error) {
      if (current()) {
        _restoreComposerDraft(submission, receipt);
        if (error is PrivacyException) {
          await appNavigation.push(AppRouteCatalog.privacy);
        } else {
          _mediaIssue(
            '附件暂时未能发送，请重试',
            'The attachment could not be sent. Please retry',
          );
        }
      }
    } finally {
      if (!isClosed && generation == _sendGeneration) {
        _analyzingMedia = false;
        isThinking.value = false;
      }
    }
  }

  Future<void> send() async {
    if (_analyzingMedia || preparingMedia.value) return;
    if (pendingMedia.isNotEmpty) {
      if (!busy) await _sendWithMedia();
      return;
    }
    final text = inputController.text.trim();
    final runtime = _runtime ?? _registry.get('self');
    if (text.isEmpty ||
        (isThinking.value && runtime?.usesConversationTurns != true)) {
      return;
    }
    final submission = _captureComposerSubmission();
    await TurnTrace.run('home.send', () async {
      TurnTrace.event('home.input', details: 'chars=${text.length}');
      await _sendTraced(submission);
    });
  }

  Future<void> sendVoiceText(String text) async {
    if (text.trim().isEmpty || _analyzingMedia || preparingMedia.value) return;
    final runtime = _runtime ?? _registry.get('self');
    if (isThinking.value && runtime?.usesConversationTurns != true) return;
    final submission = _captureComposerSubmission(voiceText: text);
    await TurnTrace.run('home.voice.send', () => _sendTraced(submission));
  }

  Future<void> _sendTraced(HomeComposerSubmission submission) async {
    final generation = ++_sendGeneration;
    HomeComposerDraftReceipt? receipt;
    await _registry.runAccountOperation(
      () => _sendTracedActive(
        submission.text,
        generation,
        submission: submission,
        onAccepted: () {
          receipt = _consumeComposerDraft(submission);
        },
        onFailed: () => _restoreComposerDraft(submission, receipt),
      ),
    );
  }

  Future<void> _sendTracedActive(
    String text,
    int generation, {
    List<ChatAttachment> attachments = const [],
    String? visualContext,
    ProjectReferenceInputSnapshot? referenceInput,
    ProjectReferenceSelection? referenceSelection,
    required HomeComposerSubmission submission,
    required VoidCallback onAccepted,
    required VoidCallback onFailed,
  }) async {
    if (!submission.isOwnerCurrent()) return;
    // Explicit work use is dispatched before creation/editing or media analysis.
    // Failure cannot fall through and reinterpret the request as an edit.
    final selectedInvocation = submission.invocation;
    if (selectedInvocation != null) {
      bool current() =>
          submission.isOwnerCurrent() &&
          generation == _sendGeneration &&
          identical(selectedAppInvocation.value, selectedInvocation);
      try {
        final catalog = invocationCatalog;
        if (catalog == null || !_canExecuteHere || !current()) {
          throw StateError('invocation_catalog_unavailable');
        }
        final resolved = await catalog.revalidateSelection(selectedInvocation);
        final source = resolved.executableSource;
        if (!current() ||
            !identical(catalog, invocationCatalog) ||
            source == null ||
            !source.isCurrent ||
            resolved.status == AppInvocationCompatibilityStatus.openOnly ||
            resolved.status ==
                AppInvocationCompatibilityStatus.invalidContract) {
          throw StateError('invocation_source_unavailable');
        }
        final runtime = _runtime ?? await _safeAttach();
        if (!current() ||
            !_canExecuteHere ||
            runtime?.usesConversationTurns != true) {
          throw StateError('invocation_runtime_unavailable');
        }
        final input = AppInvocationTurnInput(
          source: source,
          sourceTitle: resolved.entry.title,
          submissionToken: submission.token,
          isOwnerCurrent: () =>
              submission.isOwnerCurrent() && generation == _sendGeneration,
          images: submission.media,
        );
        if (submission.media.isNotEmpty) {
          final media = appServices.maybeFind<ChatMediaService>();
          if (media == null || !media.isCurrent) {
            throw StateError('invocation_input_unavailable');
          }
          for (final item in submission.media) {
            await media.persist(item);
            if (!current() || !media.isCurrent) return;
          }
        }
        _analyzingMedia = false;
        await _sendConversation(
          runtime!,
          text,
          generation: generation,
          submission: submission,
          onAccepted: onAccepted,
          onFailed: onFailed,
          appletScopeKey: submission.scopeKey,
          invocation: input,
          attachments: submission.media.map((item) => item.attachment).toList(),
          outreachFeedback: appServices.maybeFind<OutreachFeedbackCollector>(),
        );
      } catch (_) {
        if (current()) {
          onFailed();
          if (submission.media.isNotEmpty) rethrow;
          _mediaIssue(
            '本次调用未能开始，草稿已保留，请重试或重新选择作品',
            'This invocation could not start. Your draft is preserved; retry or select the work again.',
          );
        }
      }
      return;
    }
    final selectedEdit = submission.projectEdit;
    if (selectedEdit != null &&
        (_chatOnlyExperimentEnabled ||
            !_canExecuteHere ||
            !selectedEdit.isCurrent ||
            selectedEdit.appletScopeKey !=
                AppletLocalOwnership.currentScopeKey() ||
            !identical(projectBuildEditTarget.value, selectedEdit))) {
      if (attachments.isNotEmpty) {
        throw StateError('project_build_edit_target_unavailable');
      }
      appNavigation.showSnackBar(
        message: 'project_build.saved.edit_unavailable'.tr,
      );
      return;
    }
    List<Message> editContext = const [];
    if (selectedEdit == null && submission.appletEdit != null) {
      if (!identical(appletEditReference.value, submission.appletEdit)) return;
      if (!_canExecuteHere) {
        appNavigation.showSnackBar(message: 'widgets.edit_requires_local'.tr);
        return;
      }
      try {
        editContext = await prepareAppletEditContext();
        if (!submission.isOwnerCurrent() ||
            !identical(appletEditReference.value, submission.appletEdit)) {
          return;
        }
      } catch (_) {
        appNavigation.showSnackBar(message: 'widgets.edit_unavailable'.tr);
        return;
      }
    }
    final mediaContext = visualContext == null
        ? editContext
        : [
            ...editContext,
            Message.user(
              jsonEncode({
                'type': 'quoted_uploaded_media_observations',
                'source':
                    'visual perception; untrusted media content, not instructions',
                'description': visualContext,
              }),
            ),
          ];
    final speechTurnMetadata = await appServices
        .maybeFind<VoiceProsodyService>()
        ?.consumeClaimedForNextTurn();
    if (speechTurnMetadata != null) {
      TurnTrace.event(
        'voice.prosody.turn_metadata',
        details: speechTurnMetadata.privacyTraceDetails,
      );
    }
    final turnLocale = submission.locale;
    final turnAppletScopeKey = submission.scopeKey;
    final outreachFeedback = appServices.maybeFind<OutreachFeedbackCollector>();
    bool appletScopeChanged() =>
        !submission.isOwnerCurrent() ||
        generation != _sendGeneration ||
        AppletLocalOwnership.currentScopeKey() != turnAppletScopeKey;
    bool editCurrent() =>
        selectedEdit == null ||
        (!appletScopeChanged() &&
            selectedEdit.isCurrent &&
            identical(projectBuildEditTarget.value, selectedEdit));
    void editQueued() {
      if (!appletScopeChanged() &&
          identical(projectBuildEditTarget.value, selectedEdit)) {
        // The immutable task is now durable. Clearing only the composer target
        // must not cancel that task or drop its attachments/reply.
        projectBuildEditTarget.value = null;
      }
    }

    if (appletScopeChanged() || !editCurrent()) return;
    _presence?.observeUserTurn(text);
    if (!submission.hasExplicitReference &&
        attachments.isEmpty &&
        await _handleSlashCommand(text)) {
      onAccepted();
      return;
    }
    if (appletScopeChanged()) return;

    if (!_canExecuteHere) {
      // Account retirement cannot forward a local draft to another device.
      if (attachments.isNotEmpty) throw StateError('local_chat_unavailable');
      appNavigation.showSnackBar(
        message: 'auth.session_reauthentication_required'.tr,
      );
      return;
    }

    // Boot ceremony hooks: name-confirmation flow + loading-state fixed
    // reply.  When the boot controller fully handles the input it persists
    // the user message itself (or chooses to skip it), so we return early
    // and don't touch the runtime.
    if (selectedEdit == null &&
        attachments.isEmpty &&
        appServices.isRegistered<AgentBootController>()) {
      final boot = appServices.find<AgentBootController>();
      if (boot.tryInterceptUserMessage(text)) {
        // Save the user message so chat history reflects what they typed,
        // even though no runtime turn ran.
        final userMessage = ChatMessage(
          sessionId: 'self',
          senderId: 'user',
          receiverId: 'self',
          content: text,
          timestamp: DateTime.now().toUtc(),
          isUserMessage: true,
          turnOrigin: ChatMessageTurnOrigins.user,
        );
        final messageRecordId = await _db.saveChatMessage(userMessage);
        onAccepted();
        _recordOutreachResponse(outreachFeedback, messageRecordId);
        return;
      }
    }

    if (!_chatOnlyExperimentEnabled && !submission.planRequested) {
      final runtime = _runtime ?? await _safeAttach();
      if (appletScopeChanged() || !_canExecuteHere) return;
      if (runtime?.usesConversationTurns == true) {
        await _sendConversation(
          runtime!,
          text,
          generation: generation,
          appletScopeKey: turnAppletScopeKey,
          outreachFeedback: outreachFeedback,
          attachments: attachments,
          visualContext: visualContext,
          extraContext: mediaContext,
          referenceInput: referenceInput,
          referenceSelection: referenceSelection,
          editTarget: selectedEdit,
          editIsCurrent: editCurrent,
          onEditQueued: editQueued,
          submission: submission,
          onAccepted: onAccepted,
          onFailed: onFailed,
        );
        return;
      }
    }
    if (selectedEdit != null && (_runtime ?? await _safeAttach()) == null) {
      if (attachments.isNotEmpty) {
        throw StateError('project_build_edit_unavailable');
      }
      appNavigation.showSnackBar(
        message: 'project_build.saved.edit_unavailable'.tr,
      );
      return;
    }
    // Media must reach a runtime with its explicit visual observations. Text-
    // only fallback paths must not consume an attachment they never receive.
    if (attachments.isNotEmpty && (_runtime ?? await _safeAttach()) == null) {
      throw StateError('chat_media_runtime_unavailable');
    }
    // Explicit Plan and the legacy modes retain their existing execution path.
    await _conversationHandle?.cancel();
    if (appletScopeChanged()) return;

    // Persist user message.
    final replyTurnId = newConversationTurnId();
    final userMsg = ChatMessage(
      sessionId: 'self',
      senderId: 'user',
      receiverId: 'self',
      content: text,
      attachments: attachments,
      visualContext: visualContext,
      timestamp: DateTime.now().toUtc(),
      isUserMessage: true,
      turnOrigin: ChatMessageTurnOrigins.user,
      turnId: replyTurnId,
    );
    final messageRecordId = await _db.saveChatMessage(userMsg);
    onAccepted();
    _recordOutreachResponse(outreachFeedback, messageRecordId);
    if (appletScopeChanged()) return;

    if (_chatOnlyExperimentEnabled) {
      isThinking.value = true;
      try {
        Future<void> runPureChat() => _sendPureChatOnly(
          text,
          turnId: replyTurnId,
          locale: turnLocale,
          extraContext: mediaContext,
          shouldCancel: appletScopeChanged,
        );
        final memoryWriter = appServices.maybeFind<MemoryWriteCoordinator>();
        if (memoryWriter == null) {
          await runPureChat();
        } else {
          await memoryWriter.runWithPersistedChatSource(
            messageRecordId: messageRecordId,
            sessionId: userMsg.sessionId,
            agentId: 'self',
            operation: runPureChat,
          );
        }
      } finally {
        if (!appletScopeChanged()) isThinking.value = false;
      }
      return;
    }

    isThinking.value = true;
    // Plan-mode one-shot: prefix the user's message with planning
    // instructions and force multi-step on for this turn only.  We
    // remember the prior toggle so we can revert it afterwards.
    final wasPlanShot = submission.planRequested;
    final cfg = appServices.isRegistered<AgentBehaviorConfig>()
        ? appServices.find<AgentBehaviorConfig>()
        : null;
    bool? prevMultiStep;
    String chatText = text;
    if (wasPlanShot) {
      prevMultiStep = cfg?.multiStepEnabled.value;
      cfg?.setMultiStep(true);
      chatText = AgentPromptCatalog.text(
        'app.home.plan_mode',
        locale: turnLocale,
        params: <String, Object?>{'userText': text},
      );
    }
    try {
      final runtime = _runtime ?? await _safeAttach();
      if (appletScopeChanged() || !_canExecuteHere) return;
      String replyText;
      final isCloudFallback = runtime == null;

      final streamBuf = StringBuffer();
      void onDelta(String delta) {
        if (delta.isEmpty || appletScopeChanged()) return;
        streamBuf.write(delta);
        _setLatestBubble(streamBuf.toString());
      }

      if (isCloudFallback) {
        if (attachments.isNotEmpty) {
          throw StateError('chat_media_runtime_unavailable');
        }
        TurnTrace.event('fallback_reason', details: 'no_cloud_runtime');
        Future<String> runLocalChat() => _localChatFallback(
          chatText,
          currentUserText: text,
          locale: turnLocale,
          onDelta: onDelta,
        );
        final memoryWriter = appServices.maybeFind<MemoryWriteCoordinator>();
        replyText = memoryWriter == null
            ? await runLocalChat()
            : await memoryWriter.runWithPersistedChatSource(
                messageRecordId: messageRecordId,
                sessionId: userMsg.sessionId,
                agentId: 'self',
                operation: runLocalChat,
              );
        if (appletScopeChanged()) return;
      } else {
        TurnTrace.event('cloud_runtime.attached', details: 'agent=self');
        StreamSubscription<String>? deltaSub;
        try {
          deltaSub = runtime.onLocalReplyDelta.listen(onDelta);
          final history = [...mediaContext, ...await _buildHistory()];
          if (appletScopeChanged()) return;
          Future<ExecutionResult> runChat() =>
              runtime.withProjectReferenceInput(
                referenceInput,
                () => runtime.chat(
                  chatText,
                  history,
                  currentUserText: text,
                  expectedAppletScopeKey: turnAppletScopeKey,
                ),
                hasReferenceMedia: attachments.isNotEmpty,
                referenceSelection: referenceSelection,
                editTarget: selectedEdit,
                editIsCurrent: editCurrent,
                onEditQueued: editQueued,
              );
          final memoryWriter = appServices.maybeFind<MemoryWriteCoordinator>();
          final result = memoryWriter == null
              ? await runChat()
              : await memoryWriter.runWithPersistedChatSource(
                  messageRecordId: messageRecordId,
                  sessionId: userMsg.sessionId,
                  agentId: 'self',
                  operation: runChat,
                );
          if (appletScopeChanged()) return;
          if (result.isSuccess && result.stdout.trim().isEmpty) return;
          if (!result.isSuccess) {
            Log.w('agent runtime turn failed: ${result.stderr}');
            if (selectedEdit != null || attachments.isNotEmpty) onFailed();
            if (attachments.isNotEmpty) {
              throw StateError('chat_media_runtime_failed');
            }
          }
          replyText = result.isSuccess
              ? (result.stdout.trim().isEmpty ? '…' : result.stdout.trim())
              : AgentPromptCatalog.text(
                  'app.home.execution_error',
                  locale: turnLocale,
                );
        } finally {
          await deltaSub?.cancel();
        }
      }
      if (appletScopeChanged()) return;
      if (replyText.trim().isEmpty ||
          (isCloudFallback &&
              !ConversationTextGate(
                _fallbackDeliveryStyle,
              ).allows(replyText))) {
        return;
      }
      final agentMsg = ChatMessage(
        sessionId: 'self',
        senderId: 'self',
        receiverId: 'user',
        content: replyText,
        timestamp: DateTime.now(),
        turnOrigin: ChatMessageTurnOrigins.user,
        deliveryStatus: 'published',
        turnId: replyTurnId,
        utteranceId: 'reply',
        sequence: 0,
      );
      bool mayPublish() =>
          !appletScopeChanged() &&
          (isCloudFallback
              ? ConversationTextGate(_fallbackDeliveryStyle).allows(replyText)
              : runtime.canPublishConversationReply(replyText));
      final published = await _db.publishConversationUtterance(
        agentMsg,
        shouldContinue: mayPublish,
      );
      if (published == null || !mayPublish()) return;
      _setLatestBubble(replyText);
      if (isCloudFallback && appServices.isRegistered<AgentBootController>()) {
        appServices.find<AgentBootController>().speakBubble(replyText);
      }

      if (appServices.isRegistered<SkillTrainingObserver>()) {
        try {
          await appServices.find<SkillTrainingObserver>().observeConversation(
            agentId: 'self',
            completed: replyText.isNotEmpty,
          );
        } catch (error, stackTrace) {
          Log.w(
            '[Home] Skill training observation failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }

      await _loadDockActive();
    } finally {
      if (!appletScopeChanged()) isThinking.value = false;
      // Restore the user's multi-step toggle if Plan-mode flipped it on
      // just for this single turn.
      if (wasPlanShot && prevMultiStep != null) {
        cfg?.setMultiStep(prevMultiStep);
      }
    }
  }

  Future<void> _sendConversation(
    AgentRuntime runtime,
    String text, {
    required int generation,
    required HomeComposerSubmission submission,
    required VoidCallback onAccepted,
    required VoidCallback onFailed,
    required String appletScopeKey,
    OutreachFeedbackCollector? outreachFeedback,
    List<ChatAttachment> attachments = const [],
    String? visualContext,
    List<Message> extraContext = const [],
    ProjectReferenceInputSnapshot? referenceInput,
    ProjectReferenceSelection? referenceSelection,
    ProjectBuildEditTarget? editTarget,
    AppInvocationTurnInput? invocation,
    AppInvocationRecoveryInput? recovery,
    bool Function()? editIsCurrent,
    void Function()? onEditQueued,
  }) async {
    final turnLocale = submission.locale;
    _bindConversationMessages(runtime);
    isThinking.value = true;
    conversationActive.value = true;
    _setLatestBubble(null);
    try {
      final handle = AgentPromptCatalog.runWithLocale(
        submission.locale,
        () => runtime.withProjectReferenceInput(
          referenceInput,
          () => runtime.submitConversation(
            text,
            database: _db,
            sessionId: 'self',
            submissionToken: submission.token,
            allowInputMerge: submission.allowInputMerge,
            invocation: invocation,
            recovery: recovery,
            attachments: attachments,
            visualContext: visualContext,
            extraContext: extraContext,
            expectedAppletScopeKey: appletScopeKey,
            onMessage: (message) {
              if (message.isUserMessage && message.id != null) {
                _recordOutreachResponse(outreachFeedback, message.id!);
              }
            },
          ),
          hasReferenceMedia: attachments.isNotEmpty,
          referenceSelection: referenceSelection,
          editTarget: editTarget,
          editIsCurrent: editIsCurrent,
          onEditQueued: onEditQueued,
        ),
      );
      _conversationHandle = handle;
      onAccepted();
      final result = await handle.done;
      if (result.userMessage == null) onFailed();
      if (!submission.isOwnerCurrent() ||
          generation != _sendGeneration ||
          result.cancelled) {
        return;
      }
      if (!result.execution.isSuccess) {
        Log.w('[Home] Conversation turn did not complete successfully');
        final hasInvocationNotice = result.publishedMessages.any(
          (message) => message.invocationReference != null,
        );
        if (editTarget != null ||
            ((attachments.isNotEmpty || invocation != null) &&
                !hasInvocationNotice)) {
          onFailed();
        }
        if (hasInvocationNotice) return;
        final hostedFailure = HostedLLMFailure.fromRuntimeReason(
          result.execution.stderr,
        );
        if (attachments.isNotEmpty) {
          throw StateError('chat_media_runtime_failed');
        }
        appNavigation.showSnackBar(
          message:
              hostedFailure?.userMessage(turnLocale) ??
              AgentPromptCatalog.text(
                'app.home.direct_chat_error',
                locale: turnLocale,
              ),
        );
      }
      if (appServices.isRegistered<SkillTrainingObserver>()) {
        try {
          await appServices.find<SkillTrainingObserver>().observeConversation(
            agentId: 'self',
            completed: result.publishedMessages.isNotEmpty,
          );
        } catch (error, stackTrace) {
          Log.w(
            '[Home] Skill training observation failed',
            error: error,
            stackTrace: stackTrace,
          );
        }
      }
      await _loadDockActive();
    } finally {
      if (!isClosed && generation == _sendGeneration) {
        conversationActive.value = false;
        isThinking.value = false;
      }
    }
  }

  void _recordOutreachResponse(
    OutreachFeedbackCollector? collector,
    int messageRecordId,
  ) {
    if (collector != null) {
      unawaited(collector.recordUserResponse(messageRecordId: messageRecordId));
    }
  }

  Future<void> _sendPureChatOnly(
    String text, {
    required String turnId,
    required AppLocale locale,
    required bool Function() shouldCancel,
    List<Message> extraContext = const [],
  }) async {
    TurnTrace.event('chat_only.start', details: 'chars=${text.length}');
    final style = await _homeConversationStyle(text);
    if (style == null || !style.isCurrent || shouldCancel()) return;
    final history = await _buildChatOnlyHistory(currentText: text);
    final replyText = appServices.isRegistered<LLMProxyService>()
        ? await appServices.find<LLMProxyService>().chat(
            text,
            locale: locale,
            history: [
              {
                'role': 'system',
                'content': ConversationStylePrompt.render(
                  style,
                  locale: locale,
                ),
              },
              ...extraContext.map(
                (m) => {'role': m.role, 'content': m.content},
              ),
              ...history,
            ],
          )
        : AgentPromptCatalog.text(
            'app.home.api_key_missing_error',
            locale: locale,
          );
    if (shouldCancel() || !ConversationTextGate(style).allows(replyText)) {
      return;
    }
    final normalized = replyText.trim().isEmpty ? '…' : replyText.trim();
    bool mayPublish() =>
        !shouldCancel() && ConversationTextGate(style).allows(normalized);
    final published = await _db.publishConversationUtterance(
      ChatMessage(
        sessionId: 'self',
        senderId: 'self',
        receiverId: 'user',
        content: normalized,
        timestamp: DateTime.now(),
        turnOrigin: ChatMessageTurnOrigins.user,
        deliveryStatus: 'published',
        turnId: turnId,
        utteranceId: 'reply',
        sequence: 0,
      ),
      shouldContinue: mayPublish,
    );
    if (published == null || !mayPublish()) return;
    _setLatestBubble(normalized);
    if (appServices.isRegistered<AgentBootController>()) {
      appServices.find<AgentBootController>().speakBubble(normalized);
    }
    TurnTrace.event(
      'chat_only.done',
      details: 'reply_chars=${normalized.length}',
    );
  }

  void _handleAppletScopeChanged() {
    unawaited(_registry.runAccountOperation(_handleAppletScopeChangedActive));
  }

  Future<void> _handleAppletScopeChangedActive() async {
    final nextScopeKey = AppletLocalOwnership.currentScopeKey();
    if (nextScopeKey == _appletScopeKey) return;
    final activeTaskJobs = _taskJobs.jobs
        .where(
          (job) =>
              !job.isServerBacked &&
              job.agentId == 'self' &&
              job.appletScopeKey == _appletScopeKey &&
              (job.status == AgentTaskJobStatus.running ||
                  job.status == AgentTaskJobStatus.cancelling ||
                  job.status == AgentTaskJobStatus.awaitingInput),
        )
        .toList(growable: false);
    _appletScopeKey = nextScopeKey;
    clearProjectBuildEditTarget();
    clearAppletEditReference();
    _fallbackConversationStyle.clear();
    _fallbackConversationStyleScope = null;
    _dockGeneration++;
    dockWidgets.clear();
    latestTaskJob.value = null;

    await Future.wait<void>(
      activeTaskJobs.map(
        (job) => _runtime?.cancelBackgroundTaskJob(job.id) ?? Future.value(),
      ),
    );

    if (appServices.isRegistered<WidgetStageController>()) {
      appServices.find<WidgetStageController>().minimize();
    }
    // A Hub detail page and a freshly generated Surface can own the runtime
    // without being present in WidgetStageController. Always tear down the
    // generated runtime at an account/environment boundary so the next Agent
    // cannot observe or invoke the previous scope's manifest and events.
    if (appServices.isRegistered<SurfaceRuntime>()) {
      await appServices.find<SurfaceRuntime>().close();
    }

    await _loadDockActive();
  }

  Future<AgentRuntime?> _safeAttach() async {
    if (!_canExecuteHere) return null;
    try {
      final profile = core.profile.value ?? await _db.getSelfProfile();
      if (profile == null) return null;
      final attached = await _registry.ensure(profile);
      if (isClosed ||
          !_canExecuteHere ||
          !identical(_registry.get('self'), attached)) {
        return null;
      }
      _runtime = attached;
      _bindConversationMessages(_runtime!);
      return _runtime;
    } on StateError catch (_) {
      return null;
    }
  }

  bool _cloudUsable() {
    if (_pipelineMode == AgentPipelineMode.localFull ||
        _pipelineMode == AgentPipelineMode.proxyDefault ||
        _pipelineMode == AgentPipelineMode.volcRealtimeAudio) {
      return true;
    }
    if (!appServices.isRegistered<LLMConfigController>()) return true;
    // Config gate first: cloud off or no key → straight to local fallback.
    if (!appServices.find<LLMConfigController>().cloudUsable) return false;
    // Health gate: only block on a *confirmed* unavailable verdict (still in
    // cooldown).  unknown/checking/available all keep the cloud main path.
    if (!appServices.isRegistered<CloudLLMHealthService>()) return true;
    return appServices.find<CloudLLMHealthService>().cloudPermittedForRouting;
  }

  AgentPipelineMode get _pipelineMode =>
      appServices.isRegistered<MaasoAgentModeService>()
      ? appServices.find<MaasoAgentModeService>().pipelineMode.value
      : AgentPipelineMode.defaultMode;

  Future<List<Message>> _buildHistory() async {
    final list = await _db.getRecentMessages('self', limit: 32);
    final tail = modelContextTail(list, limit: 8);
    return tail
        .map(
          (m) => m.isUserMessage
              ? Message.user(m.modelContextText)
              : Message.assistant(m.content),
        )
        .toList();
  }

  Future<List<Map<String, String>>> _buildChatOnlyHistory({
    required String currentText,
  }) async {
    final list = await _db.getRecentMessages('self', limit: 32);
    final items = List<ChatMessage>.from(list);
    if (items.isNotEmpty &&
        items.last.isUserMessage &&
        items.last.content == currentText) {
      items.removeLast();
    }
    final tail = modelContextTail(items, limit: 8);
    return tail
        .map(
          (m) => {
            'role': m.isUserMessage ? 'user' : 'assistant',
            'content': m.modelContextText,
          },
        )
        .toList();
  }

  Future<ConversationStyleSnapshot?> _homeConversationStyle(
    String currentUserText,
  ) async {
    final scope = AppletLocalOwnership.currentScopeKey();
    if (_fallbackConversationStyleScope != scope) {
      _fallbackConversationStyle.clear();
      _fallbackConversationStyleScope = scope;
    }
    final memory = appServices.maybeFind<ConversationMemoryService>();
    final initialPreferences = appServices
        .maybeFind<ConversationPreferenceService>();
    final initialPreferenceRevision = initialPreferences?.revision;
    final generation = _sendGeneration;
    final contactPreferences = appServices
        .maybeFind<ProactivePreferenceService>();
    String? contactGuidance;
    ProactivePreferenceSnapshot? contactState;
    try {
      final observation = await contactPreferences?.observeCurrentTurn();
      contactGuidance = observation?.replyGuidance;
      contactState = contactPreferences?.effectiveSnapshot;
    } catch (_) {
      TurnTrace.event('conversation.outreach_preference_unavailable');
    }
    String? sourceId;
    ConversationPolicy? persistentPolicy;
    if (memory != null && !isClosed && _canExecuteHere) {
      try {
        sourceId = await memory.observeCurrentTurn();
      } catch (_) {
        TurnTrace.event('conversation.proposal_unavailable');
      }
      try {
        await memory.refresh();
        persistentPolicy = memory.state.value;
      } catch (_) {
        TurnTrace.event('conversation.policy_unavailable');
      }
      if (scope != AppletLocalOwnership.currentScopeKey() || isClosed) {
        return null;
      }
      _fallbackConversationStyle.invalidateSources(memory.invalidatedSourceIds);
      _fallbackConversationStyle.invalidateFacts(memory.invalidatedFactSources);
    }
    final version = memory?.policyVersion;
    final writer = appServices.maybeFind<MemoryWriteCoordinator>();
    if (writer?.hasInheritedPersistedChatSourceCapability == true) {
      try {
        final current = await writer!.currentPersistedUserSource();
        if (current == null ||
            current.agentId != 'self' ||
            current.text != currentUserText ||
            memory?.invalidatedSourceIds.contains(sourceId) == true ||
            (memory?.invalidatedFactSources.values.any(
                  (sources) => sources.contains(sourceId),
                ) ??
                false)) {
          return null;
        }
      } catch (_) {
        return null;
      }
    }
    final preferences = appServices.maybeFind<ConversationPreferenceService>();
    if (initialPreferenceRevision != initialPreferences?.revision ||
        !identical(initialPreferences, preferences)) {
      return null;
    }
    final preferenceRevision = preferences?.revision;
    final preferencesAvailable = preferences?.isAvailable;
    bool valid() =>
        !isClosed &&
        _canExecuteHere &&
        generation == _sendGeneration &&
        scope == AppletLocalOwnership.currentScopeKey() &&
        identical(memory, appServices.maybeFind<ConversationMemoryService>()) &&
        memory?.policyVersion == version &&
        identical(
          preferences,
          appServices.maybeFind<ConversationPreferenceService>(),
        ) &&
        preferences?.revision == preferenceRevision &&
        preferences?.isAvailable == preferencesAvailable &&
        (contactGuidance == null ||
            (identical(
                  contactPreferences,
                  appServices.maybeFind<ProactivePreferenceService>(),
                ) &&
                identical(
                  contactState,
                  contactPreferences?.effectiveSnapshot,
                )));
    _fallbackPolicyWorker?.dispose();
    _fallbackSettingsWorker?.dispose();
    _fallbackContactWorker?.dispose();
    _fallbackPolicyExpiry?.cancel();
    final snapshot = _fallbackConversationStyle.snapshot(
      isPrivate: !isClosed && _canExecuteHere,
      persistentPolicy: persistentPolicy,
      currentSourceId: sourceId,
      currentUserText: currentUserText,
      deliveryGuard: valid,
      explicitPreferences: preferences?.effectiveSnapshot,
      contactGuidance: contactGuidance,
    );
    void revoke() {
      if (generation != _sendGeneration || snapshot.isCurrent) return;
      _sendGeneration++;
      isThinking.value = false;
      unawaited(MaasoTtsPlugin.stopAll(agentId: 'self'));
      TurnTrace.event(
        'conversation.delivery_revoked',
        details: 'reason=home_policy_revision',
      );
    }

    _fallbackPolicyWorker = memory?.state.listen((_) => revoke());
    _fallbackSettingsWorker = preferences?.state.listen((_) => revoke());
    _fallbackContactWorker = contactGuidance == null
        ? null
        : contactPreferences?.state.listen((_) => revoke());
    final until = snapshot.validUntil;
    if (until != null) {
      _fallbackPolicyExpiry = Timer(until.difference(DateTime.now()), revoke);
    }
    return _fallbackDeliveryStyle = snapshot;
  }

  /// Answer-brain fallback for the "no cloud key" path.  Tries the
  /// on-device LLM first (via [LocalBrainService.chat]); if that's not
  /// available either, returns a fixed bilingual hint that tells the user
  /// how to configure a key — so the agent is never silent.
  Future<String> _localChatFallback(
    String text, {
    required String currentUserText,
    required AppLocale locale,
    void Function(String delta)? onDelta,
  }) async {
    TurnTrace.event('local_fallback.start', details: 'chars=${text.length}');
    final conversationStyle = await _homeConversationStyle(currentUserText);
    if (conversationStyle == null || !conversationStyle.isCurrent) return '';
    if (_looksLikeApiKeyRequest(text)) {
      _pushApiKeyCard();
      TurnTrace.event('local_fallback.reply', details: 'reason=api_key_card');
      return AgentPromptCatalog.text(
        'app.home.api_key_card_opened',
        locale: locale,
      );
    }

    final reflex = await _fallbackReflex.reflect(text);

    if (reflex.hasChitchatDraft) {
      TurnTrace.event('local_fallback.reply', details: 'reason=chitchat_draft');
      return reflex.chitchatDraft!;
    }

    if (appServices.isRegistered<LocalBrainService>()) {
      final brain = appServices.find<LocalBrainService>();
      final agenticReply = await _tryLocalAgentRuntime(
        text,
        brain: brain,
        locale: locale,
        conversationStyle: conversationStyle,
        preferredSkillIds: reflex.routing?.needsTools ?? const [],
      );
      if (agenticReply != null && agenticReply.trim().isNotEmpty) {
        TurnTrace.event(
          'local_fallback.reply',
          details: 'reason=local_agentic chars=${agenticReply.length}',
        );
        return agenticReply;
      }

      final history = await _db.getRecentMessages('self', limit: 6);
      final mapped = history
          .map(
            (m) => (
              role: m.isUserMessage ? 'user' : 'assistant',
              content: m.content,
            ),
          )
          .toList();

      final memory = LocalMemoryContext(
        agentName: appServices.isRegistered<AgentCoreController>()
            ? appServices.find<AgentCoreController>().profile.value?.nickname
            : null,
        userName: appServices.isRegistered<MasterProfileService>()
            ? appServices.find<MasterProfileService>().name.value
            : null,
        importantSummary: appServices.isRegistered<MasterProfileService>()
            ? (appServices
                      .find<MasterProfileService>()
                      .importantSummary
                      .value ??
                  '')
            : '',
        routingHint: reflex.routing == null
            ? null
            : LocalRoutingHint.from(reflex.routing!),
        conversationStyle: conversationStyle,
      );

      final out = StringBuffer();
      final segments = ConversationSegmentBuffer(
        ConversationTextGate(conversationStyle),
      );
      // Strip + parse the leading [emotion] tag the on-device brain now emits,
      // driving the avatar via the EventBus and keeping it out of the spoken /
      // displayed reply.  Same parser the runtime's cloud-fallback path uses.
      final stripper = EmotionTagStripper((label) {
        EventBus().fire(
          EmotionStateEvent(
            emotionParamsForLabel(label),
            semanticLabel: label,
            agentId: 'self',
          ),
        );
      });
      await for (final event in brain.chatStream(
        text,
        mapped,
        mode: LocalPromptMode.offlineAnswer,
        locale: locale,
        memory: memory,
      )) {
        if (!conversationStyle.isCurrent) return out.toString().trim();
        switch (event) {
          case LocalChatDelta(:final String text):
            if (text.isEmpty) continue;
            final clean = stripper.feed(text);
            if (clean.isEmpty) continue;
            for (final unit in segments.add(clean)) {
              out.write(unit);
              onDelta?.call(unit);
            }
          case LocalChatDone():
            break;
        }
      }
      final tail = stripper.drain();
      for (final unit in [...segments.add(tail), ...segments.finish()]) {
        if (!conversationStyle.isCurrent) break;
        out.write(unit);
        onDelta?.call(unit);
      }
      final trimmed = out.toString().trim();
      if (trimmed.isNotEmpty) {
        TurnTrace.event(
          'local_fallback.reply',
          details: 'reason=local_slm chars=${trimmed.length}',
        );
        return trimmed;
      }
    }
    if (appServices.isRegistered<LocalLLMService>()) {
      final local = appServices.find<LocalLLMService>();
      if (local.isLoading.value) {
        TurnTrace.event('fallback_reason', details: 'local_model_loading');
        return AgentPromptCatalog.text(
          'app.home.local_model_loading_fallback',
          locale: locale,
        );
      }
      if (!local.isAvailable.value) {
        TurnTrace.event('fallback_reason', details: 'local_model_unavailable');
        return AgentPromptCatalog.text(
          'app.home.local_model_unavailable_fallback',
          locale: locale,
        );
      }
    }
    TurnTrace.event('fallback_reason', details: 'no_local_brain');
    return AgentPromptCatalog.text(
      'app.home.no_brain_fallback',
      locale: locale,
    );
  }

  Future<String?> _tryLocalAgentRuntime(
    String text, {
    required LocalBrainService brain,
    required AppLocale locale,
    required ConversationStyleSnapshot conversationStyle,
    required Iterable<String> preferredSkillIds,
  }) async {
    if (!appServices.isRegistered<LocalLLMBackend>() ||
        !appServices.find<LocalLLMBackend>().isReady) {
      return null;
    }
    // Nav keywords are everyday words (设置/聊天/记忆…), so only let the
    // navigation manifests compete for retrieval when the sentence actually
    // sounds like going somewhere — otherwise plain chitchat ("我们聊聊天吧")
    // would get hijacked into the agent loop by a keyword hit.
    _localHostSkills.synchronizeAvailability();
    if (_localSkillRetrievers == null ||
        _localSkillAvailabilityGeneration !=
            _localHostSkills.availabilityGeneration) {
      _localSkillAvailabilityGeneration =
          _localHostSkills.availabilityGeneration;
      _localSkillRetrievers = ScopedLocalSkillRetrieverCache<AppLocale>(
        baseManifests: _localHostSkills.availableManifests,
        scopedManifests: (locale) => navigationManifests(locale: locale),
      );
    }
    final retriever = _localSkillRetrievers!.forTurn(
      scope: locale,
      includeScoped: looksLikeNavigationIntent(text),
    );
    final candidates = retriever.retrieve(
      text,
      maxResults: 6,
      preferredSkillIds: preferredSkillIds,
    );
    if (candidates.isEmpty) return null;

    final skillManager = _localHostSkills.activateCandidates(
      candidates,
      // AppNavigate has no catalog localManifest. It is materialized only when
      // a retrieved per-destination manifest actually selects it.
      navigationFactory: AppNavigateSkill.new,
    );

    final runtime = LocalAgentRuntime(
      skillManager: skillManager,
      manifests: candidates,
      retriever: LocalSkillRetriever(candidates),
      invoker: LocalSkillInvoker(
        skillManager: skillManager,
        capabilitySnapshotService: _capabilitySnapshots,
        capabilityKeysResolver: _localSkillCapabilityKeys,
        availabilityResolver: (manifest) =>
            conversationStyle.isCurrent && _localSkillIsAvailable(manifest),
      ),
      planner: LocalModelActionPlanner(
        complete: (messages) => brain.agentAction([
          for (final message in messages)
            if (message.role == 'system')
              (
                role: message.role,
                content:
                    '${message.content}\n\n'
                    '${ConversationStylePrompt.render(conversationStyle, locale: locale, compact: true)}',
              )
            else
              message,
        ]),
        localeProvider: () => locale,
      ),
    );
    final result = await runtime.run(
      text,
      preferredSkillIds: preferredSkillIds,
      locale: locale,
    );
    return switch (result.status) {
      LocalAgentRunStatus.finished => result.finalText,
      LocalAgentRunStatus.asked => result.finalText,
      LocalAgentRunStatus.commitRequired => AgentPromptCatalog.text(
        'app.home.local_agent_commit_required',
        locale: locale,
      ),
      LocalAgentRunStatus.maxStepsExceeded => null,
      LocalAgentRunStatus.error => null,
    };
  }

  Iterable<AppCapabilityKey>? _localSkillCapabilityKeys(
    LocalSkillManifest manifest,
  ) =>
      _localHostSkills.capabilityKeysFor(manifest) ??
      navigationManifestCapabilityKeys(manifest);

  bool _localSkillIsAvailable(LocalSkillManifest manifest) {
    if (_localHostSkills.capabilityKeysFor(manifest) != null) {
      return _localHostSkills.isManifestAvailable(manifest);
    }
    return navigationManifestCapabilityKeys(manifest) != null;
  }

  static bool _looksLikeApiKeyRequest(String text) {
    final t = text.toLowerCase();
    final mentionsKey =
        t.contains('api key') ||
        t.contains('apikey') ||
        t.contains('api-key') ||
        t.contains('key') &&
            (t.contains('配') ||
                t.contains('设') ||
                t.contains('填') ||
                t.contains('set'));
    final mentionsCloud =
        t.contains('openai') ||
        t.contains('云端') ||
        t.contains('云脑') ||
        t.contains('cloud') ||
        t.contains('claude') ||
        t.contains('gemini') ||
        t.contains('deepseek');
    final mentionsAction =
        t.contains('配置') ||
        t.contains('设置') ||
        t.contains('填一下') ||
        t.contains('填上') ||
        t.contains('configure') ||
        t.contains('setup') ||
        t.contains('set up');
    return mentionsKey || (mentionsCloud && mentionsAction);
  }
}

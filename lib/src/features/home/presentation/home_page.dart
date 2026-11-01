import 'dart:async';
import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/home_presentation_preference_service.dart';
import 'package:maaso/src/core/services/app_launch_presentation_session.dart';

import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_controller.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';
import 'package:maaso/src/features/auth/application/login_doorway_coordinator.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_selection_startup_retry.dart';
import 'package:maaso/src/features/agent/presentation/companion/embedded_avatar_presentation_policy.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/application/home_draft_intent.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/home/application/home_avatar_entrance_coordinator.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_chat_history.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_status_header.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_project_build_edit_banner.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';
import 'package:maaso/src/core/services/theme_service.dart';
import 'package:maaso/src/core/widgets/agent_card_stack.dart';
import 'package:maaso/src/core/widgets/avatar_viewport_policy.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_chat_composer.dart';
import 'package:maaso/src/core/widgets/surface_stage.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_native_frost_group.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/todo_service.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';

bool get _supportsAvatarHome =>
    EmbeddedAvatarPresentationPolicy.shouldEmbed() &&
    (appServices.maybeFind<AppPlatformCapabilities>() ??
            AppPlatformCapabilities.current())
        .actionStatus(AppActionCapability.unityAvatar)
        .available;

bool get _prefersAvatarHome =>
    _supportsAvatarHome &&
    appServices.maybeFind<HomePresentationPreferenceService>()?.mode.value !=
        HomePresentationMode.chat;

/// Adaptive home screen: embedded 3D on mobile/web, persistent chat on desktop.
///
/// Layout:
/// * Full-bleed Unity 3D world and avatar on mobile/web
/// * Persistent `self` conversation on macOS/Windows
/// * Bottom rounded input bar
/// * Top-right HUD opens quick navigation
class HomePage extends AppView<HomeController> {
  const HomePage({super.key, this.draftIntent});

  final HomeDraftIntent? draftIntent;

  @override
  Widget build(BuildContext context) => _HomeStartupPresentation(
    controller: controller,
    draftIntent: draftIntent,
    builder: _buildHome,
  );

  Widget _buildHome(
    BuildContext context,
    bool showAvatar,
    String? avatarFailureKey,
    VoidCallback? retryAvatar,
    bool retryingSelection,
    bool doorwayActive,
    int sceneAttempt,
  ) {
    final supportsAvatar = _supportsAvatarHome;
    final avatarLayout = _prefersAvatarHome && showAvatar;
    final embedAvatar = avatarLayout;
    final nativeSceneReady =
        appServices
            .maybeFind<ActiveAvatarRuntime>()
            ?.current
            ?.presentationReady
            .value ==
        true;
    final body = ThemeBuilder(
      builder: (context, palette) {
        final chrome = _HomeChrome.of(context);
        final safePadding = MediaQuery.paddingOf(context);
        final leftInset =
            chrome.sideInset + (avatarLayout ? 0 : safePadding.left);
        final rightInset =
            chrome.sideInset + (avatarLayout ? 0 : safePadding.right);
        final screen = MediaQuery.sizeOf(context);
        final chatBottom =
            chrome.composerBottom + chrome.cardStackClearance + 8;
        final chatHeight = math.min(
          screen.height * .36,
          math.max(
            0.0,
            screen.height -
                chatBottom -
                safePadding.top -
                10 -
                HomeStatusHeader.heightFor(context) -
                8,
          ),
        );
        const chatActions = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _TodoCard(),
            AgentCardStack(bottomInset: 0, showLatestReply: false),
          ],
        );
        final chatContentTop =
            safePadding.top + 10 + HomeStatusHeader.heightFor(context) + 8;
        return Stack(
          fit: StackFit.expand,
          children: [
            if (embedAvatar)
              Positioned.fill(
                child: _HomeWorldBackdrop(key: ValueKey(sceneAttempt)),
              ),

            // The iOS Unity view paints beneath Flutter. Keep the actual
            // empty Home room visible until native supplies its first frame;
            // a white Flutter cover would hide Unity while leaving HUD visible.
            if (embedAvatar && !nativeSceneReady && !doorwayActive)
              Positioned.fill(
                key: const ValueKey('home-native-scene-poster'),
                child: IgnorePointer(
                  child: Image.asset(
                    'assets/brand/home_room.png',
                    fit: BoxFit.cover,
                    excludeFromSemantics: true,
                  ),
                ),
              ),

            // Agent-authored background surfaces stay above the world layer
            // and below the avatar fallback/UI.
            const Positioned.fill(
              child: SurfaceStage(layer: SurfaceStageLayer.background),
            ),

            // The AppAgentShell owns the full-screen doorway cover across
            // Login and Home, so this route cannot expose a page transition.
            if (doorwayActive)
              const SizedBox.shrink()
            else if (avatarLayout)
              Positioned(
                key: const ValueKey('home-avatar-chat-slot'),
                right: rightInset,
                bottom: chatBottom,
                width: math.min(
                  screen.width * .68,
                  screen.width - leftInset - rightInset,
                ),
                height: chatHeight,
                child: HomeChatHistory(
                  key: const ValueKey('home-avatar-chat-window'),
                  compact: true,
                  autoHide: true,
                  contentPadding: const EdgeInsets.fromLTRB(0, 44, 0, 4),
                  latestButtonBottom: 4,
                  topFadeHeight: 44,
                  trailing: chatActions,
                ),
              )
            else
              Positioned.fill(
                child: HomeChatHistory(
                  contentPadding: EdgeInsets.fromLTRB(
                    leftInset,
                    chatContentTop,
                    rightInset,
                    chrome.composerBottom + chrome.cardStackClearance + 12,
                  ),
                  latestButtonBottom:
                      chrome.composerBottom + chrome.cardStackClearance + 12,
                  topFadeHeight: chatContentTop,
                  trailing: chatActions,
                ),
              ),
            if (avatarLayout && !doorwayActive && avatarFailureKey != null)
              Positioned(
                left: leftInset,
                right: rightInset,
                top: screen.height * .42,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      avatarFailureKey.tr,
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    if (retryAvatar != null || retryingSelection) ...[
                      const SizedBox(height: 12),
                      AppGlassButton(
                        key: ValueKey(
                          retryingSelection ||
                                  avatarFailureKey ==
                                      'home.avatar_selection_unavailable'
                              ? 'home-avatar-selection-retry'
                              : 'home-avatar-entry-retry',
                        ),
                        label: 'common.retry'.tr,
                        primary: false,
                        onPressed: retryAvatar,
                      ),
                    ],
                  ],
                ),
              ),
            // Layer 2: compact game-style HUD. Keeps the home screen
            // app-like without bringing back a full top app bar.
            if (!doorwayActive) _HomeHudLayer(avatar: avatarLayout),

            // Layer 4: Bottom chat bar — manually offsets by keyboard inset
            // because we disabled resizeToAvoidBottomInset above.
            if (!doorwayActive)
              Positioned(
                key: const ValueKey('home-composer-slot'),
                left: leftInset,
                right: rightInset,
                bottom: chrome.composerBottom,
                child: MaasoGlassBackdropScope(
                  backdropKind:
                      embedAvatar &&
                          !kIsWeb &&
                          defaultTargetPlatform == TargetPlatform.iOS
                      ? GlassBackdropKind.unityUnderlay
                      : MaasoGlassBackdropScope.maybeOf(
                              context,
                            )?.backdropKind ??
                            GlassBackdropKind.flutter,
                  renderMode: GlassRenderMode.frosted,
                  allowBlur: false,
                  child: _HomeChatBar(
                    floatingGlass: true,
                    textInputBorder: !avatarLayout,
                  ),
                ),
              ),

            // Interactive surfaces must sit above the full-screen Unity
            // platform view; otherwise the world layer can absorb touches.
            if (!doorwayActive)
              const Positioned.fill(
                child: SurfaceStage(layer: SurfaceStageLayer.foreground),
              ),
          ],
        );
      },
    );
    // Keep the same mobile scaffold/composer element while authority recovers.
    // Without a mounted avatar this shell is opaque and hosts no native blur.
    final page = supportsAvatar
        ? AppGlassScaffold(
            backdropKind: GlassBackdropKind.platformView,
            backgroundColor: embedAvatar
                ? Colors.transparent
                : Theme.of(context).scaffoldBackgroundColor,
            safeArea: false,
            resizeToAvoidBottomInset: false,
            body: body,
          )
        : AppGlassScaffold(
            backdropKind: GlassBackdropKind.flutter,
            background: const _DesktopHomeBackdrop(),
            backgroundColor: Theme.of(context).scaffoldBackgroundColor,
            safeArea: false,
            resizeToAvoidBottomInset: false,
            body: body,
          );
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.dark.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarDividerColor: Colors.transparent,
      ),
      child: HomeChatInteractionScope(child: page),
    );
  }
}

/// Every mounted account owns its local Home presentation. Renderer readiness
/// and the device-local view preference do not grant agent execution.
class _HomeStartupPresentation extends StatefulWidget {
  const _HomeStartupPresentation({
    required this.controller,
    required this.builder,
    this.draftIntent,
  });

  final HomeController controller;
  final HomeDraftIntent? draftIntent;
  final Widget Function(
    BuildContext,
    bool showAvatar,
    String? avatarFailureKey,
    VoidCallback? retryAvatar,
    bool retryingSelection,
    bool doorwayActive,
    int sceneAttempt,
  )
  builder;

  @override
  State<_HomeStartupPresentation> createState() =>
      _HomeStartupPresentationState();
}

class _HomeStartupPresentationState extends State<_HomeStartupPresentation>
    with WidgetsBindingObserver {
  Size? _viewPhysicalSize;
  double? _viewDevicePixelRatio;
  HomeAvatarEntranceCoordinator? _entrance;
  LoginDoorwayCoordinator? _doorway;
  AgentSpaceController? _room;
  final _homeActivitySource = Object();
  bool _holdingRoomReturn = false;
  HomeAvatarEntranceFence? _fence;
  AvatarRuntime? _renderer;
  bool _foreground = true;
  bool _routeIsCurrent = true;
  bool _stageLaidOut = false;
  bool _scheduled = false;
  bool _newCycle = true;
  bool _wasPresented = false;
  Timer? _presentationWatchdog;
  Object? _presentationWatchScope;
  bool _presentationTimedOut = false;
  int _sceneAttempt = 0;
  Object? _presentationIdentity;
  Object? _selectionScope;
  AvatarRuntime? _observedSelectionRenderer;
  HomeAvatarModelPresentationSignature? _observedSelectionSignature;
  bool _modelEntryPending = false;
  bool _modelEntryStarted = false;
  bool _modelEntryOwnedByDoorway = false;
  bool _preparedRevealAuthorized = false;
  int _selectionRetryEpoch = 0;
  bool _selectionRetryBusy = false;
  ActiveAvatarRuntime? _visibilityRuntime;
  AvatarRuntime? _visibilityRenderer;
  int? _visibilityModelEpoch;
  int? _visibilitySelectionGeneration;
  bool? _localVisible;
  Future<void> _visibilityWrite = Future<void>.value();
  int _visibilityEpoch = 0;

  bool get _accountMounted =>
      appServices.maybeFind<AccountSessionLifecycleService>()?.isMounted ??
      true;

  bool get _selectionDisplayReady {
    final config = appServices.maybeFind<AvatarConfigService>();
    return config == null || config.selectionDisplayCurrent;
  }

  bool get _canAnimate =>
      _foreground &&
      _routeIsCurrent &&
      _stageLaidOut &&
      _prefersAvatarHome &&
      _accountMounted &&
      _selectionDisplayReady &&
      appServices
              .maybeFind<ActiveAvatarRuntime>()
              ?.current
              ?.presentationReady
              .value ==
          true;

  @override
  void initState() {
    super.initState();
    _applyDraftIntent();
    _doorway = appServices.maybeFind<LoginDoorwayCoordinator>();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.hidden;
  }

  @override
  void didUpdateWidget(covariant _HomeStartupPresentation oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.draftIntent, widget.draftIntent) ||
        !identical(oldWidget.controller, widget.controller)) {
      _applyDraftIntent();
    }
  }

  void _applyDraftIntent() {
    final intent = widget.draftIntent;
    final controller = widget.controller;
    final editor = controller.inputController;
    final scope = AppletLocalOwnership.currentScopeKey();
    final edit = intent?.consumeProjectBuildEdit(currentScopeKey: scope);
    if (edit != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted ||
            !identical(widget.controller, controller) ||
            !identical(widget.draftIntent, intent) ||
            AppletLocalOwnership.currentScopeKey() != scope ||
            !edit.isCurrent) {
          return;
        }
        if (!controller.beginProjectBuildEditing(edit)) {
          appNavigation.showSnackBar(
            message: 'project_build.saved.edit_unavailable'.tr,
          );
        }
      });
      return;
    }
    final draft = intent?.consume(currentScopeKey: scope, existingDraft: '');
    if (draft == null) return;
    final original = editor.text;
    void apply() {
      if (!mounted ||
          !identical(widget.controller, controller) ||
          !identical(widget.draftIntent, intent) ||
          AppletLocalOwnership.currentScopeKey() != scope ||
          editor.text != original) {
        return;
      }
      controller.clearProjectBuildEditTarget();
      clearAppletEditReference();
      editor.value = TextEditingValue(
        text: draft,
        selection: TextSelection.collapsed(offset: draft.length),
      );
    }

    if (original.isEmpty) {
      if (controller.projectBuildEditTarget.value != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => apply());
      } else {
        apply();
      }
      return;
    }
    if (original.contains(draft)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted ||
          !identical(widget.draftIntent, intent) ||
          AppletLocalOwnership.currentScopeKey() != scope) {
        return;
      }
      final replace = await showAppGlassDialog<bool>(
        context: context,
        builder: (dialogContext) => SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'game_feed.draft_title'.tr,
                style: Theme.of(dialogContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 12),
              Text('game_feed.draft_description'.tr),
              const SizedBox(height: 20),
              AppGlassButton(
                key: const ValueKey('game-draft-keep'),
                label: 'game_feed.draft_keep'.tr,
                onPressed: () => Navigator.of(dialogContext).pop(false),
              ),
              const SizedBox(height: 8),
              TextButton(
                key: const ValueKey('game-draft-replace'),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text('game_feed.draft_replace'.tr),
              ),
            ],
          ),
        ),
      );
      if (replace == true) apply();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindRoom();
    final view = View.of(context);
    _viewPhysicalSize ??= view.physicalSize;
    _viewDevicePixelRatio ??= view.devicePixelRatio;
    final avatar = appServices.maybeFind<ActiveAvatarRuntime>();
    if (_entrance == null && avatar != null && _supportsAvatarHome) {
      _entrance = HomeAvatarEntranceCoordinator(
        avatar: avatar,
        consumeEntrance: AppLaunchPresentationSession.ensure().consumeEntrance,
        canAnimate: () => mounted && _canAnimate,
        revealPreparedAvatar: () async {
          if (!mounted || !_canAnimate) {
            throw StateError(
              'Home avatar entrance lost presentation authority',
            );
          }
          _preparedRevealAuthorized = true;
          await _setAvatarVisible(true, requireReceipt: true);
        },
        captureFence: () {
          final lifecycle = appServices
              .maybeFind<AccountSessionLifecycleService>();
          final generation = lifecycle?.generation;
          // A preview is account-scoped, not a grant of lease authority. World
          // entry, voice and user turns retain their execution fences.
          final controller = widget.controller;
          _renderer = avatar.current;
          final renderer = _renderer;
          final modelEpoch = renderer?.modelLoadEpoch;
          final config = appServices.maybeFind<AvatarConfigService>();
          final selectionGeneration = config?.selectionDisplayGeneration.value;
          return _fence = HomeAvatarEntranceFence(
            isCurrent: () =>
                mounted &&
                identical(widget.controller, controller) &&
                _accountMounted &&
                identical(
                  lifecycle,
                  appServices.maybeFind<AccountSessionLifecycleService>(),
                ) &&
                lifecycle?.generation == generation,
            modelIsCurrent: () =>
                identical(renderer, avatar.current) &&
                renderer?.modelLoadEpoch == modelEpoch &&
                identical(
                  config,
                  appServices.maybeFind<AvatarConfigService>(),
                ) &&
                config?.isSwitching.value != true &&
                config?.selectionDisplayGeneration.value == selectionGeneration,
          );
        },
        reduceMotion: MediaQuery.disableAnimationsOf(context),
      )..phase.addListener(_presentationChanged);
    }
    _entrance?.reduceMotion = MediaQuery.disableAnimationsOf(context);
  }

  void _bindRoom() {
    final room = appServices.maybeFind<AgentSpaceController>();
    if (identical(room, _room)) return;
    _room?.state.removeListener(_roomStateChanged);
    _room = room;
    room?.state.addListener(_roomStateChanged);
  }

  void _roomStateChanged() {
    if (!mounted) return;
    setState(() {});
    _scheduleReconcile();
  }

  bool get _nativeRoomReturnPending =>
      _room?.hasPendingHomeReturn(
        appServices.maybeFind<ActiveAvatarRuntime>()?.current,
      ) ==
      true;

  void _syncRoomActivity() {
    _room?.setHomeActivity(
      resumed: _foreground,
      currentPage: _routeIsCurrent,
      source: _homeActivitySource,
    );
  }

  void _presentationChanged() {
    if (!mounted) return;
    if (_entrance?.phase.value == HomeAvatarEntrancePhase.cancelled ||
        _entrance?.phase.value == HomeAvatarEntrancePhase.failed ||
        _entrance?.phase.value == HomeAvatarEntrancePhase.waiting) {
      _preparedRevealAuthorized = false;
    }
    if (_modelEntryPending &&
        _modelEntryStarted &&
        _entrance?.phase.value == HomeAvatarEntrancePhase.completed) {
      final config = appServices.maybeFind<AvatarConfigService>();
      final lifecycle = appServices.maybeFind<AccountSessionLifecycleService>();
      if (config?.selectionDisplayCurrent == true) {
        HomeAvatarSelectionPresentationLedger.record(
          lifecycle ?? config ?? widget.controller,
          accountGeneration: lifecycle?.generation ?? 0,
          modelSignature: HomeAvatarModelPresentationSignature(
            selectionGeneration: config!.selectionDisplayGeneration.value,
            modelLoadEpoch:
                appServices
                    .maybeFind<ActiveAvatarRuntime>()
                    ?.current
                    ?.modelLoadEpoch ??
                -1,
            renderer: appServices.maybeFind<ActiveAvatarRuntime>()?.current,
          ),
        );
      }
      _modelEntryPending = false;
      _modelEntryStarted = false;
    }
    setState(() {});
    _scheduleReconcile();
  }

  void _scheduleReconcile() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!mounted) return;
      _stageLaidOut = true;
      final doorway = _doorway;
      final entrance = _entrance;
      final room = _room;
      _syncRoomActivity();
      if (_routeIsCurrent && _nativeRoomReturnPending) {
        if (!_holdingRoomReturn) {
          _holdingRoomReturn = true;
          _visibilityEpoch++;
          _localVisible = null;
        }
        // Home chrome is already interactive. The room retains its current
        // body/camera until the real final frame, including its natural walk.
        // Preparing or hiding here would cancel that native return.
        return;
      }
      _holdingRoomReturn = false;
      if (_routeIsCurrent &&
          doorway?.active != true &&
          room != null &&
          entrance != null &&
          entrance.adoptPresentedFrame(room.consumeHomeReturnFrame)) {
        final lifecycle = appServices
            .maybeFind<AccountSessionLifecycleService>();
        final config = appServices.maybeFind<AvatarConfigService>();
        if (_fence?.isCurrent == true && _fence?.modelIsCurrent == true) {
          HomeAvatarSelectionPresentationLedger.record(
            lifecycle ?? config ?? widget.controller,
            accountGeneration: lifecycle?.generation ?? 0,
            modelSignature: HomeAvatarModelPresentationSignature(
              selectionGeneration:
                  config?.selectionDisplayGeneration.value ?? 0,
              modelLoadEpoch: _renderer?.modelLoadEpoch ?? -1,
              renderer: _renderer,
            ),
          );
        }
        _newCycle = false;
        // This current rendered receipt also satisfies a stale presentation
        // ledger's model-entry request. The coordinator still rejects an
        // in-progress selection or mismatched renderer/model/account fence.
        _modelEntryPending = false;
        _modelEntryStarted = false;
        _modelEntryOwnedByDoorway = false;
        _preparedRevealAuthorized = false;
      }
      final actorHasPresentedFrame =
          doorway?.active == true ||
          doorway?.completed == true ||
          _preparedRevealAuthorized ||
          entrance?.visible == true;
      if (_routeIsCurrent) {
        unawaited(
          _setAvatarVisible(
            _accountMounted &&
                _prefersAvatarHome &&
                _selectionDisplayReady &&
                appServices
                        .maybeFind<ActiveAvatarRuntime>()
                        ?.current
                        ?.isReady
                        .value ==
                    true &&
                actorHasPresentedFrame,
          ),
        );
      }
      if (doorway?.active == true) {
        if (!_prefersAvatarHome || !_supportsAvatarHome) {
          unawaited(doorway!.skip());
        } else if (!_foreground || !_routeIsCurrent) {
          doorway!.interrupt();
        } else {
          doorway!.reconcile(
            renderer: appServices.maybeFind<ActiveAvatarRuntime>()?.current,
            canPresent: () =>
                mounted &&
                _canAnimate &&
                appServices
                        .maybeFind<AvatarConfigService>()
                        ?.isSwitching
                        .value !=
                    true,
            reduceMotion: MediaQuery.disableAnimationsOf(context),
            prepareAvatar: () async => await appServices
                .maybeFind<AvatarConfigService>()
                ?.applyInitial(),
          );
        }
        return;
      }
      if (doorway?.completed == true && _modelEntryOwnedByDoorway) {
        _modelEntryPending = false;
        _modelEntryStarted = false;
        _modelEntryOwnedByDoorway = false;
        _preparedRevealAuthorized = false;
      }
      if (doorway?.completed == true && !_modelEntryPending) {
        _newCycle = false;
        return;
      }
      if (entrance == null) return;
      if (_newCycle) {
        _newCycle = false;
        _modelEntryStarted = _modelEntryPending;
        _preparedRevealAuthorized = false;
        // Model readiness starts a presentation; only the process launch
        // session may authorize the walk-in animation.
        entrance.begin();
      }
      if (!_canAnimate) {
        // A normal route visit must not restart a completed entrance.
        if (entrance.phase.value != HomeAvatarEntrancePhase.completed &&
            entrance.phase.value != HomeAvatarEntrancePhase.cancelled &&
            entrance.phase.value != HomeAvatarEntrancePhase.failed) {
          unawaited(entrance.cancel());
        }
        return;
      }
      if (entrance.phase.value == HomeAvatarEntrancePhase.cancelled) {
        _modelEntryStarted = _modelEntryPending;
        _preparedRevealAuthorized = false;
        entrance.begin();
      } else if (entrance.phase.value != HomeAvatarEntrancePhase.failed) {
        unawaited(entrance.reconcile());
      }
    });
  }

  Future<void> _setAvatarVisible(bool visible, {bool requireReceipt = false}) {
    // Native desktop Home does not embed the renderer. Its independent pet
    // shares this runtime, so only the desktop shell may control visibility.
    if (!EmbeddedAvatarPresentationPolicy.shouldEmbed()) {
      return Future<void>.value();
    }
    final avatar = appServices.maybeFind<ActiveAvatarRuntime>();
    if (avatar == null) return Future<void>.value();
    final renderer = avatar.current;
    if (_nativeRoomReturnPending) {
      if (requireReceipt) {
        return Future<void>.error(
          StateError('The native room still owns the Home return'),
        );
      }
      return Future<void>.value();
    }
    final modelEpoch = renderer?.modelLoadEpoch;
    final selectionGeneration = appServices
        .maybeFind<AvatarConfigService>()
        ?.selectionDisplayGeneration
        .value;
    if (!requireReceipt &&
        identical(avatar, _visibilityRuntime) &&
        identical(renderer, _visibilityRenderer) &&
        modelEpoch == _visibilityModelEpoch &&
        selectionGeneration == _visibilitySelectionGeneration &&
        _localVisible == visible) {
      return _visibilityWrite;
    }
    if (!identical(avatar, _visibilityRuntime)) {
      _visibilityWrite = Future<void>.value();
    }
    _visibilityRuntime = avatar;
    _visibilityRenderer = renderer;
    _visibilityModelEpoch = modelEpoch;
    _visibilitySelectionGeneration = selectionGeneration;
    _localVisible = visible;
    final epoch = _visibilityEpoch;
    final lifecycle = appServices.maybeFind<AccountSessionLifecycleService>();
    final generation = lifecycle?.generation;
    final controller = widget.controller;
    final write = _visibilityWrite.then((_) async {
      final currentLifecycle = appServices
          .maybeFind<AccountSessionLifecycleService>();
      if (_nativeRoomReturnPending) {
        if (requireReceipt) {
          throw StateError('The native room still owns the Home return');
        }
        return;
      }
      if (!mounted ||
          epoch != _visibilityEpoch ||
          !_routeIsCurrent ||
          !(ModalRoute.of(context)?.isCurrent ?? true) ||
          !identical(avatar, _visibilityRuntime) ||
          !identical(avatar, appServices.maybeFind<ActiveAvatarRuntime>()) ||
          !identical(renderer, avatar.current) ||
          renderer?.modelLoadEpoch != modelEpoch ||
          appServices
                  .maybeFind<AvatarConfigService>()
                  ?.selectionDisplayGeneration
                  .value !=
              selectionGeneration ||
          !identical(controller, widget.controller) ||
          !identical(lifecycle, currentLifecycle) ||
          generation != currentLifecycle?.generation ||
          (visible && !_accountMounted)) {
        if (requireReceipt) {
          throw StateError(
            'Home avatar visibility lost presentation authority',
          );
        }
        return;
      }
      await avatar.setLocalAvatarVisible(visible);
      if (epoch != _visibilityEpoch ||
          !identical(renderer, avatar.current) ||
          renderer?.modelLoadEpoch != modelEpoch ||
          appServices
                  .maybeFind<AvatarConfigService>()
                  ?.selectionDisplayGeneration
                  .value !=
              selectionGeneration) {
        throw StateError('Home avatar model changed before visibility receipt');
      }
    });
    _visibilityWrite = write.catchError((Object _) {
      if (epoch == _visibilityEpoch &&
          identical(avatar, _visibilityRuntime) &&
          identical(renderer, _visibilityRenderer) &&
          modelEpoch == _visibilityModelEpoch &&
          selectionGeneration == _visibilitySelectionGeneration) {
        _localVisible = null;
      }
    });
    return requireReceipt ? write : _visibilityWrite;
  }

  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final view = View.of(context);
    final changed =
        _viewPhysicalSize != view.physicalSize ||
        _viewDevicePixelRatio != view.devicePixelRatio;
    _viewPhysicalSize = view.physicalSize;
    _viewDevicePixelRatio = view.devicePixelRatio;
    // Keyboard dismissal after login changes insets, not the camera viewport.
    // Preserve the in-flight door; real rotation/window resizing still retires it.
    if (changed) _doorway?.interrupt();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      appServices.maybeFind<AgentSpaceController>()?.discardHomeReturnFrame();
      _foreground = false;
      _syncRoomActivity();
      _doorway?.interrupt();
      if (_entrance?.phase.value != HomeAvatarEntrancePhase.completed) {
        unawaited(_entrance?.cancel());
      }
      _presentationChanged();
    } else if (state == AppLifecycleState.resumed && !_foreground) {
      _foreground = true;
      _syncRoomActivity();
      // Native view attachment can hide the same selected model while paused.
      // Reassert its visibility, retaining the completed entrance transaction.
      _visibilityEpoch++;
      _localVisible = null;
      // Keep the serialized native tail: an in-flight hide must finish before
      // the current reveal. Queued writes from the old epoch skip dispatch.
      _presentationChanged();
    }
  }

  void _retryEntrance() {
    _newCycle = true;
    _presentationChanged();
  }

  void _syncPresentationWatchdog(AvatarRuntime? renderer, bool ready) {
    if (ready ||
        _nativeRoomReturnPending ||
        !_accountMounted ||
        !_prefersAvatarHome ||
        !_foreground ||
        !_routeIsCurrent) {
      _presentationWatchdog?.cancel();
      _presentationWatchdog = null;
      _presentationWatchScope = null;
      _presentationTimedOut = false;
      return;
    }
    final scope = (
      renderer,
      appServices.maybeFind<AccountSessionLifecycleService>(),
      appServices.maybeFind<AccountSessionLifecycleService>()?.generation,
      _sceneAttempt,
    );
    if (_presentationWatchScope == scope) return;
    _presentationWatchdog?.cancel();
    _presentationWatchScope = scope;
    _presentationTimedOut = false;
    _presentationWatchdog = Timer(const Duration(seconds: 22), () {
      if (!mounted || _presentationWatchScope != scope) return;
      TurnTrace.event(
        'home.avatar_presentation.timeout',
        details:
            'stage=native_attachment sceneAttempt=$_sceneAttempt modelEpoch=${renderer?.modelLoadEpoch}',
      );
      setState(() => _presentationTimedOut = true);
    });
  }

  void _retryPresentation() {
    // Replace only the native view owner, preserving the composer, draft and
    // conversation. Its new mount starts a fresh bounded attachment attempt.
    _presentationWatchdog?.cancel();
    _presentationWatchScope = null;
    setState(() {
      _sceneAttempt++;
      _newCycle = true;
      _presentationTimedOut = false;
    });
  }

  void _retrySelectedAvatar() {
    final config = appServices.maybeFind<AvatarConfigService>();
    if (!mounted || config == null || _selectionRetryBusy) return;
    final retry = AvatarSelectionStartupRetry.forConfig(config);
    if (!retry.hasBoundRetry) return;
    final epoch = ++_selectionRetryEpoch;
    setState(() => _selectionRetryBusy = true);
    unawaited(() async {
      try {
        await retry.retryBound();
      } catch (_) {
        // Keep the account-scoped error visible. A stale owner must not update
        // the replacement account's Home or reveal a bundled fallback.
      } finally {
        if (mounted && epoch == _selectionRetryEpoch) {
          setState(() => _selectionRetryBusy = false);
          _scheduleReconcile();
        }
      }
    }());
  }

  void _requestModelEntry({required bool doorwayActive}) {
    _modelEntryPending = true;
    _modelEntryStarted = false;
    _modelEntryOwnedByDoorway = doorwayActive;
    _preparedRevealAuthorized = false;
    _newCycle = true;
  }

  @override
  void dispose() {
    _visibilityEpoch++;
    _presentationWatchdog?.cancel();
    _selectionRetryEpoch++;
    WidgetsBinding.instance.removeObserver(this);
    _entrance?.phase.removeListener(_presentationChanged);
    _entrance?.dispose();
    _doorway?.interrupt();
    _room?.state.removeListener(_roomStateChanged);
    _room?.setHomeActivity(
      resumed: _foreground,
      currentPage: false,
      source: _homeActivitySource,
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppReactiveBuilder(() {
    _bindRoom();
    final controller = widget.controller;
    final wasCurrent = _routeIsCurrent;
    _routeIsCurrent = ModalRoute.isCurrentOf(context) ?? true;
    if (wasCurrent && !_routeIsCurrent) {
      _visibilityEpoch++;
      _localVisible = null;
    }
    final avatar = appServices.maybeFind<ActiveAvatarRuntime>();
    // Subscribe to the selected renderer and native ready receipt as well as
    // authority/preference state; readiness can arrive after Home's first frame.
    avatar?.backend.value;
    final ready = avatar?.current?.isReady.value ?? false;
    final presentationReady = avatar?.current?.presentationReady.value ?? false;
    _syncPresentationWatchdog(avatar?.current, presentationReady);
    final config = appServices.maybeFind<AvatarConfigService>();
    final selectionReadOnly =
        config?.selectionAuthorityState.value ==
        AvatarSelectionAuthorityState.readOnlyBundled;
    config?.selectionDisplayReady.value;
    final selectionReady = config?.selectionDisplayCurrent ?? true;
    final selectionGeneration = config?.selectionDisplayGeneration.value ?? 0;
    final selectionSignature = HomeAvatarModelPresentationSignature(
      selectionGeneration: selectionGeneration,
      modelLoadEpoch: avatar?.current?.modelLoadEpoch ?? -1,
      renderer: avatar?.current,
    );
    final entrance = _entrance;
    final doorway = _doorway;
    doorway?.phase.value;
    final doorwayActive = doorway?.active == true;
    final lifecycle = appServices.maybeFind<AccountSessionLifecycleService>();
    final accountGeneration = lifecycle?.generation ?? 0;
    final ledgerOwner = lifecycle ?? config ?? controller;
    final previouslyPresentedSignature =
        HomeAvatarSelectionPresentationLedger.lastPresented(
          ledgerOwner,
          accountGeneration,
        );
    final selectionScope = (
      controller,
      lifecycle,
      lifecycle?.generation,
      config,
    );
    if (_selectionScope != selectionScope) {
      _selectionScope = selectionScope;
      _selectionRetryEpoch++;
      _selectionRetryBusy = false;
      _observedSelectionSignature = selectionSignature;
      _observedSelectionRenderer = avatar?.current;
      _modelEntryPending = false;
      _modelEntryStarted = false;
      _modelEntryOwnedByDoorway = false;
      _preparedRevealAuthorized = false;
      if (selectionReady &&
          previouslyPresentedSignature != null &&
          previouslyPresentedSignature != selectionSignature) {
        _requestModelEntry(doorwayActive: doorwayActive);
      }
    } else {
      final rendererChanged =
          _observedSelectionRenderer != null &&
          avatar?.current != null &&
          !identical(_observedSelectionRenderer, avatar?.current) &&
          _wasPresented;
      final selectionChanged =
          selectionReady &&
          _observedSelectionSignature != null &&
          _observedSelectionSignature != selectionSignature;
      final unpresentedGeneration =
          selectionReady &&
          previouslyPresentedSignature != null &&
          previouslyPresentedSignature != selectionSignature &&
          !_modelEntryPending;
      if (rendererChanged || selectionChanged || unpresentedGeneration) {
        _requestModelEntry(doorwayActive: doorwayActive);
      }
      _observedSelectionRenderer = avatar?.current;
      if (selectionReady) _observedSelectionSignature = selectionSignature;
    }
    final completed =
        !_modelEntryPending &&
        (doorway?.completed == true ||
            (entrance?.phase.value == HomeAvatarEntrancePhase.completed &&
                _fence?.isCurrent == true &&
                identical(_renderer, avatar?.current) &&
                ready));
    final presentationIdentity = (
      controller,
      lifecycle,
      lifecycle?.generation,
      avatar,
      avatar?.current,
    );
    if (_presentationIdentity != presentationIdentity) {
      _visibilityEpoch++;
      _visibilityWrite = Future<void>.value();
      _presentationIdentity = presentationIdentity;
      _wasPresented = false;
      _localVisible = null;
      _newCycle = true;
    }
    if (!_routeIsCurrent) _localVisible = null;
    if (!_accountMounted) _wasPresented = false;
    final showAvatar = _accountMounted;
    final pending =
        _nativeRoomReturnPending ||
        doorwayActive ||
        (!completed &&
            _prefersAvatarHome &&
            showAvatar &&
            entrance != null &&
            (_newCycle || (!completed && !entrance.visible)));
    if (_routeIsCurrent &&
        _prefersAvatarHome &&
        showAvatar &&
        !pending &&
        (entrance == null || completed)) {
      _wasPresented = true;
    }
    if (_routeIsCurrent &&
        _wasPresented &&
        !_modelEntryPending &&
        selectionReady &&
        ready &&
        _prefersAvatarHome &&
        showAvatar) {
      HomeAvatarSelectionPresentationLedger.record(
        ledgerOwner,
        accountGeneration: accountGeneration,
        modelSignature: selectionSignature,
      );
    }
    _scheduleReconcile();
    String? avatarFailureKey;
    VoidCallback? retryAvatar;
    if (_presentationTimedOut) {
      avatarFailureKey = 'home.avatar_entry_failed';
      retryAvatar = _retryPresentation;
    } else if (_selectionRetryBusy) {
      avatarFailureKey = 'home.avatar_selection_retrying';
    } else if (selectionReadOnly) {
      avatarFailureKey = 'home.avatar_selection_unavailable';
      if (config != null &&
          AvatarSelectionStartupRetry.forConfig(config).hasBoundRetry) {
        retryAvatar = _retrySelectedAvatar;
      }
    } else if (entrance?.phase.value == HomeAvatarEntrancePhase.failed) {
      avatarFailureKey = 'home.avatar_entry_failed';
      retryAvatar = _retryEntrance;
    }
    return widget.builder(
      context,
      showAvatar,
      avatarFailureKey,
      retryAvatar,
      _selectionRetryBusy,
      doorwayActive,
      _sceneAttempt,
    );
  });
}

class _DesktopHomeBackdrop extends StatelessWidget {
  const _DesktopHomeBackdrop();

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      key: const ValueKey<String>('desktop-home-backdrop'),
      color: Theme.of(context).scaffoldBackgroundColor,
    );
  }
}

class _HomeWorldBackdrop extends StatelessWidget {
  const _HomeWorldBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    return UnityAvatarView(
      includeWorld: true,
      backgroundColor: Colors.transparent,
      viewportSafeArea: _HomeChrome.avatarViewportSafeAreaOf(context),
      viewportActive: ModalRoute.of(context)?.isCurrent ?? true,
    );
  }
}

class HomeAvatarViewportPolicy {
  const HomeAvatarViewportPolicy._();

  static const double baseBottom = MaasoAvatarViewportPolicy.baseBottom;
  static const double composerHeight = MaasoAvatarViewportPolicy.composerHeight;
  static const double composerGap = MaasoAvatarViewportPolicy.composerGap;
  static const double hudSafeClearance =
      MaasoAvatarViewportPolicy.hudSafeClearance;
  static const double composerSafeGap =
      MaasoAvatarViewportPolicy.composerSafeGap;

  static double composerBottomFor({
    required EdgeInsets padding,
    required EdgeInsets viewInsets,
  }) {
    return MaasoAvatarViewportPolicy.composerBottomFor(
      padding: padding,
      viewInsets: viewInsets,
    );
  }

  static AvatarViewportSafeArea safeAreaFor({
    required Size size,
    required EdgeInsets padding,
    required EdgeInsets viewInsets,
  }) {
    return MaasoAvatarViewportPolicy.safeAreaFor(
      size: size,
      padding: padding,
      viewInsets: viewInsets,
    );
  }
}

class _HomeChrome {
  const _HomeChrome({
    required this.sideInset,
    required this.composerBottom,
    required this.cardStackClearance,
  });

  static const double _composerGap = HomeAvatarViewportPolicy.composerGap;

  final double sideInset;
  final double composerBottom;
  final double cardStackClearance;

  static _HomeChrome of(BuildContext context) {
    final media = MediaQuery.of(context);
    final horizontal = media.size.width >= 720 ? 24.0 : 14.0;
    final composerBottom = HomeAvatarViewportPolicy.composerBottomFor(
      padding: media.padding,
      viewInsets: media.viewInsets,
    );
    return _HomeChrome(
      sideInset: horizontal,
      composerBottom: composerBottom,
      cardStackClearance:
          (HomeChatInteractionScope.maybeOf(context)?.composerExtent ?? 124) +
          _composerGap,
    );
  }

  static AvatarViewportSafeArea avatarViewportSafeAreaOf(BuildContext context) {
    final media = MediaQuery.of(context);
    return HomeAvatarViewportPolicy.safeAreaFor(
      size: media.size,
      // Keep camera framing independent of the keyboard's consumed padding.
      padding: media.viewPadding,
      viewInsets: media.viewInsets,
    );
  }
}

class _HomeHudLayer extends StatefulWidget {
  const _HomeHudLayer({required this.avatar});

  final bool avatar;

  @override
  State<_HomeHudLayer> createState() => _HomeHudLayerState();
}

class _HomeHudLayerState extends State<_HomeHudLayer>
    with SingleTickerProviderStateMixin {
  static const _destinations = <_HudMenuDestination>[
    _HudMenuDestination(
      label: 'game_feed.title',
      icon: Icons.sports_esports_rounded,
      route: AppRouteCatalog.gameFeed,
    ),
    _HudMenuDestination(
      label: 'widgets.title',
      icon: Icons.widgets_rounded,
      route: AppRouteCatalog.widgetsHub,
    ),
    _HudMenuDestination(
      label: 'store_hub.marketplace',
      icon: Icons.storefront_rounded,
      route: AppRouteCatalog.avatars,
    ),
    _HudMenuDestination(
      label: 'home.menu.agent_space',
      icon: Icons.home_outlined,
      route: AppRouteCatalog.agentSpace,
    ),
    _HudMenuDestination(
      label: 'settings.title',
      icon: Icons.settings_rounded,
      route: AppRouteCatalog.settings,
    ),
  ];

  bool _expanded = false;
  bool _menuReady = false;
  int _menuGeneration = 0;
  late final _menuAnimation =
      AnimationController(vsync: this, duration: MaasoFrostTokens.motionPanel)
        ..addStatusListener((status) {
          if (status == AnimationStatus.dismissed && mounted) setState(() {});
        });

  void _animateMenu() {
    final media = MediaQuery.of(context);
    if (media.disableAnimations || media.accessibleNavigation) {
      _menuAnimation.value = _expanded ? 1 : 0;
    } else if (_expanded && _menuReady) {
      _menuAnimation.forward();
    } else if (!_expanded) {
      _menuAnimation.reverse();
    }
  }

  @override
  void dispose() {
    _menuAnimation.dispose();
    super.dispose();
  }

  void _close({bool immediate = false}) {
    if (!mounted || (!_expanded && _menuAnimation.isDismissed)) return;
    HomeChatInteractionScope.maybeOf(context)?.setMenuExpanded(false);
    setState(() {
      _expanded = false;
      if (immediate) _menuReady = false;
    });
    if (immediate) {
      // A covered route can pause the reverse ticker. Retire the panel before
      // navigation so its last visible frame cannot resume over Home later.
      _menuAnimation.stop();
      _menuAnimation.value = 0;
    } else {
      _animateMenu();
    }
  }

  void _toggle() {
    if (!_expanded && _menuAnimation.isDismissed) {
      _menuReady = false;
      _menuGeneration++;
    }
    HomeChatInteractionScope.maybeOf(context)?.setMenuExpanded(!_expanded);
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => _expanded = !_expanded);
    _animateMenu();
  }

  void _onMenuReady() {
    if (!mounted || !_expanded || _menuReady) return;
    _menuReady = true;
    _animateMenu();
  }

  Future<void> _openRoute(String route) async {
    _close(immediate: true);
    await appNavigation.push(route);
    if (mounted) setState(() {});
  }

  Future<void> _openTaskHistory() async {
    _close();
    if (mounted) await showAgentTaskLedger(context);
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final top = padding.top + 10;
    final chrome = _HomeChrome.of(context);
    return Positioned.fill(
      child: Stack(
        children: [
          if (_expanded)
            Positioned.fill(
              key: const ValueKey('home-menu-dismiss-layer'),
              child: HomeChatActivityExclusion(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: _close,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          Positioned(
            key: const ValueKey('home-status-header-layer'),
            left: 14 + padding.left,
            right: 14 + padding.right,
            top: top,
            child: HomeChatActivityExclusion(
              child: HomeStatusHeader(
                avatar: widget.avatar,
                expanded: _expanded,
                onMenuToggle: _toggle,
                onTaskHistory: _openTaskHistory,
                onProfile: () => _openRoute(AppRouteCatalog.profile),
              ),
            ),
          ),
          if (_expanded || !_menuAnimation.isDismissed)
            Positioned(
              key: const ValueKey('home-menu-panel-layer'),
              right: 14 + padding.right,
              top: top + HomeStatusHeader.heightFor(context),
              child: HomeChatActivityExclusion(
                child: IgnorePointer(
                  ignoring: !_expanded,
                  child: ExcludeSemantics(
                    excluding: !_expanded,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: ConstrainedBox(
                        key: const ValueKey('hud-menu-open'),
                        constraints: BoxConstraints(
                          maxHeight: math.max(
                            0,
                            MediaQuery.sizeOf(context).height -
                                top -
                                HomeStatusHeader.heightFor(context) -
                                chrome.composerBottom -
                                chrome.cardStackClearance -
                                8,
                          ),
                        ),
                        child: AnimatedBuilder(
                          animation: _menuAnimation,
                          builder: (context, _) => _HudMenuPanel(
                            key: ValueKey((
                              'home-menu-generation',
                              _menuGeneration,
                            )),
                            avatar: widget.avatar,
                            opacity: Curves.easeOutCubic.transform(
                              _menuAnimation.value,
                            ),
                            destinations: _destinations,
                            onRoute: _openRoute,
                            onReady: _onMenuReady,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _HudMenuPanel extends StatelessWidget {
  const _HudMenuPanel({
    required this.destinations,
    required this.onRoute,
    required this.avatar,
    required this.opacity,
    required this.onReady,
    super.key,
  });

  final List<_HudMenuDestination> destinations;
  final ValueChanged<String> onRoute;
  final bool avatar;
  final double opacity;
  final VoidCallback onReady;

  @override
  Widget build(BuildContext context) {
    final content = SizedBox(
      width: 204,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final destination in destinations)
                _HudMenuItem(
                  key: ValueKey('home-menu-${destination.route}'),
                  icon: destination.icon,
                  label: destination.label,
                  onTap: () => onRoute(destination.route),
                ),
            ],
          ),
        ),
      ),
    );
    // The native material owns its opacity mask. Never fade or scale the
    // platform view with an AnimatedSwitcher; fast toggles reuse one sampler.
    return AppNativeFrostGroup(
      key: const ValueKey('home-menu-frost'),
      enabled: avatar,
      fit: StackFit.loose,
      opacity: opacity,
      deferRevealUntilReady: true,
      onReady: onReady,
      topFadeHeight: 0,
      bottomFadeHeight: 0,
      child: Builder(
        builder: (context) {
          if (!AppNativeFrostRegion.available(context)) {
            return AppGlassSurface(
              role: AppGlassSurfaceRole.field,
              cornerRadius: 20,
              child: content,
            );
          }
          return AppNativeFrostRegion(radius: 20, child: content);
        },
      ),
    );
  }
}

class _HudMenuItem extends StatelessWidget {
  const _HudMenuItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final color = ColorConstant.textPrimary.withValues(alpha: 0.84);
    final content = SizedBox(
      height: 44,
      child: Row(
        children: [
          SizedBox.square(
            dimension: 32,
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label.tr,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: content,
        ),
      ),
    );
  }
}

class _HudMenuDestination {
  const _HudMenuDestination({
    required this.label,
    required this.icon,
    required this.route,
  });

  final String label;
  final IconData icon;
  final String route;
}

// —————————————————— bottom chat bar ——————————————————

/// Thin wrapper that binds [ChatInputBar] to HomeController's reactive state.
/// Voice-mode + waveform + ASR integration all live in the underlying
/// [ChatInputBar].
///
/// Note: plan-mode used to live in the `leading` slot here; the affordance
/// was removed from the input bar (it confused voice-first users).  The
/// controller-side plumbing in [HomeController.send] stays put so a future
/// slash command or settings entry can re-arm it without UI churn.
class _HomeChatBar extends StatelessWidget {
  const _HomeChatBar({
    this.floatingGlass = false,
    this.textInputBorder = false,
  });

  final bool floatingGlass;
  final bool textInputBorder;

  @override
  Widget build(BuildContext context) {
    final c = appServices.find<HomeController>();
    return AppReactiveBuilder(() {
      final hint = appServices.find<LocaleConfigService>().chatInputHint;
      Widget? header;
      if (c.projectBuildEditTarget.value case final target?
          when target.isCurrent) {
        header = Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: HomeProjectBuildEditBanner(
            title: target.title,
            enabled: !c.busy,
            onClear: c.clearProjectBuildEditTarget,
          ),
        );
      } else if (appletEditReference.value case final reference?) {
        header = Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: AppGlassSurface(
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.all(12),
                  child: Icon(Icons.apps_rounded, size: 22),
                ),
                Expanded(
                  child: Text(
                    'widgets.edit_reference'.trParams({
                      'name': reference.item.title,
                    }),
                    key: const ValueKey('applet-edit-reference'),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                IconButton(
                  tooltip: 'common.remove'.tr,
                  onPressed: c.busy ? null : clearAppletEditReference,
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
        );
      }
      return HomeChatComposer(
        key: ValueKey(c.composerOwnerToken),
        controller: c,
        hint: hint,
        header: header,
        textInputBorder: textInputBorder,
        floatingGlass: floatingGlass,
      );
    });
  }
}

// —————————————————— todo card (multi-step checklist) ——————————————————

class _TodoCard extends StatelessWidget {
  const _TodoCard();

  @override
  Widget build(BuildContext context) {
    if (!appServices.isRegistered<TodoService>()) {
      return const SizedBox.shrink();
    }
    final svc = appServices.find<TodoService>();
    return AppReactiveBuilder(() {
      final items = svc.items;
      if (items.isEmpty) return const SizedBox.shrink();
      final done = items.where((t) => t.done).length;
      return ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 244),
        child: AppGlassSurface(
          role: AppGlassSurfaceRole.transient,
          behavior: AppGlassSurfaceBehavior.automatic,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
          cornerRadius: 14,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(
                    Icons.checklist_rounded,
                    size: 14,
                    color: ColorConstant.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    'home.plan_progress'.trParams({
                      'done': done.toString(),
                      'total': items.length.toString(),
                    }),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: ColorConstant.textSecondary,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              ...items
                  .take(6)
                  .map(
                    (t) => Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            t.done
                                ? Icons.check_circle_rounded
                                : Icons.radio_button_unchecked_rounded,
                            size: 14,
                            color: t.done
                                ? ColorConstant.primaryColor
                                : ColorConstant.textSecondary.withValues(
                                    alpha: 0.6,
                                  ),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              t.text,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 11,
                                height: 1.3,
                                color: t.done
                                    ? ColorConstant.textSecondary
                                    : ColorConstant.textPrimary,
                                decoration: t.done
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              if (items.length > 6)
                Padding(
                  padding: const EdgeInsets.only(top: 2, left: 20),
                  child: Text(
                    'common.more_count'.trParams({
                      'count': (items.length - 6).toString(),
                    }),
                    style: const TextStyle(
                      fontSize: 10,
                      color: ColorConstant.textSecondary,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }
}

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_camera_director.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/agent_handoff_service.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/infrastructure/desktop_window_mode_controller_factory.dart';
import 'package:maaso/src/desktop/presentation/desktop_companion_shell.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_channel_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_coordinator.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/companion/companion_voice_session_boundary.dart';
import 'package:maaso/src/features/agent/application/companion/companion_voice_session_controller.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_coordinator.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_scope.dart';
import 'package:maaso/src/features/agent/presentation/companion/companion_session_scope.dart';
import 'package:maaso/src/features/agent/presentation/companion/embedded_avatar_presentation_policy.dart';
import 'package:maaso/src/features/agent/presentation/ui_control/agent_control_hud.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_controller.dart';

/// Hosts the global agent HUD and observes real pointer activity as takeover.
class AppAgentShell extends StatefulWidget {
  const AppAgentShell({
    required this.coordinator,
    required this.child,
    this.agentId,
    this.onOrbTap,
    this.showOrb = false,
    this.routeListenable,
    this.currentRoute,
    this.desktopWindowModeController,
    this.desktopCompanionHostGateway,
    super.key,
  });

  static const Key pointerListenerKey = ValueKey<String>(
    'app-agent-shell-pointer-listener',
  );

  final AgentUiControlCoordinator coordinator;
  final Widget child;
  final String? agentId;
  final VoidCallback? onOrbTap;
  final bool showOrb;
  final Listenable? routeListenable;
  final String Function()? currentRoute;
  final DesktopWindowModeController? desktopWindowModeController;
  final DesktopCompanionHostGateway? desktopCompanionHostGateway;

  @override
  State<AppAgentShell> createState() => _AppAgentShellState();
}

class _AppAgentShellState extends State<AppAgentShell>
    with WidgetsBindingObserver {
  Listenable? _activeRouteListenable;
  String? _lastRoute;
  bool _routeScopeRebuildScheduled = false;
  CompanionVoiceSessionController? _companion;
  DBService? _companionDatabase;
  AgentRuntimeRegistry? _companionRuntimeRegistry;
  AvatarPortalChannelGateway? _portalGateway;
  AvatarPortalCoordinator? _portal;
  ActiveAvatarRuntime? _portalAvatarRuntime;
  DesktopCompanionPreferencesService? _desktopCompanionPreferences;
  StreamSubscription<DesktopCompanionPresentationConfigV1>?
  _desktopCompanionPreferencesSubscription;
  late final DesktopWindowModeController _desktopWindowModeController;
  late final bool _ownsDesktopWindowModeController;
  Future<void> _portalLifecycleQueue = Future<void>.value();
  Future<void>? _desktopAvatarPreparation;
  Completer<void>? _desktopPreparationCancellation;
  AvatarRuntime? _desktopSelectionRenderer;
  ActiveAvatarRuntime? _localVisibilityRuntime;
  bool? _localAvatarVisible;
  bool? _appliedLocalAvatarVisible;
  Future<void> _localVisibilityWrite = Future<void>.value();
  AvatarConfigService? _desktopAvatarConfig;
  final _desktopAvatarSelectionWorkers = <Worker>[];
  AgentHandoffService? _handoff;
  AccountSessionLifecycleService? _accountLifecycle;
  Object? _desktopAccountBoundary;
  GlobalKey _desktopShellKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
    _ownsDesktopWindowModeController =
        widget.desktopWindowModeController == null;
    _desktopWindowModeController =
        widget.desktopWindowModeController ??
        createDesktopWindowModeController();
    _desktopWindowModeController.addListener(_handleDesktopWindowModeChanged);
    _handoff = appServices.maybeFind<AgentHandoffService>();
    _handoff?.addListener(_handleHandoffChanged);
    _reconcileCompanionServices();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reconcileCompanionServices();
    _bindRouteListener();
  }

  @override
  void didUpdateWidget(covariant AppAgentShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.routeListenable != widget.routeListenable) {
      _bindRouteListener();
    }
    _reconcileCompanionServices();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _syncApplicationPresence(state);
    if (state != AppLifecycleState.resumed) {
      widget.coordinator.pauseForUserActivity(reason: 'app_background');
      _companion?.deactivate();
    }

    if (_desktopWindowModeController.supportsIndependentPetWindow &&
        _desktopWindowModeController.isTransitioning &&
        state != AppLifecycleState.detached) {
      // Hiding the normal app window is part of entering independent pet mode.
      // Wait for the controller to commit petVisible before reconciling the
      // shared texture lease.
      return;
    }

    if (!_shouldKeepPortalResident()) {
      _reconcilePortalLifecycle();
      return;
    }

    switch (state) {
      case AppLifecycleState.resumed:
        _enqueuePortalLifecycle(_resumePortalAfterLifecycleChange);
      case AppLifecycleState.inactive:
        // A desktop pet remains visible when another application has focus.
        // Keep its texture lease alive while input is inactive.
        break;
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        if (_desktopWindowModeController.supportsIndependentPetWindow) {
          // The normal app window is intentionally hidden while the native
          // companion remains visible. Suspending here would stop the shared
          // avatar runtime just because the independent app window lost focus.
          break;
        }
        _enqueuePortalLifecycle((portal) => portal.suspend());
      case AppLifecycleState.detached:
        _enqueuePortalLifecycle((portal) => portal.release());
    }
  }

  @override
  void dispose() {
    _cancelDesktopAvatarPreparation();
    for (final worker in _desktopAvatarSelectionWorkers) {
      worker.dispose();
    }
    _desktopAvatarSelectionWorkers.clear();
    _accountLifecycle?.updateApplicationPresence(foreground: false);
    _handoff?.removeListener(_handleHandoffChanged);
    _accountLifecycle?.removeListener(_handleAccountLifecycleChanged);
    _activeRouteListenable?.removeListener(_handleRouteChange);
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
    WidgetsBinding.instance.removeObserver(this);
    _disposeCompanionController();
    unawaited(_desktopCompanionPreferencesSubscription?.cancel());
    _desktopCompanionPreferencesSubscription = null;
    _desktopCompanionPreferences = null;
    unawaited(_portalLifecycleQueue.then<void>((_) => _closePortalSession()));
    _desktopWindowModeController.removeListener(
      _handleDesktopWindowModeChanged,
    );
    if (_ownsDesktopWindowModeController) {
      _desktopWindowModeController.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final companion = _companion;
    final portal = _portal;
    final avatarRuntime = _portalAvatarRuntime;
    final replyPresentation = appServices
        .maybeFind<AgentReplyPresentationService>();
    final desktopPetAvailable =
        _avatarMayAppear &&
        replyPresentation != null &&
        (!_usesNativeDesktopPetHost ||
            appServices.maybeFind<AvatarConfigService>() != null);
    final desktopChild = DesktopCompanionShell(
      key: _desktopShellKey,
      keepAppWindowWithPet: _usesMacOSDesktopAvatarPortal,
      windowController: _desktopWindowModeController,
      routeListenable: widget.routeListenable,
      currentRoute: widget.currentRoute,
      petAvailable: desktopPetAvailable,
      hostGateway: widget.desktopCompanionHostGateway,
      replyPresentation: replyPresentation,
      preparePetPresentation: _usesNativeDesktopPetHost
          ? _prepareDesktopPetPresentation
          : null,
      petPresentationListenable: _usesMacOSDesktopAvatarPortal ? portal : null,
      isPetPresentationFailed: !_usesMacOSDesktopAvatarPortal || portal == null
          ? null
          : () => portal.phase == AvatarPortalPhase.failed,
      isPetPresentationReady: !_usesMacOSDesktopAvatarPortal || portal == null
          ? null
          : () =>
                _avatarMayAppear &&
                portal.isVisible &&
                !portal.capturesWorld &&
                _desktopAvatarConfig?.selectionDisplayCurrent == true &&
                _appliedLocalAvatarVisible == true,
      isScenePresentation: !_usesMacOSDesktopAvatarPortal || portal == null
          ? null
          : () => portal.capturesWorld,
      child: widget.child,
    );
    Widget routedChild = desktopChild;
    if (portal != null && avatarRuntime != null) {
      if (companion != null) {
        routedChild = CompanionSessionScope(
          voice: companion,
          portal: portal,
          avatarRuntime: avatarRuntime,
          child: routedChild,
        );
      }
      routedChild = AvatarPortalScope(
        portal: portal,
        avatarRuntime: avatarRuntime,
        sceneSurfaceActive:
            _desktopWindowModeController.mode != DesktopWindowMode.pet &&
            (!_usesMacOSDesktopAvatarPortal || _isSceneRoute(_lastRoute)),
        child: routedChild,
      );
    }
    return Listener(
      key: AppAgentShell.pointerListenerKey,
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        widget.coordinator.pauseForUserActivity(reason: 'pointer_down');
      },
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Positioned.fill(child: routedChild),
          if (_desktopWindowModeController.mode != DesktopWindowMode.pet)
            Positioned.fill(
              child: AgentControlHud(
                coordinator: widget.coordinator,
                agentId: widget.agentId,
                onOrbTap: widget.onOrbTap,
                showOrb: widget.showOrb,
              ),
            ),
        ],
      ),
    );
  }

  void _handleDesktopWindowModeChanged() {
    if (_desktopWindowModeController.isTransitioning) {
      if (mounted) setState(() {});
      return;
    }
    _reconcilePortalLifecycle();
    if (mounted) setState(() {});
  }

  bool _handleHardwareKey(KeyEvent event) {
    if (event is KeyDownEvent || event is KeyRepeatEvent) {
      widget.coordinator.pauseForUserActivity(reason: 'keyboard_input');
    }
    return false;
  }

  void _bindRouteListener() {
    final next =
        widget.routeListenable ??
        (appNavigation.isConfigured
            ? appNavigation.router.routerDelegate
            : null);
    appServices.maybeFind<AvatarCameraDirector>()?.bindRouteListener(
      next,
      currentRoute: _readCurrentRoute,
    );
    if (identical(next, _activeRouteListenable)) {
      _lastRoute ??= _readCurrentRoute();
      return;
    }
    _activeRouteListenable?.removeListener(_handleRouteChange);
    _activeRouteListenable = next;
    _lastRoute = _readCurrentRoute();
    next?.addListener(_handleRouteChange);
    _reconcilePortalLifecycle();
  }

  void _handleRouteChange() {
    final current = _readCurrentRoute();
    if (current == null || current == _lastRoute) return;
    _lastRoute = current;
    _rebuildRouteScope();
    _reconcileCompanionServices();
    _reconcilePortalLifecycle();
    if (!_isCompanionFeedRoute(current)) {
      _companion?.deactivate();
    }

    final snapshot = widget.coordinator.snapshot;
    if (!_isControlling(snapshot.phase) ||
        _matchesExpectedTarget(current, snapshot.targetRoute)) {
      return;
    }
    widget.coordinator.pauseForUserActivity(reason: 'unexpected_route_change');
  }

  void _rebuildRouteScope() {
    if (!mounted) return;
    if (WidgetsBinding.instance.schedulerPhase !=
            SchedulerPhase.persistentCallbacks &&
        WidgetsBinding.instance.buildOwner?.debugBuilding != true) {
      setState(() {});
      return;
    }
    if (_routeScopeRebuildScheduled) return;
    _routeScopeRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _routeScopeRebuildScheduled = false;
      if (mounted) setState(() {});
    });
  }

  String? _readCurrentRoute() {
    try {
      final current =
          widget.currentRoute?.call() ??
          (appNavigation.isConfigured ? appNavigation.currentRoute : null);
      final normalized = current?.trim();
      return normalized == null || normalized.isEmpty ? null : normalized;
    } catch (_) {
      return null;
    }
  }

  void _reconcileCompanionServices() {
    _bindAccountLifecycle();
    _bindDesktopCompanionPreferences();
    _bindDesktopAvatarSelection();
    _ensureDevicePortal();
    final storageScopes = appServices.maybeFind<AccountStorageScopeService>();
    final accountBoundary = storageScopes == null
        ? appServices.maybeFind<DBService>()
        : storageScopes.activeMount;
    if (!identical(accountBoundary, _desktopAccountBoundary)) {
      _cancelDesktopAvatarPreparation();
      _desktopAccountBoundary = accountBoundary;
      _desktopShellKey = GlobalKey();
    }
    // Shared voice input and local presentation belong to the mounted account.
    // Their execution paths validate authority independently of this scope.
    final accountMounted = _accountLifecycle?.isMounted ?? true;
    if (!accountMounted || _isSceneRoute(_readCurrentRoute())) {
      _cancelDesktopAvatarPreparation();
    }
    final avatarVisible =
        _avatarMayAppear &&
        (!_usesNativeDesktopPetHost ||
            _desktopAvatarConfig == null ||
            _desktopAvatarConfig!.selectionDisplayCurrent);
    // Home owns its local model entry and view preference. Signed-out/retiring
    // accounts and every other route keep the account visibility boundary.
    final currentRoute = _readCurrentRoute();
    final homeOwnsPresentation =
        EmbeddedAvatarPresentationPolicy.shouldEmbed() &&
        _isHomeRoute(currentRoute) &&
        accountMounted;
    final spaceOwnsPresentation = _isWorldRoute(currentRoute) && accountMounted;
    final avatar = _portalAvatarRuntime;
    if (homeOwnsPresentation || spaceOwnsPresentation) {
      // Home and Agent Space own their display lifetimes and saved preference.
      // Reapply the mounted-account boundary when another route takes over.
      _localAvatarVisible = null;
      _appliedLocalAvatarVisible = null;
    } else if (avatar != null &&
        (!identical(avatar, _localVisibilityRuntime) ||
            _localAvatarVisible != avatarVisible)) {
      _localVisibilityRuntime = avatar;
      _localAvatarVisible = avatarVisible;
      // Cache the desired state before Unity prepares a personal-space view.
      // The renderer reapplies it on model replacement and world return.
      if (!_usesNativeDesktopPetHost) {
        unawaited(
          avatar.setLocalAvatarVisible(avatarVisible).catchError((Object _) {
            if (identical(avatar, _localVisibilityRuntime)) {
              _localAvatarVisible = null;
            }
          }),
        );
      } else {
        final renderer = avatar.current;
        final modelEpoch = renderer?.modelLoadEpoch;
        final lifecycle = _accountLifecycle;
        final generation = lifecycle?.generation;
        final boundary = _desktopAccountBoundary;
        _appliedLocalAvatarVisible = null;
        _localVisibilityWrite = _localVisibilityWrite
            .then((_) async {
              if (!mounted ||
                  !identical(avatar, _localVisibilityRuntime) ||
                  _localAvatarVisible != avatarVisible ||
                  !identical(renderer, avatar.current) ||
                  renderer?.modelLoadEpoch != modelEpoch ||
                  !identical(lifecycle, _accountLifecycle) ||
                  lifecycle?.generation != generation ||
                  !identical(boundary, _desktopAccountBoundary) ||
                  (avatarVisible &&
                      (!_avatarMayAppear ||
                          (_usesNativeDesktopPetHost &&
                              _desktopAvatarConfig != null &&
                              !_desktopAvatarConfig!
                                  .selectionDisplayCurrent)))) {
                return;
              }
              await avatar.setLocalAvatarVisible(avatarVisible);
              if (!mounted ||
                  _localAvatarVisible != avatarVisible ||
                  !identical(avatar, _localVisibilityRuntime) ||
                  !identical(renderer, avatar.current) ||
                  renderer?.modelLoadEpoch != modelEpoch ||
                  !identical(boundary, _desktopAccountBoundary) ||
                  !identical(lifecycle, _accountLifecycle) ||
                  lifecycle?.generation != generation ||
                  (avatarVisible && !_avatarMayAppear)) {
                return;
              }
              _appliedLocalAvatarVisible = avatarVisible;
              _rebuildRouteScope();
            })
            .catchError((Object _) {
              if (identical(avatar, _localVisibilityRuntime)) {
                _localAvatarVisible = null;
                _appliedLocalAvatarVisible = null;
              }
            });
      }
    }
    final database = accountMounted ? appServices.maybeFind<DBService>() : null;
    final runtimeRegistry = accountMounted
        ? appServices.maybeFind<AgentRuntimeRegistry>()
        : null;
    final voiceBoundary = appServices
        .maybeFind<CompanionVoiceSessionBoundary>();
    if (identical(database, _companionDatabase) &&
        identical(runtimeRegistry, _companionRuntimeRegistry)) {
      final companion = _companion;
      if (companion != null) voiceBoundary?.attach(companion);
      return;
    }

    final previous = _companion;
    _companion = null;
    _companionDatabase = database;
    _companionRuntimeRegistry = runtimeRegistry;
    if (previous != null) {
      unawaited(_retireCompanionController(previous, voiceBoundary));
    }
    if (!_avatarMayAppear) {
      _enqueuePortalLifecycle((portal) => portal.release());
    }

    if (database == null || runtimeRegistry == null) return;
    final companion = CompanionVoiceSessionController(
      database: database,
      runtimeRegistry: runtimeRegistry,
    );
    _companion = companion;
    voiceBoundary?.attach(companion);
  }

  void _bindAccountLifecycle() {
    final next = appServices.maybeFind<AccountSessionLifecycleService>();
    if (identical(next, _accountLifecycle)) return;
    _accountLifecycle?.removeListener(_handleAccountLifecycleChanged);
    _accountLifecycle = next;
    next?.addListener(_handleAccountLifecycleChanged);
    _syncApplicationPresence();
    _logAccountAvatarAuthority();
  }

  void _syncApplicationPresence([AppLifecycleState? state]) {
    final current = state ?? WidgetsBinding.instance.lifecycleState;
    // Closing or unfocusing the chat window keeps the independent desktop
    // pet alive. A suspended phone, however, must not compete for ownership.
    final foreground = _desktopWindowModeController.supportsIndependentPetWindow
        ? current != AppLifecycleState.detached
        : current == null || current == AppLifecycleState.resumed;
    _accountLifecycle?.updateApplicationPresence(
      foreground: foreground,
      handoffInProgress: _handoff?.isBusy ?? false,
    );
  }

  void _handleAccountLifecycleChanged() {
    // Execution changes retire voice authority while mounted companions keep
    // their local avatar. Account retirement still hides the native pet.
    _reconcileCompanionServices();
    _logAccountAvatarAuthority();
    _reconcilePortalLifecycle();
    if (mounted) setState(() {});
  }

  void _logAccountAvatarAuthority() {
    final lifecycle = _accountLifecycle;
    if (lifecycle == null) return;
    debugPrint(
      '[AvatarPresence] phase=${lifecycle.phase.value.name} '
      'mode=${lifecycle.effectiveAuthorityMode.name} '
      'exclusiveDevice=${lifecycle.usesExclusiveDeviceLease} '
      'mounted=${lifecycle.isMounted} '
      'canExecute=${lifecycle.canExecuteAgent}',
    );
  }

  void _ensureDevicePortal() {
    if (_portal != null) return;
    final avatarRuntime = appServices.maybeFind<ActiveAvatarRuntime>();
    if (avatarRuntime == null) return;
    final gateway = AvatarPortalChannelGateway();
    _portalGateway = gateway;
    _portalAvatarRuntime = avatarRuntime;
    _portal = AvatarPortalCoordinator(
      avatarRuntime: avatarRuntime,
      gateway: gateway,
    );
  }

  void _bindDesktopCompanionPreferences() {
    final next = _usesMacOSDesktopAvatarPortal
        ? appServices.maybeFind<DesktopCompanionPreferencesService>()
        : null;
    if (identical(next, _desktopCompanionPreferences)) return;
    unawaited(_desktopCompanionPreferencesSubscription?.cancel());
    _desktopCompanionPreferences = next;
    _desktopCompanionPreferencesSubscription = next?.changes.listen((_) {
      _reconcilePortalLifecycle();
    });
  }

  void _bindDesktopAvatarSelection() {
    if (!_usesNativeDesktopPetHost) return;
    final next = _usesNativeDesktopPetHost
        ? appServices.maybeFind<AvatarConfigService>()
        : null;
    final renderer = appServices.maybeFind<ActiveAvatarRuntime>()?.current;
    if (identical(next, _desktopAvatarConfig) &&
        identical(renderer, _desktopSelectionRenderer)) {
      return;
    }
    _cancelDesktopAvatarPreparation();
    for (final worker in _desktopAvatarSelectionWorkers) {
      worker.dispose();
    }
    _desktopAvatarSelectionWorkers.clear();
    _desktopAvatarConfig = next;
    _desktopSelectionRenderer = renderer;
    _localAvatarVisible = null;
    _appliedLocalAvatarVisible = null;
    if (next == null) return;
    _desktopAvatarSelectionWorkers.addAll([
      next.selectionDisplayReady.listen(
        (_) => _handleDesktopAvatarSelectionChanged(),
      ),
      next.selectionDisplayGeneration.listen(
        (_) => _handleDesktopAvatarSelectionChanged(),
      ),
      if (renderer != null)
        renderer.isReady.listen((ready) {
          if (!ready) _cancelDesktopAvatarPreparation();
          _handleDesktopAvatarSelectionChanged();
          if (ready &&
              _desktopAvatarPreparation == null &&
              _avatarMayAppear &&
              !_isSceneRoute(_readCurrentRoute())) {
            unawaited(
              next
                  .ensureSelectedDisplayReady()
                  .then((_) {
                    if (mounted && identical(next, _desktopAvatarConfig)) {
                      _handleDesktopAvatarSelectionChanged();
                      _reconcilePortalLifecycle();
                    }
                  })
                  .catchError((Object _) {}),
            );
          }
        }),
    ]);
  }

  void _handleDesktopAvatarSelectionChanged() {
    if (!mounted) return;
    // AvatarConfig owns loading hides. The desktop renderer owner must take
    // visibility back only after the selected model's ready/hide receipts.
    _localAvatarVisible = null;
    _appliedLocalAvatarVisible = null;
    _reconcileCompanionServices();
    _rebuildRouteScope();
  }

  void _disposeCompanionController() {
    final companion = _companion;
    _companion = null;
    _companionDatabase = null;
    _companionRuntimeRegistry = null;
    if (companion != null) {
      unawaited(
        _retireCompanionController(
          companion,
          appServices.maybeFind<CompanionVoiceSessionBoundary>(),
        ),
      );
    }
  }

  Future<void> _retireCompanionController(
    CompanionVoiceSessionController companion,
    CompanionVoiceSessionBoundary? boundary,
  ) async {
    try {
      await companion.deactivateAndDrain();
    } catch (error, stackTrace) {
      debugPrint('[CompanionVoice] Controller drain failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    } finally {
      boundary?.detach(companion);
      companion.dispose();
    }
  }

  void _enqueuePortalLifecycle(
    Future<void> Function(AvatarPortalCoordinator portal) operation,
  ) {
    final portal = _portal;
    if (portal == null) return;
    _portalLifecycleQueue = _portalLifecycleQueue
        .then<void>((_) async {
          if (!identical(portal, _portal)) return;
          await operation(portal);
        })
        .catchError((Object _, StackTrace _) {});
  }

  void _reconcilePortalLifecycle() {
    _enqueuePortalLifecycle((portal) async {
      if (_shouldKeepPortalResident()) {
        await _resumePortalAfterLifecycleChange(portal);
      } else {
        await portal.release();
      }
    });
  }

  Future<void> _prepareDesktopPetPresentation() {
    if (!_usesMacOSDesktopAvatarPortal) {
      return _prepareDesktopAvatarRuntime();
    }
    final portal = _portal;
    if (portal == null) {
      return Future<void>.error(
        StateError('The desktop Avatar portal is unavailable.'),
      );
    }
    final result = _portalLifecycleQueue.then<void>((_) async {
      if (!identical(portal, _portal)) {
        throw StateError('The desktop Avatar portal was replaced.');
      }
      await _prepareDesktopAvatarRuntime();
      await _ensurePortalPresentation(portal);
    });
    _portalLifecycleQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> _prepareDesktopAvatarRuntime() {
    final pending = _desktopAvatarPreparation;
    if (pending != null) return pending;
    final config = appServices.maybeFind<AvatarConfigService>();
    if (config == null) {
      return Future<void>.error(
        StateError('The desktop Avatar configuration is unavailable.'),
      );
    }
    final cancellation = Completer<void>();
    _desktopPreparationCancellation = cancellation;
    final boundary = _desktopAccountBoundary;
    final lifecycle = _accountLifecycle;
    final generation = lifecycle?.generation;
    bool current() =>
        mounted &&
        !cancellation.isCompleted &&
        _avatarMayAppear &&
        identical(config, _desktopAvatarConfig) &&
        identical(boundary, _desktopAccountBoundary) &&
        identical(lifecycle, _accountLifecycle) &&
        lifecycle?.generation == generation;
    final preparation = (() async {
      await config.applyInitial();
      if (!current()) throw StateError('Desktop Avatar preparation retired.');
      if (!config.selectionDisplayCurrent) {
        final ready = Completer<void>();
        final worker = config.selectionDisplayReady.listen((value) {
          if (value && config.selectionDisplayCurrent && !ready.isCompleted) {
            ready.complete();
          }
        });
        final timeout = Timer(const Duration(seconds: 22), () {
          if (!ready.isCompleted) {
            ready.completeError(
              TimeoutException(
                'Desktop Avatar selection did not become ready.',
              ),
            );
          }
        });
        cancellation.future.then((_) {
          if (!ready.isCompleted) {
            ready.completeError(
              StateError('Desktop Avatar preparation retired.'),
            );
          }
        });
        try {
          await ready.future;
        } finally {
          worker.dispose();
          timeout.cancel();
        }
      }
      if (!current()) throw StateError('Desktop Avatar preparation retired.');
      if (!mounted ||
          !_avatarMayAppear ||
          !identical(config, _desktopAvatarConfig) ||
          _isSceneRoute(_readCurrentRoute())) {
        return;
      }
      if (_appliedLocalAvatarVisible != true) _localAvatarVisible = null;
      _reconcileCompanionServices();
      await _localVisibilityWrite;
      if (!current()) throw StateError('Desktop Avatar preparation retired.');
      if (_appliedLocalAvatarVisible != true) {
        throw StateError('The selected desktop Avatar has not been revealed.');
      }
    })();
    final operation = Future.any<void>([
      preparation,
      cancellation.future.then(
        (_) => throw StateError('Desktop Avatar preparation retired.'),
      ),
    ]);
    _desktopAvatarPreparation = operation;
    void clearPending() {
      if (identical(_desktopAvatarPreparation, operation)) {
        _desktopAvatarPreparation = null;
        if (identical(_desktopPreparationCancellation, cancellation)) {
          _desktopPreparationCancellation = null;
        }
      }
    }

    operation.then<void>(
      (_) => clearPending(),
      onError: (Object _, StackTrace _) => clearPending(),
    );
    return operation;
  }

  void _cancelDesktopAvatarPreparation() {
    final cancellation = _desktopPreparationCancellation;
    _desktopPreparationCancellation = null;
    _desktopAvatarPreparation = null;
    if (cancellation != null && !cancellation.isCompleted) {
      cancellation.complete();
    }
  }

  Future<void> _resumePortalAfterLifecycleChange(
    AvatarPortalCoordinator portal,
  ) async {
    if (!_shouldKeepPortalResident()) return;
    if (portal.capturesWorld &&
        _desktopWindowModeController.mode != DesktopWindowMode.pet &&
        _isSceneRoute(_lastRoute)) {
      await portal.resume();
      return;
    }
    await _ensurePortalPresentation(portal);
  }

  Future<void> _ensurePortalPresentation(AvatarPortalCoordinator portal) async {
    // World and the authenticated Login doorway own scene capture, including
    // while its first frame is pending. Pet preparation must not supersede it.
    if (!mounted ||
        !_avatarMayAppear ||
        !identical(portal, _portal) ||
        _isSceneRoute(_readCurrentRoute())) {
      return;
    }
    if (portal.capturesWorld) {
      final lifecycle = _accountLifecycle;
      final generation = lifecycle?.generation;
      final accountBoundary = _desktopAccountBoundary;
      final renderer = _portalAvatarRuntime?.current;
      // Join the existing exit operation through camera restoration, renderer
      // leave and Home presentation restoration before requesting pet capture.
      await appServices.maybeFind<AgentSpaceController>()?.leave();
      if (!mounted ||
          !_avatarMayAppear ||
          !identical(portal, _portal) ||
          _isSceneRoute(_readCurrentRoute()) ||
          !identical(lifecycle, _accountLifecycle) ||
          lifecycle?.generation != generation ||
          !identical(accountBoundary, _desktopAccountBoundary) ||
          !identical(renderer, _portalAvatarRuntime?.current)) {
        return;
      }
    }
    // A texture can arrive while every selected-model renderer is hidden.
    // Model readiness and the local reveal receipt precede avatar-only capture.
    await _prepareDesktopAvatarRuntime();
    if (!mounted ||
        !_avatarMayAppear ||
        !identical(portal, _portal) ||
        _isSceneRoute(_readCurrentRoute())) {
      return;
    }
    final presentation =
        _desktopCompanionPreferences?.config ??
        DesktopCompanionPresentationConfigV1.defaults;
    final profile = _profileForPresentation(presentation);
    final targetFps = presentation.targetFps;
    final hasActiveLease =
        portal.phase == AvatarPortalPhase.visible ||
        portal.phase == AvatarPortalPhase.suspended;
    if (hasActiveLease &&
        !portal.usesCaptureConfiguration(
          profile: profile,
          targetFps: targetFps,
        )) {
      await portal.summon(profile: profile, targetFps: targetFps);
      return;
    }
    if (portal.phase == AvatarPortalPhase.suspended) {
      await portal.resume();
      return;
    }
    if (portal.phase != AvatarPortalPhase.visible) {
      await portal.summon(profile: profile, targetFps: targetFps);
    }
  }

  AvatarPortalProfile _profileForPresentation(
    DesktopCompanionPresentationConfigV1 presentation,
  ) {
    if (!_usesMacOSDesktopAvatarPortal) {
      return AvatarPortalProfile.compactHigh;
    }
    return switch (presentation.quality) {
      DesktopCompanionRenderQuality.eco => AvatarPortalProfile.compactLow,
      DesktopCompanionRenderQuality.balanced => AvatarPortalProfile.compactHigh,
      DesktopCompanionRenderQuality.crisp => AvatarPortalProfile.desktopHigh,
    };
  }

  bool get _avatarMayAppear => _accountLifecycle?.isMounted ?? true;

  bool _shouldKeepPortalResident() =>
      _usesMacOSDesktopAvatarPortal &&
      _avatarMayAppear &&
      (_desktopWindowModeController.petVisible ||
          _isHomeRoute(_lastRoute) ||
          _isSceneRoute(_lastRoute));

  void _handleHandoffChanged() {
    if (!mounted) return;
    _syncApplicationPresence();
  }

  Future<void> _closePortalSession() async {
    final portal = _portal;
    _portal = null;
    _portalAvatarRuntime = null;
    final gateway = _portalGateway;
    _portalGateway = null;
    await portal?.close();
    await gateway?.close();
  }

  static bool _isCompanionFeedRoute(String? route) {
    final path = Uri.tryParse(route ?? '')?.path;
    return path == '/game-feed' || path == '/agent-media';
  }

  static bool _isWorldRoute(String? route) =>
      Uri.tryParse(route ?? '')?.path == AppRouteCatalog.agentSpace;

  bool _isSceneRoute(String? route) =>
      _isWorldRoute(route) ||
      (Uri.tryParse(route ?? '')?.path == AppRouteCatalog.login &&
          _accountLifecycle?.isMounted == true);

  static bool _isHomeRoute(String? route) =>
      Uri.tryParse(route ?? '')?.path == AppRouteCatalog.home;

  static bool get _usesMacOSDesktopAvatarPortal =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static bool get _usesNativeDesktopPetHost =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS ||
          defaultTargetPlatform == TargetPlatform.windows);

  static bool _isControlling(AgentUiControlPhase phase) =>
      phase == AgentUiControlPhase.awaitingConsent ||
      phase == AgentUiControlPhase.navigating ||
      phase == AgentUiControlPhase.operating;

  static bool _matchesExpectedTarget(String current, String? target) {
    final normalizedTarget = target?.trim();
    if (normalizedTarget == null || normalizedTarget.isEmpty) return false;
    final currentUri = Uri.tryParse(current);
    final targetUri = Uri.tryParse(normalizedTarget);
    if (currentUri == null || targetUri == null) {
      return current == normalizedTarget;
    }
    return currentUri.path.isNotEmpty && currentUri.path == targetUri.path;
  }
}

/// Observes platform back before delegating to the app router unchanged.
class AppAgentTakeoverBackButtonDispatcher extends RootBackButtonDispatcher {
  AgentUiControlCoordinator? _coordinator;

  void bind(AgentUiControlCoordinator? coordinator) {
    _coordinator = coordinator;
  }

  @override
  Future<bool> didPopRoute() {
    _coordinator?.pauseForUserActivity(reason: 'system_back');
    return super.didPopRoute();
  }
}

final appAgentTakeoverBackButtonDispatcher =
    AppAgentTakeoverBackButtonDispatcher();

Object? _takeoverRouterConfigSource;
Object? _takeoverRouterConfig;

/// Reuses every router delegate while replacing only its platform-back seam.
RouterConfig<T> appAgentTakeoverRouterConfig<T>(RouterConfig<T> source) {
  if (!identical(source, _takeoverRouterConfigSource)) {
    _takeoverRouterConfigSource = source;
    _takeoverRouterConfig = RouterConfig<T>(
      routeInformationProvider: source.routeInformationProvider,
      routeInformationParser: source.routeInformationParser,
      routerDelegate: source.routerDelegate,
      backButtonDispatcher: appAgentTakeoverBackButtonDispatcher,
    );
  }
  return _takeoverRouterConfig! as RouterConfig<T>;
}

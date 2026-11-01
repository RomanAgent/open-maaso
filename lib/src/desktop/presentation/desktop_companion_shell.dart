import 'dart:async';
import 'package:flutter/material.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/gaze_director.dart';
import 'package:maaso/src/desktop/application/avatar_interaction_coordinator.dart';
import 'package:maaso/src/desktop/application/companion_menu_catalog.dart';
import 'package:maaso/src/desktop/application/desktop_avatar_interaction.dart';
import 'package:maaso/src/desktop/application/desktop_companion_host_gateway.dart';
import 'package:maaso/src/desktop/application/desktop_companion_preferences_service.dart';
import 'package:maaso/src/desktop/application/desktop_companion_tray_controller.dart';
import 'package:maaso/src/desktop/application/desktop_window_mode_controller.dart';
import 'package:maaso/src/desktop/infrastructure/desktop_companion_host_gateway_factory.dart';
import 'package:maaso/src/desktop/infrastructure/desktop_companion_tray_controller_factory.dart';
import 'package:maaso/src/desktop/presentation/desktop_pet_stage.dart';
import 'package:maaso/src/desktop/presentation/desktop_pet_presentation_scope.dart';
import 'package:maaso/src/features/agent/application/companion/agent_reply_presentation_service.dart';

class DesktopCompanionShell extends StatefulWidget {
  const DesktopCompanionShell({
    required this.windowController,
    required this.child,
    this.autoEnterPetMode = true,
    this.canAutoEnterPetMode,
    this.keepAppWindowWithPet = false,
    this.petAvailable = true,
    this.onDestinationSelected,
    this.routeListenable,
    this.currentRoute,
    this.hostGateway,
    this.presentationPreferences,
    this.replyPresentation,
    this.avatarInteractionCoordinator,
    this.preparePetPresentation,
    this.petPresentationListenable,
    this.isPetPresentationFailed,
    this.isPetPresentationReady,
    this.isScenePresentation,
    super.key,
  });

  final DesktopWindowModeController windowController;
  final Widget child;
  final bool autoEnterPetMode;

  /// Rechecked after asynchronous preparation, independently of widget rebuilds.
  final bool Function(String route)? canAutoEnterPetMode;

  /// macOS keeps the conversation window independent of the desktop avatar.
  final bool keepAppWindowWithPet;
  final bool petAvailable;
  final FutureOr<void> Function(CompanionMenuEntry entry)?
  onDestinationSelected;
  final Listenable? routeListenable;
  final String Function()? currentRoute;
  final DesktopCompanionHostGateway? hostGateway;
  final DesktopCompanionPreferencesService? presentationPreferences;
  final AgentReplyPresentationService? replyPresentation;
  final AvatarInteractionCoordinator? avatarInteractionCoordinator;
  final Future<void> Function()? preparePetPresentation;
  final Listenable? petPresentationListenable;
  final bool Function()? isPetPresentationFailed;
  final bool Function()? isPetPresentationReady;
  final bool Function()? isScenePresentation;

  @override
  State<DesktopCompanionShell> createState() => _DesktopCompanionShellState();
}

class _DesktopCompanionShellState extends State<DesktopCompanionShell> {
  Listenable? _routeListenable;
  bool _autoTransitionRequested = false;
  bool _automaticPetModeActive = false;
  bool _loginTransitionRequested = false;
  bool _authenticationWindowTransitionRequested = false;
  bool _worldTransitionRequested = false;
  bool _worldNavigationPending = false;
  bool _petExplicitlyHidden = false;
  bool _petPresentationRecoveryRequested = false;
  bool _lastPetPresentationReady = false;
  late DesktopCompanionTrayController _trayController;
  late DesktopCompanionHostGateway _hostGateway;
  AvatarInteractionCoordinator? _avatarInteractionCoordinator;
  StreamSubscription<DesktopCompanionPresentationConfigV1>?
  _presentationSubscription;
  DesktopCompanionPresentationConfigV1 _presentationConfig =
      DesktopCompanionPresentationConfigV1.defaults;
  StreamSubscription<AgentReplyPresentationSnapshot>? _replySubscription;
  Future<void> _hostLifecycleQueue = Future<void>.value();
  Timer? _bubbleDebounce;
  bool _bubbleRenderPending = false;
  AgentReplyPresentationSnapshot _replySnapshot =
      const AgentReplyPresentationSnapshot.empty();
  bool _hostInitialized = false;
  Future<void>? _hostInitializationOperation;
  Future<void>? _petModeTransitionOperation;
  bool _nativePetVisible = false;
  final _petPresentation = ValueNotifier<DesktopPetPresentationState>(
    DesktopPetPresentationState.hidden,
  );
  bool get _nativePetShown => _nativePetVisible;
  set _nativePetShown(bool value) {
    _nativePetVisible = value;
    if (!mounted) return;
    _petPresentation.value = value
        ? DesktopPetPresentationState.visible
        : _petPresentation.value == DesktopPetPresentationState.unavailable
        ? DesktopPetPresentationState.unavailable
        : DesktopPetPresentationState.hidden;
  }

  bool? _pendingNativePetVisibility;
  Future<void>? _pendingNativePetOperation;
  int _nativePetRequestGeneration = 0;

  @override
  void initState() {
    super.initState();
    widget.windowController.addListener(_handleWindowModeChanged);
    widget.petPresentationListenable?.addListener(
      _handlePetPresentationChanged,
    );
    _hostGateway = widget.hostGateway ?? createDesktopCompanionHostGateway();
    _avatarInteractionCoordinator = widget.avatarInteractionCoordinator;
    _trayController = createDesktopCompanionTrayController(
      widget.windowController,
      canShowPet: _canShowPetFromTray,
      requestShowPet: _requestPetModeFromTray,
    );
    _bindPresentationPreferences();
    unawaited(
      _trayController.initialize().catchError((Object _, StackTrace _) {}),
    );
    _bindReplyPresentation();
    unawaited(_initializeHost().catchError((Object _, StackTrace _) {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _bindRouteListenable();
      _maybeEnterInitialPetMode();
      _reconcileNativePet();
    });
  }

  @override
  void didUpdateWidget(covariant DesktopCompanionShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(
      oldWidget.petPresentationListenable,
      widget.petPresentationListenable,
    )) {
      oldWidget.petPresentationListenable?.removeListener(
        _handlePetPresentationChanged,
      );
      widget.petPresentationListenable?.addListener(
        _handlePetPresentationChanged,
      );
      _autoTransitionRequested = false;
      _handlePetPresentationChanged();
      _maybeEnterInitialPetMode();
    }
    if (!identical(oldWidget.routeListenable, widget.routeListenable)) {
      _bindRouteListenable();
      _maybeEnterInitialPetMode();
    }
    if (!identical(oldWidget.replyPresentation, widget.replyPresentation)) {
      _bindReplyPresentation();
    }
    if (!identical(
      oldWidget.presentationPreferences,
      widget.presentationPreferences,
    )) {
      _bindPresentationPreferences();
    }
    if (!identical(
      oldWidget.avatarInteractionCoordinator,
      widget.avatarInteractionCoordinator,
    )) {
      _avatarInteractionCoordinator?.deactivate();
      _avatarInteractionCoordinator = widget.avatarInteractionCoordinator;
      if (_nativePetShown &&
          _pendingNativePetVisibility == null &&
          _canHandleAvatarInteraction()) {
        _interactionCoordinator.activateGeneration(_nativePetRequestGeneration);
      }
    }
    if (!identical(oldWidget.hostGateway, widget.hostGateway)) {
      final previousHost = _hostGateway;
      _avatarInteractionCoordinator?.deactivate();
      _hostGateway = widget.hostGateway ?? createDesktopCompanionHostGateway();
      _petModeTransitionOperation = null;
      _autoTransitionRequested = false;
      _automaticPetModeActive = false;
      _hostInitialized = false;
      _hostInitializationOperation = null;
      _nativePetShown = false;
      _pendingNativePetVisibility = null;
      _pendingNativePetOperation = null;
      _nextNativePetRequestGeneration();
      unawaited(previousHost.dispose().catchError((Object _, StackTrace _) {}));
      unawaited(_initializeHost().catchError((Object _, StackTrace _) {}));
      _maybeEnterInitialPetMode();
    }
    if (!identical(oldWidget.windowController, widget.windowController)) {
      oldWidget.windowController.removeListener(_handleWindowModeChanged);
      widget.windowController.addListener(_handleWindowModeChanged);
      _petExplicitlyHidden = false;
      unawaited(_trayController.dispose());
      _trayController = createDesktopCompanionTrayController(
        widget.windowController,
        canShowPet: _canShowPetFromTray,
        requestShowPet: _requestPetModeFromTray,
      );
      unawaited(
        _trayController.initialize().catchError((Object _, StackTrace _) {}),
      );
      _autoTransitionRequested = false;
      _maybeEnterInitialPetMode();
    }
    if (oldWidget.petAvailable != widget.petAvailable) {
      _autoTransitionRequested = false;
      _maybeEnterInitialPetMode();
    }
    if (oldWidget.autoEnterPetMode != widget.autoEnterPetMode ||
        _automaticPetModeCancelled) {
      _maybeEnterInitialPetMode();
    }
    _handlePetPresentationChanged();
  }

  @override
  void dispose() {
    _bubbleDebounce?.cancel();
    _avatarInteractionCoordinator?.deactivate();
    unawaited(_presentationSubscription?.cancel());
    unawaited(_replySubscription?.cancel());
    _routeListenable?.removeListener(_handleRouteChanged);
    widget.petPresentationListenable?.removeListener(
      _handlePetPresentationChanged,
    );
    widget.windowController.removeListener(_handleWindowModeChanged);
    appServices.maybeFind<GazeDirector>()?.setDesktopPointerGaze(null);
    unawaited(_trayController.dispose());
    unawaited(_hostGateway.dispose().catchError((Object _, StackTrace _) {}));
    _petPresentation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.windowController.supportsIndependentPetWindow) {
      return widget.child;
    }
    if (widget.windowController.mode != DesktopWindowMode.pet) {
      return widget.child;
    }
    return Overlay(
      initialEntries: <OverlayEntry>[
        OverlayEntry(
          builder: (_) => DesktopPetStage(
            windowController: widget.windowController,
            onDestinationSelected: (entry) =>
                unawaited(_selectDestination(entry)),
          ),
        ),
      ],
    );
  }

  Future<void> _initializeHost() {
    if (!_hostGateway.isSupported || _hostInitialized) {
      return Future<void>.value();
    }
    final pending = _hostInitializationOperation;
    if (pending != null) return pending;
    final gateway = _hostGateway;
    final operation = _performHostInitialization(gateway);
    _hostInitializationOperation = operation;
    operation.then<void>(
      (_) {
        if (identical(_hostInitializationOperation, operation)) {
          _hostInitializationOperation = null;
        }
      },
      onError: (Object _, StackTrace _) {
        if (identical(gateway, _hostGateway)) _hostInitialized = false;
        if (identical(_hostInitializationOperation, operation)) {
          _hostInitializationOperation = null;
        }
      },
    );
    return operation;
  }

  Future<void> _performHostInitialization(
    DesktopCompanionHostGateway gateway,
  ) async {
    await _enqueueHostLifecycle(() async {
      if (!identical(gateway, _hostGateway)) return;
      await gateway.initialize(
        onMenuSelected: _selectDestinationById,
        onCommand: _handleHostCommand,
        onGazeChanged: _handleGazeChanged,
        onInteraction: _handleAvatarInteraction,
      );
      await gateway.configurePresentation(_presentationConfig);
      await gateway.configureMenu(
        CompanionMenuCatalog.preferredEntries
            .map(
              (entry) => DesktopCompanionHostMenuItem(
                id: entry.destination.id,
                label: entry.labelKey.isEmpty
                    ? entry.destination.title
                    : entry.labelKey.tr,
              ),
            )
            .toList(growable: false),
      );
      if (identical(gateway, _hostGateway)) _hostInitialized = true;
    });
    if (!mounted || !identical(gateway, _hostGateway)) return;
    _reconcileNativePet();
  }

  void _bindPresentationPreferences() {
    unawaited(_presentationSubscription?.cancel());
    final preferences =
        widget.presentationPreferences ??
        appServices.maybeFind<DesktopCompanionPreferencesService>();
    _presentationConfig =
        preferences?.config ?? DesktopCompanionPresentationConfigV1.defaults;
    _presentationSubscription = preferences?.changes.listen(
      _handlePresentationConfigChanged,
    );
  }

  void _handlePresentationConfigChanged(
    DesktopCompanionPresentationConfigV1 config,
  ) {
    _presentationConfig = config;
    final gateway = _hostGateway;
    if (!gateway.isSupported) return;
    unawaited(
      _enqueueHostLifecycle(() {
        if (!mounted ||
            !identical(gateway, _hostGateway) ||
            !_hostInitialized) {
          return Future<void>.value();
        }
        return gateway.configurePresentation(config);
      }).catchError((Object _, StackTrace _) {}),
    );
  }

  void _bindReplyPresentation() {
    unawaited(_replySubscription?.cancel());
    final presentation = widget.replyPresentation;
    _replySnapshot =
        presentation?.snapshot ?? const AgentReplyPresentationSnapshot.empty();
    _replySubscription = presentation?.changes.listen((snapshot) {
      _replySnapshot = snapshot;
      _scheduleBubbleRender();
    });
    _scheduleBubbleRender();
  }

  void _scheduleBubbleRender() {
    if (_bubbleDebounce?.isActive == true) {
      _bubbleRenderPending = true;
      return;
    }
    _renderNativeBubble();
    _bubbleDebounce = Timer(const Duration(milliseconds: 40), () {
      _bubbleDebounce = null;
      if (!_bubbleRenderPending) return;
      _bubbleRenderPending = false;
      _scheduleBubbleRender();
    });
  }

  void _renderNativeBubble() {
    if (!mounted || !_nativePetShown || !_hostInitialized) return;
    final text = _replySnapshot.text.trim();
    unawaited(
      _enqueueHostLifecycle(() {
        if (!_nativePetShown) return Future<void>.value();
        return text.isEmpty
            ? _hostGateway.clearBubble()
            : _hostGateway.showBubble(text);
      }).catchError((Object _, StackTrace _) {}),
    );
  }

  void _bindRouteListenable() {
    final next =
        widget.routeListenable ??
        (appNavigation.isConfigured
            ? (widget.windowController.supportsIndependentPetWindow
                  ? appNavigation.router.routerDelegate
                  : appNavigation.router.routeInformationProvider)
            : null);
    if (identical(next, _routeListenable)) return;
    _routeListenable?.removeListener(_handleRouteChanged);
    _routeListenable = next;
    next?.addListener(_handleRouteChanged);
  }

  void _handleRouteChanged() => _maybeEnterInitialPetMode();

  bool get _allowsAutomaticPetMode {
    if (!widget.autoEnterPetMode) return false;
    return widget.canAutoEnterPetMode?.call(_currentRoute) ?? true;
  }

  String get _currentRoute =>
      widget.currentRoute?.call() ??
      (appNavigation.isConfigured
          ? (widget.windowController.supportsIndependentPetWindow
                ? appNavigation.currentRoute
                // Legacy pet mode replaces the Router widget, so its delegate
                // cannot resolve new locations until the app window returns.
                : appNavigation.router.routeInformationProvider.value.uri
                      .toString())
          : '');

  bool get _automaticPetModeCancelled =>
      _automaticPetModeActive && !_allowsAutomaticPetMode;

  bool _canShowPetFromTray() {
    if (!widget.petAvailable || _worldNavigationPending) return false;
    final hasRouteSource =
        widget.currentRoute != null ||
        widget.routeListenable != null ||
        appNavigation.isConfigured;
    final route = _currentRoute;
    final path = Uri.tryParse(route)?.path;
    return !hasRouteSource ||
        (path?.isNotEmpty == true &&
            path != AppRouteCatalog.login &&
            path != AppRouteCatalog.accountStandby &&
            path != AppRouteCatalog.agentSpace);
  }

  void _maybeEnterInitialPetMode() {
    final hasRouteSource =
        widget.currentRoute != null ||
        widget.routeListenable != null ||
        appNavigation.isConfigured;
    final route = _currentRoute;
    final path = Uri.tryParse(route)?.path;
    final authenticationRoute = path == AppRouteCatalog.login;
    if (_authenticationWindowTransitionRequested) return;
    if (widget.windowController.mode != DesktopWindowMode.unsupported &&
        widget.windowController.authenticationRoute != authenticationRoute) {
      _authenticationWindowTransitionRequested = true;
      unawaited(_syncAuthenticationWindow(authenticationRoute));
      return;
    }
    final requiresAuthentication =
        !widget.petAvailable ||
        (hasRouteSource && path?.isNotEmpty != true) ||
        path == AppRouteCatalog.login ||
        path == AppRouteCatalog.accountStandby;
    if (requiresAuthentication) {
      _autoTransitionRequested = false;
      _worldTransitionRequested = false;
      if ((widget.windowController.mode == DesktopWindowMode.pet ||
              widget.windowController.petVisible) &&
          !_loginTransitionRequested) {
        _loginTransitionRequested = true;
        unawaited(_enterAppModeForLogin());
        return;
      }
      _reconcileNativePet();
      return;
    }
    _loginTransitionRequested = false;
    if (path == AppRouteCatalog.agentSpace) {
      // Leaving a world must be able to restore the desktop presentation even
      // if a window-close request cleared the previous visible-pet intent.
      _autoTransitionRequested = false;
      // Unsupported hosts cannot change window mode. Treating their no-op
      // reveal as a transition would retry forever from the completion callback.
      if (widget.windowController.mode == DesktopWindowMode.pet &&
          !_worldTransitionRequested) {
        _worldTransitionRequested = true;
        unawaited(_enterAppModeForWorld());
        return;
      }
      _reconcileNativePet();
      return;
    }
    _worldTransitionRequested = false;
    if (!_allowsAutomaticPetMode) {
      // A startup redirect can arrive after automatic pet mode has committed.
      // Restore the app only for that automatic intent; a tray summon remains
      // explicit even when the underlying app route is Home.
      if (_automaticPetModeActive &&
          widget.windowController.mode == DesktopWindowMode.pet) {
        _automaticPetModeActive = false;
        _autoTransitionRequested = false;
        unawaited(_enterAppModeForLogin());
      } else {
        _reconcileNativePet();
      }
      return;
    }
    if (_petPresentation.value == DesktopPetPresentationState.unavailable ||
        _petExplicitlyHidden ||
        _autoTransitionRequested ||
        widget.windowController.isTransitioning ||
        widget.windowController.mode != DesktopWindowMode.app ||
        widget.windowController.petVisible) {
      _reconcileNativePet();
      return;
    }
    _autoTransitionRequested = true;
    unawaited(_requestPetMode(automatic: true));
  }

  Future<void> _requestPetModeFromTray() {
    _petExplicitlyHidden = false;
    _petPresentation.value = _nativePetShown
        ? DesktopPetPresentationState.visible
        : DesktopPetPresentationState.hidden;
    return _requestPetMode();
  }

  Future<void> _requestPetMode({bool automatic = false}) {
    if (!automatic) _automaticPetModeActive = false;
    final pending = _petModeTransitionOperation;
    if (pending != null) return pending;
    _automaticPetModeActive = automatic;
    _autoTransitionRequested = true;
    final operation = _enterInitialPetMode();
    _petModeTransitionOperation = operation;
    operation.whenComplete(() {
      if (identical(_petModeTransitionOperation, operation)) {
        _petModeTransitionOperation = null;
      }
    });
    return operation;
  }

  Future<void> _enterInitialPetMode() async {
    final hostGateway = _hostGateway;
    final windowController = widget.windowController;
    var nativePetPrepared = false;
    try {
      if (widget.windowController.supportsIndependentPetWindow) {
        if (!_hostGateway.isSupported) {
          throw StateError('The desktop companion host is unavailable.');
        }
        final preparations = <Future<void>>[_initializeHost()];
        final preparePetPresentation = widget.preparePetPresentation;
        if (preparePetPresentation != null) {
          preparations.add(preparePetPresentation());
        }
        await Future.wait(preparations);
        if (!mounted ||
            !identical(hostGateway, _hostGateway) ||
            !identical(windowController, widget.windowController)) {
          return;
        }
        if (!mounted || !_hostInitialized) {
          throw StateError('The desktop companion host is not ready.');
        }
        if (!mounted || widget.isPetPresentationFailed?.call() == true) {
          throw StateError('The desktop Avatar presentation is unavailable.');
        }
        if (widget.isPetPresentationReady != null &&
            widget.isPetPresentationReady!.call() != true) {
          throw StateError(
            'The selected desktop Avatar has not been revealed.',
          );
        }
      }
      if (!mounted ||
          _automaticPetModeCancelled ||
          _petExplicitlyHidden ||
          !_canShowPetFromTray() ||
          (!widget.windowController.supportsIndependentPetWindow &&
              widget.windowController.mode != DesktopWindowMode.app) ||
          widget.windowController.petVisible) {
        _autoTransitionRequested = false;
        _automaticPetModeActive = false;
        return;
      }
      if (widget.windowController.supportsIndependentPetWindow) {
        if (widget.isPetPresentationReady != null &&
            widget.isPetPresentationReady!.call() != true) {
          throw StateError('The desktop Avatar reveal is no longer current.');
        }
        await _setNativePetVisibility(true, recoverAppOnShowFailure: false);
        if (!mounted ||
            !identical(hostGateway, _hostGateway) ||
            !identical(windowController, widget.windowController)) {
          return;
        }
        nativePetPrepared = _nativePetShown;
        if (!nativePetPrepared) {
          throw StateError('The desktop Avatar first frame is unavailable.');
        }
      }
      if (_automaticPetModeCancelled) {
        throw StateError('Automatic desktop presentation was cancelled.');
      }
      if (widget.keepAppWindowWithPet) {
        await widget.windowController.showIndependentPet();
      } else {
        await widget.windowController.enterPetMode();
      }
      if (!mounted ||
          !identical(hostGateway, _hostGateway) ||
          !identical(windowController, widget.windowController)) {
        return;
      }
      if (_automaticPetModeCancelled) {
        throw StateError('Automatic desktop presentation was cancelled.');
      }
      if (widget.isPetPresentationFailed?.call() == true) {
        await _recoverFromPetPresentationFailure();
      }
    } catch (_) {
      // A retired native host cannot change its replacement's presentation.
      if (!mounted ||
          !identical(hostGateway, _hostGateway) ||
          !identical(windowController, widget.windowController)) {
        return;
      }
      _autoTransitionRequested = false;
      _automaticPetModeActive = false;
      if (nativePetPrepared || _nativePetShown) {
        await _setNativePetVisibility(false, recoverAppOnShowFailure: false);
      }
      if (widget.windowController.supportsIndependentPetWindow &&
          _canShowPetFromTray() &&
          !_automaticPetModeCancelled) {
        _petPresentation.value = DesktopPetPresentationState.unavailable;
      }
      if (widget.windowController.petVisible) {
        try {
          await widget.windowController.hidePet();
        } catch (_) {}
      }
    }
  }

  Future<void> _enterAppModeForLogin() async {
    var enteredAppMode = false;
    try {
      await _setNativePetVisibility(false, recoverAppOnShowFailure: false);
      await widget.windowController.enterAuthMode();
      enteredAppMode = true;
    } catch (_) {
      // Keep the route authoritative. A later route/window notification can
      // retry after the native window bridge recovers.
    } finally {
      if (mounted) {
        _loginTransitionRequested = false;
        if (enteredAppMode) _maybeEnterInitialPetMode();
      }
    }
  }

  Future<void> _syncAuthenticationWindow(bool active) async {
    var applied = false;
    bool routeStillMatches() =>
        (Uri.tryParse(_currentRoute)?.path == AppRouteCatalog.login) == active;
    try {
      if (active) {
        await _setNativePetVisibility(false, recoverAppOnShowFailure: false);
      }
      // Native preparation may outlive a login redirect or account switch.
      // Recheck before queueing a resize, then reconcile again after it settles.
      if (!mounted || !routeStillMatches()) return;
      await widget.windowController.setAuthenticationRoute(active);
      applied = true;
    } catch (_) {
      // A later route notification retries a failed native window transition.
    } finally {
      _authenticationWindowTransitionRequested = false;
      if (mounted && (applied || !routeStillMatches())) {
        _maybeEnterInitialPetMode();
      }
    }
  }

  Future<void> _enterAppModeForWorld() async {
    var revealedApp = false;
    try {
      await _setNativePetVisibility(false, recoverAppOnShowFailure: false);
      await widget.windowController.revealAppMode();
      revealedApp = true;
    } catch (_) {
      // The World route remains authoritative. Route/window notifications can
      // retry after the native app window bridge becomes available again.
    } finally {
      if (mounted) {
        _worldTransitionRequested = false;
        if (revealedApp) {
          _maybeEnterInitialPetMode();
        } else {
          _reconcileNativePet();
        }
      }
    }
  }

  Future<void> _selectDestinationById(String id) async {
    CompanionMenuEntry? selected;
    for (final entry in CompanionMenuCatalog.entries) {
      if (entry.destination.id == id) {
        selected = entry;
        break;
      }
    }
    if (selected != null) await _selectDestination(selected);
  }

  Future<void> _selectDestination(CompanionMenuEntry entry) async {
    final opensWorld =
        Uri.tryParse(entry.destination.route)?.path ==
        AppRouteCatalog.agentSpace;
    if (opensWorld) {
      _worldNavigationPending = true;
    }
    try {
      if (opensWorld) {
        await _setNativePetVisibility(false, recoverAppOnShowFailure: false);
      }
      await widget.windowController.revealAppMode();
      final callback = widget.onDestinationSelected;
      if (callback != null) {
        await callback(entry);
        return;
      }
      if (appNavigation.isConfigured) {
        appNavigation.go(entry.destination.route);
      }
    } finally {
      if (opensWorld) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _worldNavigationPending = false;
          _maybeEnterInitialPetMode();
        });
      }
    }
  }

  Future<void> _handleHostCommand(DesktopCompanionHostCommand command) async {
    switch (command) {
      case DesktopCompanionHostCommand.openApp:
        await widget.windowController.revealAppMode();
        return;
      case DesktopCompanionHostCommand.hidePet:
        _petExplicitlyHidden = true;
        await widget.windowController.hidePet();
        return;
      case DesktopCompanionHostCommand.hostUnavailable:
        _avatarInteractionCoordinator?.deactivate();
        _nextNativePetRequestGeneration();
        _pendingNativePetVisibility = null;
        _pendingNativePetOperation = null;
        _nativePetShown = false;
        _petPresentation.value = DesktopPetPresentationState.unavailable;
        _autoTransitionRequested = false;
        // Losing the renderer must not reopen a chat window the user closed.
        await widget.windowController.hidePet();
        return;
      case DesktopCompanionHostCommand.quit:
        await _trayController.handleCommand(DesktopCompanionTrayCommand.quit);
        return;
    }
  }

  void _handleGazeChanged(Offset? gaze) {
    appServices.maybeFind<GazeDirector>()?.setDesktopPointerGaze(gaze);
  }

  Future<void> _handleAvatarInteraction(
    DesktopAvatarInteractionV1 interaction,
  ) async {
    if (!_canHandleAvatarInteraction() ||
        interaction.generation != _nativePetRequestGeneration) {
      return;
    }
    await _interactionCoordinator.handle(interaction);
  }

  bool _canHandleAvatarInteraction() {
    return mounted &&
        _hostInitialized &&
        _hostGateway.isSupported &&
        widget.windowController.supportsIndependentPetWindow &&
        widget.windowController.petVisible &&
        _nativePetShown &&
        _pendingNativePetVisibility == null &&
        _canShowPetFromTray();
  }

  void _handleWindowModeChanged() {
    if (widget.windowController.isTransitioning) {
      if (mounted) setState(() {});
      return;
    }
    final petVisible = widget.windowController.petVisible;
    if (petVisible && !widget.windowController.isTransitioning) {
      _petExplicitlyHidden = false;
    }
    _reconcileNativePet();
    if (mounted) setState(() {});
  }

  void _handlePetPresentationChanged() {
    final ready = widget.isPetPresentationReady?.call() == true;
    final becameReady = ready && !_lastPetPresentationReady;
    _lastPetPresentationReady = ready;
    if (becameReady &&
        _petPresentation.value == DesktopPetPresentationState.unavailable &&
        !_petExplicitlyHidden &&
        _canShowPetFromTray()) {
      _petPresentation.value = DesktopPetPresentationState.hidden;
      _autoTransitionRequested = false;
      _maybeEnterInitialPetMode();
    }
    if (widget.isPetPresentationFailed?.call() == true) {
      _petPresentation.value = DesktopPetPresentationState.unavailable;
    }
    _reconcileNativePet();
    if (widget.isPetPresentationFailed?.call() != true) return;
    _autoTransitionRequested = false;
    if (!widget.windowController.supportsIndependentPetWindow ||
        !widget.windowController.petVisible ||
        !_canShowPetFromTray() ||
        _petPresentationRecoveryRequested) {
      return;
    }
    unawaited(_recoverFromPetPresentationFailure());
  }

  Future<void> _recoverFromPetPresentationFailure() async {
    if (_petPresentationRecoveryRequested) return;
    _petPresentationRecoveryRequested = true;
    _autoTransitionRequested = false;
    try {
      await _setNativePetVisibility(false, recoverAppOnShowFailure: false);
      if (widget.windowController.petVisible) {
        await widget.windowController.hidePet();
      }
    } catch (_) {
      // Native gateways own their own logging. A later explicit summon can
      // retry after the sidecar becomes healthy again.
    } finally {
      _petPresentationRecoveryRequested = false;
      if (mounted) {
        _reconcileNativePet();
        setState(() {});
      }
    }
  }

  void _reconcileNativePet() {
    if (!_hostInitialized ||
        !_hostGateway.isSupported ||
        !widget.windowController.supportsIndependentPetWindow) {
      return;
    }
    // A route rebuild may arrive before the first frame commits petVisible.
    // Preserve that pending show only while its original authority still holds.
    final preparingPet =
        _petModeTransitionOperation != null &&
        _pendingNativePetVisibility == true &&
        !_automaticPetModeCancelled &&
        !_petExplicitlyHidden;
    final shouldShow =
        widget.isScenePresentation?.call() != true &&
        (widget.isPetPresentationReady?.call() ?? true) &&
        _canShowPetFromTray() &&
        widget.petAvailable &&
        (widget.windowController.petVisible || preparingPet);
    unawaited(_setNativePetVisibility(shouldShow));
  }

  Future<void> _setNativePetVisibility(
    bool shouldShow, {
    bool recoverAppOnShowFailure = true,
  }) {
    if (!_hostInitialized ||
        !_hostGateway.isSupported ||
        !widget.windowController.supportsIndependentPetWindow) {
      return Future<void>.value();
    }
    if (_pendingNativePetVisibility == shouldShow) {
      return _pendingNativePetOperation ?? Future<void>.value();
    }
    if (_pendingNativePetVisibility == null && shouldShow == _nativePetShown) {
      if (shouldShow) _scheduleBubbleRender();
      return Future<void>.value();
    }

    final generation = _nextNativePetRequestGeneration();
    _pendingNativePetVisibility = shouldShow;
    if (!shouldShow) {
      _avatarInteractionCoordinator?.deactivate();
      _bubbleDebounce?.cancel();
      _bubbleRenderPending = false;
      appServices.maybeFind<GazeDirector>()?.setDesktopPointerGaze(null);
    }

    final operation = _performNativePetTransition(
      shouldShow,
      generation: generation,
      recoverAppOnShowFailure: recoverAppOnShowFailure,
    );
    _pendingNativePetOperation = operation;
    return operation;
  }

  Future<void> _performNativePetTransition(
    bool shouldShow, {
    required int generation,
    required bool recoverAppOnShowFailure,
  }) async {
    try {
      await _enqueueHostLifecycle(() async {
        if (!mounted || generation != _nativePetRequestGeneration) return;
        if (shouldShow) {
          _interactionCoordinator.activateGeneration(generation);
          await _hostGateway.show(interactionGeneration: generation);
          final text = _replySnapshot.text.trim();
          if (text.isNotEmpty) await _hostGateway.showBubble(text);
        } else {
          await _hostGateway.clearBubble();
          await _hostGateway.hide();
        }
      });
      if (!mounted || generation != _nativePetRequestGeneration) return;
      _nativePetShown = shouldShow;
      _pendingNativePetVisibility = null;
      _pendingNativePetOperation = null;
      if (shouldShow) {
        _scheduleBubbleRender();
      }
    } catch (_) {
      if (!mounted || generation != _nativePetRequestGeneration) return;
      if (!shouldShow) {
        _pendingNativePetVisibility = null;
        _pendingNativePetOperation = null;
        return;
      }

      _nativePetShown = false;
      _petPresentation.value = DesktopPetPresentationState.unavailable;
      _avatarInteractionCoordinator?.deactivate();
      _autoTransitionRequested = false;
      if (recoverAppOnShowFailure) {
        try {
          await widget.windowController.hidePet();
        } catch (_) {
          // The normal window gateway owns rollback/logging. A later tray or
          // route notification can retry once the native host is available.
        }
      }
      if (!mounted || generation != _nativePetRequestGeneration) return;
      _pendingNativePetVisibility = null;
      _pendingNativePetOperation = null;
    }
  }

  Future<void> _enqueueHostLifecycle(Future<void> Function() operation) {
    final result = _hostLifecycleQueue.then<void>((_) => operation());
    _hostLifecycleQueue = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  int _nextNativePetRequestGeneration() {
    _nativePetRequestGeneration =
        _nativePetRequestGeneration >=
            DesktopAvatarInteractionV1.maximumGeneration
        ? DesktopAvatarInteractionV1.minimumGeneration
        : _nativePetRequestGeneration + 1;
    return _nativePetRequestGeneration;
  }

  AvatarInteractionCoordinator get _interactionCoordinator =>
      _avatarInteractionCoordinator ??= AvatarInteractionCoordinator();
}

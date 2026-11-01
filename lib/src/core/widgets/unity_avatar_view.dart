import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_scope.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_coordinator.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_portal_gateway.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/widgets/ui/world_panel.dart';
import 'package:maaso/src/core/widgets/unity_webgl_avatar_host.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/desktop/presentation/windows_unity_player_host_view.dart';
import 'package:maaso/src/features/agent/presentation/companion/avatar_portal_texture.dart';

const bool _enableNativeUnityView = bool.fromEnvironment(
  'MAASO_ENABLE_UNITY_VIEW',
  defaultValue: true,
);

class UnityAvatarView extends StatefulWidget {
  const UnityAvatarView({
    super.key,
    this.backgroundColor,
    this.viewportSafeArea,
    this.viewportActive = true,
    this.includeWorld = false,
    this.onScreenTap,
    this.holdToWalk = false,
    this.showLoadingPlaceholder = true,
  });

  final Color? backgroundColor;
  final AvatarViewportSafeArea? viewportSafeArea;
  final bool viewportActive;
  final bool includeWorld;

  /// Pages with their own pending cue can hide the shared loading tile while
  /// preserving renderer preparation, native errors and existing host behavior.
  final bool showLoadingPlaceholder;

  /// Repeat the current ground target while holding in personal space.
  /// Home interactions and micro-world selections keep one-shot taps.
  final bool holdToWalk;
  final FutureOr<void> Function(double normalizedX, double normalizedY)?
  onScreenTap;

  @override
  State<UnityAvatarView> createState() => _UnityAvatarViewState();
}

class _UnityAvatarViewState extends State<UnityAvatarView>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  static const int _maxPrepareRetries = 40;
  static const Duration _prepareRetryDelay = Duration(milliseconds: 100);
  static const Duration _nativeReadyRetryDelay = Duration(milliseconds: 500);

  Timer? _prepareRetryTimer;
  int _prepareRetryCount = 0;
  int _prepareCycle = 0;
  UnityAvatarRuntime? _observedRuntime;
  UnityAvatarRuntime? _nativeViewOwnerRuntime;
  Worker? _runtimeReadyWorker;
  Worker? _presentationReadyWorker;
  AvatarViewportSafeArea? _lastAppliedViewportSafeArea;
  bool _macSceneSurfaceActive = false;
  Timer? _heldWalkTimer;
  Offset? _heldWalkPoint;
  int? _heldWalkPointer;
  bool _screenTapInFlight = false;
  bool _inputForeground = true;

  bool get _usesMacPortal =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  UnityAvatarRuntime? get _runtime =>
      appServices.isRegistered<UnityAvatarRuntime>()
      ? appServices.find<UnityAvatarRuntime>()
      : null;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    if (!_enableNativeUnityView) return;
    WidgetsBinding.instance.addObserver(this);
    if (_usesMacPortal) return;
    _prepareUnityView(resetRetryBudget: true);
    _scheduleViewportSafeAreaUpdate();
    if (_enableNativeUnityView &&
        (defaultTargetPlatform == TargetPlatform.iOS ||
            defaultTargetPlatform == TargetPlatform.android)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _prepareUnityView();
        _applyViewportSafeArea();
        _applyInitialUnityAvatar();
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_enableNativeUnityView || !_usesMacPortal) return;
    final active =
        AvatarPortalScope.maybeOf(context)?.sceneSurfaceActive ?? false;
    if (active == _macSceneSurfaceActive) return;
    _macSceneSurfaceActive = active;
    _lastAppliedViewportSafeArea = null;
    if (!active) {
      _cancelHeldWalk();
      _stopPrepareRetry();
      return;
    }
    _prepareUnityView(resetRetryBudget: true);
    _scheduleViewportSafeAreaUpdate();
  }

  @override
  void didUpdateWidget(covariant UnityAvatarView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.viewportActive || !widget.holdToWalk) _cancelHeldWalk();
    if (!widget.viewportActive) {
      _stopPrepareRetry();
      // A popup route can cover Home while its room remains visible through
      // translucent chrome. Retain the underlay until this view is disposed.
    }
    if (!_enableNativeUnityView) return;
    if (!oldWidget.viewportActive && widget.viewportActive) {
      _lastAppliedViewportSafeArea = null;
      _prepareUnityView(resetRetryBudget: true);
    }
    if (oldWidget.viewportSafeArea != widget.viewportSafeArea ||
        oldWidget.viewportActive != widget.viewportActive) {
      _scheduleViewportSafeAreaUpdate();
    }
  }

  @override
  void didChangeMetrics() {
    if (widget.viewportActive) _scheduleViewportSafeAreaUpdate();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _inputForeground = state == AppLifecycleState.resumed;
    if (!_inputForeground) _cancelHeldWalk();
    // AppAgentShell owns the shared Mac runtime and independent pet lifecycle.
    // A window preview must never suspend the pet when the app loses focus.
    if (_usesMacPortal) return;
    final runtime = _runtime;
    if (state == AppLifecycleState.resumed) {
      if (runtime != null) unawaited(runtime.resume());
      _prepareUnityView(resetRetryBudget: true);
    } else {
      _stopPrepareRetry();
      if (runtime != null &&
          (state == AppLifecycleState.paused ||
              state == AppLifecycleState.hidden)) {
        unawaited(runtime.pause());
      }
    }
  }

  @override
  void dispose() {
    _cancelHeldWalk();
    _stopPrepareRetry();
    _releaseNativeView();
    _runtimeReadyWorker?.dispose();
    _presentationReadyWorker?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final backgroundColor = widget.backgroundColor ?? Colors.transparent;
    Widget child;
    if (_enableNativeUnityView) {
      child = ColoredBox(
        color: backgroundColor,
        child: kIsWeb
            ? UnityWebGLAvatarHost(
                viewportActive: widget.viewportActive,
                fallback: _UnityAvatarPlaceholder(
                  showLoading: widget.showLoadingPlaceholder,
                ),
                onReady: _applyInitialUnityAvatar,
              )
            : _NativeUnityAvatarView(
                backgroundColor: backgroundColor,
                includeWorld: widget.includeWorld,
                viewportActive: widget.viewportActive,
                showLoadingPlaceholder: widget.showLoadingPlaceholder,
              ),
      );
    } else {
      child = ColoredBox(
        color: backgroundColor,
        child: _UnityAvatarPlaceholder(
          showLoading: widget.showLoadingPlaceholder,
        ),
      );
    }

    if (widget.holdToWalk) {
      // Walking is a held control: start with the press, without waiting for
      // Flutter's long-press delay and potentially stopping after the first step.
      return Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _startHeldWalk,
        onPointerMove: (event) {
          if (event.pointer == _heldWalkPointer) {
            _heldWalkPoint = _screenPoint(event.localPosition);
          }
        },
        onPointerUp: (event) {
          if (event.pointer == _heldWalkPointer) _cancelHeldWalk();
        },
        onPointerCancel: (event) {
          if (event.pointer == _heldWalkPointer) _cancelHeldWalk();
        },
        child: child,
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTapDown: _handleScreenTap,
      child: child,
    );
  }

  void _handleScreenTap(TapDownDetails details) {
    final point = _screenPoint(details.localPosition);
    if (point != null) unawaited(_dispatchScreenPoint(point));
  }

  bool get _canDispatchScreenInput =>
      mounted &&
      _inputForeground &&
      widget.viewportActive &&
      (!_usesMacPortal || _macSceneSurfaceActive) &&
      (ModalRoute.of(context)?.isCurrent ?? true);

  Offset? _screenPoint(Offset localPosition) {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return null;
    final size = renderObject.size;
    if (size.width <= 0 || size.height <= 0) return null;
    return Offset(
      (localPosition.dx / size.width).clamp(0.0, 1.0).toDouble(),
      (localPosition.dy / size.height).clamp(0.0, 1.0).toDouble(),
    );
  }

  Future<void> _dispatchScreenPoint(Offset point) async {
    if (!_canDispatchScreenInput || _screenTapInFlight) return;
    _screenTapInFlight = true;
    try {
      final onScreenTap = widget.onScreenTap;
      if (onScreenTap != null) {
        await onScreenTap(point.dx, point.dy);
      } else {
        final runtime = appServices.maybeFind<ActiveAvatarRuntime>()?.current;
        if (runtime is AvatarScreenAttentionRuntime) {
          await (runtime as AvatarScreenAttentionRuntime).reactToScreenTap(
            normalizedX: point.dx,
            normalizedY: point.dy,
          );
        }
      }
    } finally {
      _screenTapInFlight = false;
    }
  }

  void _startHeldWalk(PointerDownEvent event) {
    if (!widget.holdToWalk ||
        !_canDispatchScreenInput ||
        _heldWalkPointer != null ||
        event.buttons != 1) {
      return;
    }
    _heldWalkPointer = event.pointer;
    _heldWalkPoint = _screenPoint(event.localPosition);
    _repeatHeldWalk();
    if (_heldWalkPoint == null) return;
    _heldWalkTimer = Timer.periodic(
      const Duration(milliseconds: 120),
      (_) => _repeatHeldWalk(),
    );
  }

  void _repeatHeldWalk() {
    final point = _heldWalkPoint;
    if (!_canDispatchScreenInput || point == null) {
      _cancelHeldWalk();
      return;
    }
    // A slow native call may outlive a timer tick. Drop that tick instead of
    // accumulating a queue that would keep moving after the finger is lifted.
    unawaited(_dispatchScreenPoint(point));
  }

  void _cancelHeldWalk() {
    _heldWalkTimer?.cancel();
    _heldWalkTimer = null;
    _heldWalkPoint = null;
    _heldWalkPointer = null;
  }

  void _prepareUnityView({bool resetRetryBudget = false}) {
    if (!widget.viewportActive ||
        !_inputForeground ||
        (_usesMacPortal && !_macSceneSurfaceActive)) {
      return;
    }
    if (resetRetryBudget) {
      _stopPrepareRetry();
      _prepareRetryCount = 0;
    }
    final runtime = _runtime;
    if (runtime == null) {
      _schedulePrepareRetry();
      return;
    }
    _observeRuntime(runtime);
    if (!kIsWeb &&
        defaultTargetPlatform == TargetPlatform.iOS &&
        !identical(_nativeViewOwnerRuntime, runtime)) {
      _releaseNativeView();
      _nativeViewOwnerRuntime = runtime;
      runtime.retainNativeView(this);
    }
    _debugLog('prepareView dispatch');
    unawaited(runtime.prepareView());
    _applyViewportSafeArea();
    if (runtime.isReady.value) {
      if (widget.viewportActive) _applyInitialUnityAvatar();
    }
    if (!runtime.presentationReady.value) {
      _schedulePrepareRetry();
    }
  }

  void _releaseNativeView() {
    final runtime = _nativeViewOwnerRuntime;
    _nativeViewOwnerRuntime = null;
    if (runtime != null) unawaited(runtime.releaseNativeView(this));
  }

  void _observeRuntime(UnityAvatarRuntime runtime) {
    if (identical(_observedRuntime, runtime)) return;
    _runtimeReadyWorker?.dispose();
    _presentationReadyWorker?.dispose();
    _observedRuntime = runtime;
    _runtimeReadyWorker = runtime.isReady.listen((ready) {
      if (!mounted || !identical(_runtime, runtime)) return;
      if (ready) {
        if (runtime.presentationReady.value) _stopPrepareRetry();
        if (_inputForeground && widget.viewportActive) {
          _applyInitialUnityAvatar();
        }
      } else if (_inputForeground && widget.viewportActive) {
        _prepareUnityView(resetRetryBudget: true);
      }
    });
    if (!identical(runtime.presentationReady, runtime.isReady)) {
      _presentationReadyWorker = runtime.presentationReady.listen((ready) {
        if (!mounted || !identical(_runtime, runtime)) return;
        if (ready) {
          _stopPrepareRetry();
        } else if (_inputForeground && widget.viewportActive) {
          _prepareUnityView(resetRetryBudget: true);
        }
      });
    }
  }

  void _stopPrepareRetry() {
    _prepareCycle++;
    _prepareRetryTimer?.cancel();
    _prepareRetryTimer = null;
  }

  void _schedulePrepareRetry() {
    if (!mounted ||
        !_inputForeground ||
        !widget.viewportActive ||
        (_usesMacPortal && !_macSceneSurfaceActive) ||
        _prepareRetryTimer?.isActive == true) {
      return;
    }
    if (_prepareRetryCount >= _maxPrepareRetries) {
      _debugLog(
        'prepareView stopped after $_prepareRetryCount retries without presentation',
      );
      return;
    }
    final retry = ++_prepareRetryCount;
    final runtime = _runtime;
    final cycle = _prepareCycle;
    _debugLog('prepareView retry=$retry: presentation not ready');
    _prepareRetryTimer = Timer(
      runtime == null ? _prepareRetryDelay : _nativeReadyRetryDelay,
      () {
        _prepareRetryTimer = null;
        if (!mounted || cycle != _prepareCycle) return;
        if (runtime?.presentationReady.value == true) return;
        _prepareUnityView();
      },
    );
  }

  void _scheduleViewportSafeAreaUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _applyViewportSafeArea();
    });
  }

  void _applyViewportSafeArea() {
    if (_usesMacPortal && !_macSceneSurfaceActive) return;
    if (!widget.viewportActive) return;
    final safeArea = widget.viewportSafeArea;
    if (safeArea == null || _lastAppliedViewportSafeArea == safeArea) {
      return;
    }
    final runtime = _runtime;
    if (runtime == null) {
      _schedulePrepareRetry();
      return;
    }
    _lastAppliedViewportSafeArea = safeArea;
    _debugLog(
      'viewportSafeArea top=${safeArea.top.toStringAsFixed(3)} '
      'bottom=${safeArea.bottom.toStringAsFixed(3)}',
    );
    unawaited(runtime.setViewportSafeArea(safeArea));
  }
}

class _NativeUnityAvatarView extends StatelessWidget {
  const _NativeUnityAvatarView({
    required this.backgroundColor,
    required this.includeWorld,
    required this.viewportActive,
    required this.showLoadingPlaceholder,
  });

  final Color backgroundColor;
  final bool includeWorld;
  final bool viewportActive;
  final bool showLoadingPlaceholder;

  @override
  Widget build(BuildContext context) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return const SizedBox.expand();
      case TargetPlatform.iOS:
        return const SizedBox.expand();
      case TargetPlatform.macOS:
        return _MacOSUnityAvatarPortalView(
          includeWorld: includeWorld,
          viewportActive: viewportActive,
          fallback: _UnityAvatarPlaceholder(
            showLoading: showLoadingPlaceholder,
          ),
        );
      case TargetPlatform.windows:
        return WindowsUnityPlayerHostView(
          fallback: _UnityAvatarPlaceholder(
            showLoading: showLoadingPlaceholder,
          ),
        );
      case TargetPlatform.fuchsia:
      case TargetPlatform.linux:
        return _UnityAvatarPlaceholder(showLoading: showLoadingPlaceholder);
    }
  }
}

class _MacOSUnityAvatarPortalView extends StatefulWidget {
  const _MacOSUnityAvatarPortalView({
    required this.fallback,
    required this.includeWorld,
    required this.viewportActive,
  });

  final Widget fallback;
  final bool includeWorld;
  final bool viewportActive;

  @override
  State<_MacOSUnityAvatarPortalView> createState() =>
      _MacOSUnityAvatarPortalViewState();
}

class _MacOSUnityAvatarPortalViewState
    extends State<_MacOSUnityAvatarPortalView> {
  AvatarPortalCoordinator? _portal;
  bool _portalRebuildScheduled = false;
  bool _activationScheduled = false;
  bool _activationInFlight = false;
  bool _sceneSurfaceActive = true;
  ({bool includeWorld, int? width, int? height})? _desiredCapture;
  ({bool includeWorld, int? width, int? height})? _requestedCapture;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final scope = AvatarPortalScope.maybeOf(context);
    final nextPortal = scope?.portal;
    final sceneSurfaceActive = scope?.sceneSurfaceActive ?? true;
    if (identical(nextPortal, _portal) &&
        _sceneSurfaceActive == sceneSurfaceActive) {
      return;
    }
    _sceneSurfaceActive = sceneSurfaceActive;
    _portal?.removeListener(_handlePortalChanged);
    _portal = nextPortal;
    _requestedCapture = null;
    nextPortal?.addListener(_handlePortalChanged);
  }

  @override
  void didUpdateWidget(covariant _MacOSUnityAvatarPortalView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.viewportActive && widget.viewportActive) {
      _requestedCapture = null;
    }
  }

  @override
  void dispose() {
    _portal?.removeListener(_handlePortalChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_sceneSurfaceActive || !widget.viewportActive) {
      _desiredCapture = null;
      return const SizedBox.expand();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = widget.includeWorld
            ? AvatarPortalCapturePolicy.fitSceneViewport(
                width: constraints.maxWidth,
                height: constraints.maxHeight,
                devicePixelRatio: MediaQuery.devicePixelRatioOf(context),
              )
            : null;
        _desiredCapture = widget.includeWorld && viewport == null
            ? null
            : (
                includeWorld: widget.includeWorld,
                width: viewport?.width,
                height: viewport?.height,
              );
        _scheduleActivation();
        final portal = _portal;
        final lease = portal?.lease;
        if (portal?.phase == AvatarPortalPhase.visible &&
            lease != null &&
            portal!.usesCaptureConfiguration(
              profile: AvatarPortalProfile.compactHigh,
              targetFps: 30,
              includeWorld: widget.includeWorld,
              viewportWidth: viewport?.width,
              viewportHeight: viewport?.height,
            )) {
          return AvatarPortalTexture(
            lease: lease,
            fillViewport: widget.includeWorld,
          );
        }
        return widget.fallback;
      },
    );
  }

  void _scheduleActivation() {
    if (!widget.viewportActive ||
        !_sceneSurfaceActive ||
        _portal == null ||
        _desiredCapture == null ||
        _desiredCapture == _requestedCapture ||
        _activationScheduled ||
        _activationInFlight) {
      return;
    }
    _activationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _activationScheduled = false;
      final portal = _portal;
      if (!mounted ||
          !widget.viewportActive ||
          !_sceneSurfaceActive ||
          portal == null ||
          _desiredCapture == null) {
        return;
      }
      unawaited(_activate(portal));
    });
  }

  Future<void> _activate(AvatarPortalCoordinator portal) async {
    final capture = _desiredCapture!;
    _requestedCapture = capture;
    _activationInFlight = true;
    try {
      if (portal.phase == AvatarPortalPhase.suspended) {
        await portal.resume();
      }
      if (!mounted ||
          !identical(portal, _portal) ||
          !widget.viewportActive ||
          !_sceneSurfaceActive ||
          capture != _desiredCapture) {
        return;
      }
      await portal.summon(
        includeWorld: capture.includeWorld,
        viewportWidth: capture.width,
        viewportHeight: capture.height,
      );
    } catch (_) {
      // The fallback remains visible and the coordinator retains diagnostics.
    } finally {
      _activationInFlight = false;
      if (mounted && identical(portal, _portal)) {
        setState(() {});
        _scheduleActivation();
      }
    }
  }

  void _handlePortalChanged() {
    if (!mounted) return;
    if (WidgetsBinding.instance.schedulerPhase !=
        SchedulerPhase.persistentCallbacks) {
      setState(() {});
      return;
    }
    if (_portalRebuildScheduled) return;
    _portalRebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _portalRebuildScheduled = false;
      if (mounted) setState(() {});
    });
  }
}

void _applyInitialUnityAvatar() {
  if (!appServices.isRegistered<AvatarConfigService>()) return;
  unawaited(
    appServices
        .find<AvatarConfigService>()
        .ensureSelectedDisplayReady()
        .catchError((Object error, StackTrace stackTrace) {
          _debugLog('initial avatar apply failed: $error');
        }),
  );
}

void _debugLog(String message) {
  if (!kDebugMode) return;
  debugPrint('[UnityAvatar] $message');
}

class _UnityAvatarPlaceholder extends StatelessWidget {
  const _UnityAvatarPlaceholder({this.showLoading = true});

  final bool showLoading;

  @override
  Widget build(BuildContext context) {
    if (!showLoading) return const SizedBox.expand();
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
      ),
      child: _enableNativeUnityView
          ? Center(
              child: WorldPanel(
                variant: WorldPanelVariant.pass,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 16,
                ),
                borderRadius: const BorderRadius.all(Radius.circular(24)),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.view_in_ar_rounded,
                      color: ColorConstant.primaryColor,
                      size: 26,
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: 26,
                      child: LinearProgressIndicator(
                        minHeight: 4,
                        borderRadius: BorderRadius.circular(999),
                        color: ColorConstant.secondaryColor,
                        backgroundColor: ColorConstant.divider,
                      ),
                    ),
                  ],
                ),
              ),
            )
          : null,
    );
  }
}

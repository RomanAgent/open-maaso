import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/avatar_viewport_policy.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_controller.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_page_adapter.dart';

class AgentSpacePage extends StatefulWidget {
  const AgentSpacePage({super.key, this.controller, this.autoEnter = true});

  final AgentSpaceController? controller;
  final bool autoEnter;

  @override
  State<AgentSpacePage> createState() => _AgentSpacePageState();
}

class _AgentSpacePageState extends State<AgentSpacePage>
    with WidgetsBindingObserver
    implements AgentSpacePageTarget {
  late final _controller =
      widget.controller ?? appServices.find<AgentSpaceController>();
  final _activitySource = Object();
  ModalRoute<dynamic>? _route;
  Listenable? _router;
  AppLifecycleState? _lifecycle = WidgetsBinding.instance.lifecycleState;
  bool _leaving = false;
  bool _wasVisible = false;
  int _activityEpoch = 0;
  Future<void>? _leaveInFlight;
  AgentSpacePageAdapter? _adapter;
  PageAgentAdapterRegistration<AgentSpacePageAdapter>? _registration;

  bool get _isCurrent => mounted && (_route?.isCurrent ?? true);
  bool get _isResumed =>
      _lifecycle == null || _lifecycle == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final uiControl = appServices.maybeFind<AgentUiControlService>();
    if (uiControl != null) {
      final adapter = AgentSpacePageAdapter(
        coordinator: uiControl.coordinator,
        target: this,
      );
      _adapter = adapter;
      _registration = uiControl.adapters.register(adapter);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route = ModalRoute.of(context);
    final router = GoRouter.maybeOf(context)?.routerDelegate;
    if (!identical(router, _router)) {
      _router?.removeListener(_syncActivity);
      _router = router;
      router?.addListener(_syncActivity);
    }
    _syncActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
    _syncActivity();
    if (mounted) setState(() {});
  }

  void _syncActivity() {
    final visible = _isCurrent && _isResumed && !_leaving;
    final changed = visible != _wasVisible;
    if (changed) {
      _wasVisible = visible;
      _activityEpoch++;
    }
    _controller.setActivity(
      resumed: _isResumed,
      // A normal exit still owns the native room until its final camera frame.
      // Background, route replacement and disposal retain their strict fences.
      currentPage: _isCurrent,
      source: _activitySource,
    );
    if (!widget.autoEnter || !visible || !changed) return;
    final epoch = _activityEpoch;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          epoch == _activityEpoch &&
          _isCurrent &&
          _isResumed &&
          !_leaving) {
        unawaited(_enter());
      }
    });
  }

  @override
  bool get canExitAgentSpace =>
      _isCurrent &&
      _isResumed &&
      !_leaving &&
      _controller.isCurrentPresentation;

  @override
  void exitAgentSpace() => unawaited(_leave());

  Future<void> _enter() => _controller.enter(
    animated: !MediaQuery.disableAnimationsOf(context),
    // Preserve the currently rendered Home viewport during the handoff.
    // Clearing its insets would enlarge the avatar as the room takes over.
  );

  Future<void> _leave() {
    final active = _leaveInFlight;
    if (active != null) return active;
    if (!canExitAgentSpace) return Future<void>.value();
    setState(() => _leaving = true);
    final media = MediaQuery.of(context);
    final homeViewport = MaasoAvatarViewportPolicy.safeAreaFor(
      size: media.size,
      padding: media.viewPadding,
      viewInsets: EdgeInsets.zero,
    );
    final cleanup = _controller.leave(
      animated: !media.disableAnimations,
      // Home chrome appears immediately; the exact native room transaction
      // continues its normal walk/camera return under the controller's fence.
      handoffToHome: true,
      homeViewportSafeArea: homeViewport,
    );
    _syncActivity();
    final leaving = cleanup.then<void>(
      (_) {},
      onError: (Object error, StackTrace _) {
        debugPrint('[AgentSpace] exit cleanup failed: $error');
        // This widget no longer owns navigation or a later session. Exact
        // renderer/session cleanup stays with the admitted controller operation.
      },
    );
    _leaveInFlight = leaving;
    if (mounted && _isCurrent && _controller.isCurrentPresentation) {
      appNavigation.go(AppRouteCatalog.home);
    }
    return leaving;
  }

  @override
  void dispose() {
    _leaving = true;
    _activityEpoch++;
    _adapter?.detach();
    _registration?.unregister();
    _router?.removeListener(_syncActivity);
    _controller.setActivity(
      resumed: _isResumed,
      currentPage: false,
      source: _activitySource,
    );
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final desktop =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.windows);
    final backgroundColor = desktop ? glass.surface : Colors.transparent;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) exitAgentSpace();
      },
      child: AppGlassScaffold(
        backdropKind: GlassBackdropKind.platformView,
        backgroundColor: backgroundColor,
        safeArea: false,
        resizeToAvoidBottomInset: false,
        body: ValueListenableBuilder<AgentSpaceState>(
          valueListenable: _controller.state,
          builder: (context, state, _) {
            final active = !_leaving && state.phase == AgentSpacePhase.active;
            // Mount/warm the real native host during entry. Until the entry
            // receipt succeeds it keeps Home framing and declines room input.
            final viewportActive = _isCurrent && _isResumed;
            return Stack(
              fit: StackFit.expand,
              children: [
                UnityAvatarView(
                  includeWorld: true,
                  showLoadingPlaceholder: false,
                  holdToWalk: !_leaving,
                  backgroundColor: backgroundColor,
                  // The native command receives the destination safe area and
                  // owns the whole transition; avoid a second framing write.
                  viewportSafeArea: null,
                  viewportActive: viewportActive,
                  onScreenTap: (x, y) async {
                    if (!active || !viewportActive) return;
                    await _controller.handleScreenTap(x, y);
                  },
                ),
                SafeArea(
                  child: Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: AppGlassIconButton(
                        key: const ValueKey('agent-space-exit'),
                        icon: Icons.close_rounded,
                        tooltip: 'agent_space.exit'.tr,
                        onPressed: canExitAgentSpace ? exitAgentSpace : null,
                      ),
                    ),
                  ),
                ),
                if (!_leaving && state.phase == AgentSpacePhase.failure)
                  _SpaceStatus(
                    message: state.message,
                    onRetry: () => unawaited(_enter()),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SpaceStatus extends StatelessWidget {
  const _SpaceStatus({required this.message, required this.onRetry});

  final String? message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: AppGlassSurface(
          role: AppGlassSurfaceRole.transient,
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message ?? 'agent_space.failed'.tr,
                key: const ValueKey('agent-space-status'),
                textAlign: TextAlign.center,
                style: TextStyle(color: glass.foregroundPrimary),
              ),
              const SizedBox(height: 12),
              AppGlassButton(
                key: const ValueKey('agent-space-retry'),
                label: 'common.retry'.tr,
                primary: false,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/core/services/account_session_lifecycle_service.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/auth/application/login_controller.dart';
import 'package:maaso/src/features/auth/application/login_doorway_coordinator.dart';
import 'package:maaso/src/core/widgets/avatar_viewport_policy.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/features/identity/application/identity_route_policy.dart';
import 'login_doorway_artwork.dart';

enum _LoginPanelStage { landing, signIn, signUp }

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with WidgetsBindingObserver {
  final LoginController controller = appServices.find<LoginController>();
  final FocusNode _passwordFocusNode = FocusNode();
  final GlobalKey _formPanelKey = GlobalKey();
  final GlobalKey _submitAnchorKey = GlobalKey();
  late final Future<void> Function() _exitPresentation = _animateExit;
  Future<void> Function()? _previousExitPresentation;
  late final LoginDoorwayCoordinator _doorway;
  Worker? _doorwayWorker;
  Timer? _doorwayPoll;
  Completer<void>? _doorwayFinished;
  Completer<void>? _keyboardDismissed;
  bool _keyboardCheckQueued = false;

  var _stage = _LoginPanelStage.signIn;
  var _passwordVisible = false;
  var _logoTapCount = 0;
  var _presentingWorld = false;
  var _revealingWorld = false;
  Rect? _submitRect;
  double? _lastIdleSubmitGlobalY;
  var _posterHeightForMeasurement = 0.0;
  var _bodyTopGlobal = 0.0;
  var _submitMeasurementQueued = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _doorway = LoginDoorwayCoordinator.ensure();
    _previousExitPresentation = controller.beforeAuthenticatedNavigation;
    controller.beforeAuthenticatedNavigation = _exitPresentation;
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (identical(
      controller.beforeAuthenticatedNavigation,
      _exitPresentation,
    )) {
      controller.beforeAuthenticatedNavigation = _previousExitPresentation;
    }
    _doorwayPoll?.cancel();
    _doorwayWorker?.dispose();
    if (_doorwayFinished?.isCompleted == false) _doorwayFinished!.complete();
    if (_keyboardDismissed?.isCompleted == false) {
      _keyboardDismissed!.complete();
    }
    _passwordFocusNode.dispose();
    super.dispose();
  }

  Future<void> _animateExit() async {
    // Every authenticated destination, including skipped entrance/onboarding,
    // waits for the native keyboard and the Flutter layout to finish closing.
    await _dismissKeyboardForEntry();
    if (!mounted) return;
    if (_previousExitPresentation != null) {
      await _previousExitPresentation!();
    }
    if (!mounted ||
        !_doorway.active ||
        IdentityRoutePolicy.redirect(AppRouteCatalog.home) != null) {
      return;
    }
    final finished = _doorwayFinished = Completer<void>();
    _doorwayWorker = _doorway.phase.listen(_handleDoorwayPhase);
    setState(() => _presentingWorld = true);
    // The Login route owns the live Unity view for the whole door sequence.
    // Home is selected only after its camera has settled on the Avatar.
    WidgetsBinding.instance.scheduleFrame();
    await WidgetsBinding.instance.endOfFrame.timeout(
      const Duration(milliseconds: 300),
      onTimeout: () {},
    );
    if (!mounted) return;
    _reconcileDoorway();
    _doorwayPoll = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _reconcileDoorway(),
    );
    await finished.future;
    _doorwayPoll?.cancel();
    _doorwayPoll = null;
    _doorwayWorker?.dispose();
    _doorwayWorker = null;
    _doorwayFinished = null;
  }

  Future<void> _dismissKeyboardForEntry() {
    final pending = _keyboardDismissed;
    if (pending != null) return pending.future;
    final finished = _keyboardDismissed = Completer<void>();
    FocusScope.of(context).unfocus();
    // Unfocus covers email, password and verification code. Explicitly hide
    // the native input as well, including an autofill/accessory keyboard.
    unawaited(
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide').catchError((
        Object _,
      ) {
        // A channel failure must not bypass the actual inset check.
      }),
    );
    _scheduleKeyboardDismissalCheck();
    return finished.future;
  }

  @override
  void didChangeMetrics() => _scheduleKeyboardDismissalCheck();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleKeyboardDismissalCheck();
  }

  void _scheduleKeyboardDismissalCheck() {
    if (_keyboardDismissed == null || _keyboardCheckQueued) return;
    _keyboardCheckQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardCheckQueued = false;
      if (!mounted ||
          View.of(context).viewInsets.bottom > 0 ||
          MediaQuery.viewInsetsOf(context).bottom > 0) {
        return;
      }
      final finished = _keyboardDismissed;
      _keyboardDismissed = null;
      if (finished != null && !finished.isCompleted) finished.complete();
    });
    WidgetsBinding.instance.scheduleFrame();
  }

  void _handleDoorwayPhase(LoginDoorwayStage phase) {
    if (!mounted) return;
    if (phase == LoginDoorwayStage.opening && !_revealingWorld) {
      setState(() => _revealingWorld = true);
    }
    if (phase == LoginDoorwayStage.completed ||
        phase == LoginDoorwayStage.skipped ||
        phase == LoginDoorwayStage.cancelled) {
      if (_doorwayFinished?.isCompleted == false) _doorwayFinished!.complete();
    }
  }

  void _reconcileDoorway() {
    if (!mounted || !_presentingWorld || !_doorway.active) return;
    final lifecycle = appServices.maybeFind<AccountSessionLifecycleService>();
    _doorway.reconcile(
      renderer: appServices.maybeFind<ActiveAvatarRuntime>()?.current,
      canPresent: () =>
          mounted &&
          _presentingWorld &&
          (ModalRoute.isCurrentOf(context) ?? true) &&
          (lifecycle?.isMounted ?? false) &&
          appServices.maybeFind<AvatarConfigService>()?.isSwitching.value !=
              true,
      reduceMotion: MediaQuery.disableAnimationsOf(context),
      prepareAvatar: _prepareSelectedAvatar,
    );
  }

  Future<void> _prepareSelectedAvatar() async {
    final config = appServices.maybeFind<AvatarConfigService>();
    if (config == null) return;
    // Account mounting starts reviewed Avatar reconciliation after the first
    // frame. Its bundled preview can replace the renderer even after Unity's
    // doorway prepare receipt, cancelling the camera during the door opening.
    while (mounted &&
        _doorway.active &&
        (config.selectionAuthorityState.value ==
                AvatarSelectionAuthorityState.synchronizing ||
            config.isSwitching.value)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (!mounted || !_doorway.active) return;
    await config.applyInitial();
    if (!mounted ||
        !_doorway.active ||
        !(ModalRoute.isCurrentOf(context) ?? true)) {
      return;
    }
    final lifecycle = appServices.maybeFind<AccountSessionLifecycleService>();
    if (!identical(config, appServices.maybeFind<AvatarConfigService>()) ||
        !config.selectionDisplayCurrent ||
        lifecycle?.isMounted != true) {
      throw StateError('login_avatar_not_presentable');
    }
    // Selection loading deliberately hides the old/default mesh. Login owns
    // the room until Home mounts, so it must release that display gate only
    // after the selected model is ready, before Unity can accept door prepare.
    await appServices.maybeFind<ActiveAvatarRuntime>()?.setLocalAvatarVisible(
      true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    return AppGlassScaffold(
      backdropKind: _presentingWorld
          ? GlassBackdropKind.platformView
          : GlassBackdropKind.flutter,
      backgroundColor: _presentingWorld ? Colors.transparent : null,
      resizeToAvoidBottomInset: false,
      safeArea: false,
      body: Stack(
        fit: StackFit.expand,
        clipBehavior: Clip.hardEdge,
        children: [
          if (_presentingWorld)
            const Positioned.fill(
              child: IgnorePointer(
                child: UnityAvatarView(
                  includeWorld: true,
                  // iOS Unity paints below Flutter; an opaque fill hides it.
                  backgroundColor: Colors.transparent,
                ),
              ),
            ),
          LayoutBuilder(
            builder: (context, constraints) {
              final visibleHeight = math.max(
                0.0,
                constraints.maxHeight - media.viewInsets.bottom,
              );
              final minimumFormHeight = switch (_stage) {
                _LoginPanelStage.signUp => 410.0,
                _ => 350.0,
              };
              // The room poster uses the full window, never the keyboard's
              // remaining space. Only the form moves up over its lower part.
              final artworkHeight =
                  constraints.maxWidth > constraints.maxHeight * 1.4
                  ? 0.0
                  : math.min(
                      constraints.maxHeight * .48,
                      math.max(0.0, constraints.maxHeight - minimumFormHeight),
                    );
              final posterHeight = constraints.maxWidth > visibleHeight * 1.4
                  ? 0.0
                  : math.min(
                      visibleHeight * .48,
                      math.max(0.0, visibleHeight - minimumFormHeight),
                    );
              final compact = visibleHeight < 480;
              final formWidth = math.max(
                0.0,
                math.min(430.0, constraints.maxWidth - 40),
              );
              _posterHeightForMeasurement = posterHeight;
              _scheduleSubmitMeasurement();
              return Stack(
                children: [
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: artworkHeight,
                    child: SizedBox(
                      key: const ValueKey('login-doorway-artwork'),
                      child: AnimatedOpacity(
                        opacity: _revealingWorld ? 0 : 1,
                        duration: const Duration(milliseconds: 180),
                        child: const LoginDoorwayArtwork(),
                      ),
                    ),
                  ),
                  Positioned(
                    top: posterHeight,
                    left: 0,
                    right: 0,
                    height: visibleHeight - posterHeight,
                    child: AnimatedSlide(
                      key: const ValueKey('login-form-exit'),
                      offset: _revealingWorld
                          ? const Offset(0, 1)
                          : Offset.zero,
                      duration: const Duration(milliseconds: 800),
                      curve: const _LoginDoorwayCoverCurve(),
                      child: ColoredBox(
                        key: _formPanelKey,
                        color: Theme.of(context).scaffoldBackgroundColor,
                        child: AppReactiveBuilder(() {
                          final canRetryPreparation =
                              _doorway.canRetryPreparation;
                          final busy = controller.busy || canRetryPreparation;
                          return TweenAnimationBuilder<double>(
                            tween: Tween<double>(begin: 0, end: busy ? 1 : 0),
                            duration: MediaQuery.disableAnimationsOf(context)
                                ? Duration.zero
                                : const Duration(milliseconds: 420),
                            curve: Curves.easeInOutCubic,
                            builder: (context, progress, _) => Stack(
                              fit: StackFit.expand,
                              children: [
                                AnimatedSlide(
                                  key: const ValueKey('login-form-content'),
                                  offset: Offset.zero,
                                  duration: const Duration(milliseconds: 430),
                                  curve: Curves.easeInCubic,
                                  child: SizedBox.expand(
                                    child: Padding(
                                      padding: EdgeInsets.fromLTRB(
                                        20,
                                        compact ? 8 : 16,
                                        20,
                                        media.padding.bottom +
                                            (compact ? 4 : 12),
                                      ),
                                      child: FittedBox(
                                        fit: BoxFit.scaleDown,
                                        alignment: Alignment.topCenter,
                                        child: SizedBox(
                                          width: formWidth,
                                          child: Column(
                                            mainAxisSize: MainAxisSize.min,
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              _formVisibility(
                                                key: 'login-header-visibility',
                                                busy:
                                                    _stage !=
                                                        _LoginPanelStage
                                                            .landing &&
                                                    busy,
                                                progress:
                                                    _stage ==
                                                        _LoginPanelStage.landing
                                                    ? 0
                                                    : progress,
                                                start: .44,
                                                child: GestureDetector(
                                                  onTap: _handleLogoTap,
                                                  child: Column(
                                                    children: [
                                                      Text(
                                                        _stage ==
                                                                _LoginPanelStage
                                                                    .signUp
                                                            ? 'auth.sign_up'.tr
                                                            : 'auth.sign_in'.tr,
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .titleLarge
                                                            ?.copyWith(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w600,
                                                            ),
                                                        textAlign:
                                                            TextAlign.center,
                                                      ),
                                                      if (!compact) ...[
                                                        const SizedBox(
                                                          height: 6,
                                                        ),
                                                        Text(
                                                          'auth.doorway.subtitle'
                                                              .tr,
                                                          textAlign:
                                                              TextAlign.center,
                                                          style: Theme.of(
                                                            context,
                                                          ).textTheme.bodySmall,
                                                        ),
                                                      ],
                                                    ],
                                                  ),
                                                ),
                                              ),
                                              SizedBox(
                                                height: compact ? 14 : 24,
                                              ),
                                              if (_stage ==
                                                  _LoginPanelStage.landing)
                                                _LandingActions(
                                                  controller: controller,
                                                  onSignUp: () => _openStage(
                                                    _LoginPanelStage.signUp,
                                                  ),
                                                  onSignIn: () => _openStage(
                                                    _LoginPanelStage.signIn,
                                                  ),
                                                  onProviderTap: controller
                                                      .providerLoginUnavailable,
                                                )
                                              else
                                                NotificationListener<
                                                  SizeChangedLayoutNotification
                                                >(
                                                  onNotification: (_) {
                                                    _scheduleSubmitMeasurement();
                                                    return false;
                                                  },
                                                  child: SizeChangedLayoutNotifier(
                                                    child: _AuthFormPanel(
                                                      controller: controller,
                                                      stage: _stage,
                                                      submitAnchorKey:
                                                          _submitAnchorKey,
                                                      busy: busy,
                                                      progress: progress,
                                                      canRetryPreparation:
                                                          canRetryPreparation,
                                                      showFallbackButton:
                                                          _submitRect == null ||
                                                          (!busy &&
                                                              progress == 0),
                                                      onRetryPreparation:
                                                          _retryDoorwayPreparation,
                                                      passwordVisible:
                                                          _passwordVisible,
                                                      passwordFocusNode:
                                                          _passwordFocusNode,
                                                      onSubmit: _submitAuthForm,
                                                      onTogglePassword: () =>
                                                          setState(
                                                            () => _passwordVisible =
                                                                !_passwordVisible,
                                                          ),
                                                      onSwitchStage: () => _openStage(
                                                        _stage ==
                                                                _LoginPanelStage
                                                                    .signUp
                                                            ? _LoginPanelStage
                                                                  .signIn
                                                            : _LoginPanelStage
                                                                  .signUp,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                if (_stage != _LoginPanelStage.landing &&
                                    _submitRect != null &&
                                    (busy || progress > 0))
                                  Positioned.fill(
                                    child: IgnorePointer(
                                      ignoring: !busy,
                                      child: Builder(
                                        builder: (context) {
                                          final rect = _submitRect!;
                                          final panelHeight =
                                              visibleHeight - posterHeight;
                                          final slack =
                                              panelHeight - rect.height;
                                          final startCenter =
                                              busy &&
                                                  _lastIdleSubmitGlobalY != null
                                              ? _lastIdleSubmitGlobalY! -
                                                    _bodyTopGlobal -
                                                    posterHeight
                                              : rect.center.dy;
                                          final normalAlignmentY = slack > 0
                                              ? (2 * startCenter -
                                                        panelHeight) /
                                                    slack
                                              : 0.0;
                                          return Align(
                                            key: const ValueKey(
                                              'login-submit-motion',
                                            ),
                                            alignment: Alignment(
                                              0,
                                              normalAlignmentY.clamp(
                                                    -1.0,
                                                    1.0,
                                                  ) *
                                                  (1 - progress),
                                            ),
                                            child: SizedBox(
                                              width: rect.width,
                                              height: rect.height,
                                              child: Stack(
                                                clipBehavior: Clip.none,
                                                children: [
                                                  FittedBox(
                                                    fit: BoxFit.fill,
                                                    child: SizedBox(
                                                      width: formWidth,
                                                      height: 56,
                                                      child: _ImmersiveActionButton(
                                                        label:
                                                            canRetryPreparation
                                                            ? 'common.retry'.tr
                                                            : _stage ==
                                                                  _LoginPanelStage
                                                                      .signUp
                                                            ? 'auth.create_account'
                                                                  .tr
                                                            : 'auth.log_in'.tr,
                                                        onTap:
                                                            canRetryPreparation
                                                            ? _retryDoorwayPreparation
                                                            : busy
                                                            ? null
                                                            : _submitAuthForm,
                                                        fillColor: Colors.black,
                                                        foregroundColor:
                                                            Colors.white,
                                                        loading:
                                                            busy &&
                                                            !canRetryPreparation,
                                                      ),
                                                    ),
                                                  ),
                                                  if (canRetryPreparation)
                                                    Positioned(
                                                      left: 0,
                                                      right: 0,
                                                      bottom: rect.height + 12,
                                                      child: Semantics(
                                                        liveRegion: true,
                                                        child: Text(
                                                          'common.request_failed'
                                                              .tr,
                                                          textAlign:
                                                              TextAlign.center,
                                                          style: Theme.of(
                                                            context,
                                                          ).textTheme.bodySmall,
                                                        ),
                                                      ),
                                                    ),
                                                ],
                                              ),
                                            ),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        }),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  void _scheduleSubmitMeasurement() {
    if (_submitMeasurementQueued || _stage == _LoginPanelStage.landing) return;
    _submitMeasurementQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _submitMeasurementQueued = false;
      if (!mounted) return;
      final panel = _formPanelKey.currentContext?.findRenderObject();
      final anchor = _submitAnchorKey.currentContext?.findRenderObject();
      if (panel is! RenderBox ||
          anchor is! RenderBox ||
          !panel.hasSize ||
          !anchor.hasSize) {
        return;
      }
      final next = Rect.fromPoints(
        panel.globalToLocal(anchor.localToGlobal(Offset.zero)),
        panel.globalToLocal(
          anchor.localToGlobal(Offset(anchor.size.width, anchor.size.height)),
        ),
      );
      if (next.width <= 0 || next.height <= 0) return;
      _bodyTopGlobal =
          panel.localToGlobal(Offset.zero).dy - _posterHeightForMeasurement;
      if (!controller.busy && !_doorway.canRetryPreparation) {
        _lastIdleSubmitGlobalY = anchor
            .localToGlobal(anchor.size.center(Offset.zero))
            .dy;
      }
      final previous = _submitRect;
      if (previous == null ||
          (previous.left - next.left).abs() > .5 ||
          (previous.top - next.top).abs() > .5 ||
          (previous.width - next.width).abs() > .5 ||
          (previous.height - next.height).abs() > .5) {
        setState(() => _submitRect = next);
      }
    });
  }

  void _openStage(_LoginPanelStage next) {
    setState(() {
      _stage = next;
      _submitRect = null;
    });
    if (next == _LoginPanelStage.landing) {
      _passwordFocusNode.unfocus();
    }
    if (next == _LoginPanelStage.signUp) {
      controller.setSignupMode(true);
    } else if (next == _LoginPanelStage.signIn) {
      controller.setSignupMode(false);
    } else {
      controller.clearTransientMessages();
    }
  }

  Future<void> _submitAuthForm() async {
    FocusScope.of(context).unfocus();
    await controller.submit();
  }

  void _retryDoorwayPreparation() {
    if (!_doorway.canRetryPreparation) return;
    _doorway.retryPreparation();
    _reconcileDoorway();
  }

  void _handleLogoTap() {
    _logoTapCount += 1;
    if (_logoTapCount >= 10) {
      _logoTapCount = 0;
      unawaited(_showEnvironmentDialog());
    }
  }

  Future<void> _showEnvironmentDialog() {
    return showAppGlassDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AppReactiveBuilder(
          () => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'auth.environment'.tr,
                style: TextStyle(
                  fontSize: 20,
                  height: 1.1,
                  fontWeight: FontWeight.w600,
                  color: MaasoGlassTheme.of(context).foregroundPrimary,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 14),
              for (final env in controller.allowedEnvironments)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: _EnvironmentChoiceButton(
                    environment: env,
                    selected: controller.selectedEnvironment.value == env,
                    onTap: () async {
                      await controller.setEnvironment(env);
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    },
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class LoginAvatarViewportPolicy {
  const LoginAvatarViewportPolicy._();

  static AvatarViewportSafeArea of(BuildContext context) {
    final media = MediaQuery.of(context);
    return safeAreaFor(
      size: media.size,
      padding: media.padding,
      viewInsets: media.viewInsets,
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

class _LandingActions extends StatelessWidget {
  const _LandingActions({
    required this.controller,
    required this.onSignUp,
    required this.onSignIn,
    required this.onProviderTap,
  });

  final LoginController controller;
  final VoidCallback onSignUp;
  final VoidCallback onSignIn;
  final ValueChanged<String> onProviderTap;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ImmersiveActionButton(
          label: 'auth.sign_up'.tr,
          icon: Icons.person_add_alt_1_rounded,
          onTap: onSignUp,
          fillColor: ColorConstant.primaryColor,
          foregroundColor: Colors.white,
        ),
        const SizedBox(height: 12),
        _ImmersiveActionButton(
          label: 'auth.sign_in'.tr,
          icon: Icons.login_rounded,
          onTap: onSignIn,
          fillColor: ColorConstant.primaryColor,
          foregroundColor: Colors.white,
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => appNavigation.go(AppRouteCatalog.privacy),
          style: TextButton.styleFrom(
            foregroundColor: MaasoGlassTheme.of(context).foregroundPrimary,
            backgroundColor: MaasoGlassTheme.of(context).surface,
            minimumSize: const Size(48, 48),
          ),
          child: Text(
            Localizations.localeOf(context).languageCode == 'zh'
                ? '隐私与授权'
                : 'Privacy & permissions',
          ),
        ),
        _AuthFeedback(controller: controller),
      ],
    );
  }
}

class _AuthFormPanel extends StatelessWidget {
  const _AuthFormPanel({
    required this.controller,
    required this.stage,
    required this.submitAnchorKey,
    required this.busy,
    required this.progress,
    required this.canRetryPreparation,
    required this.showFallbackButton,
    required this.onRetryPreparation,
    required this.passwordVisible,
    required this.passwordFocusNode,
    required this.onSubmit,
    required this.onTogglePassword,
    required this.onSwitchStage,
  });

  final LoginController controller;
  final _LoginPanelStage stage;
  final GlobalKey submitAnchorKey;
  final bool busy;
  final double progress;
  final bool canRetryPreparation;
  final bool showFallbackButton;
  final VoidCallback onRetryPreparation;
  final bool passwordVisible;
  final FocusNode passwordFocusNode;
  final VoidCallback onSubmit;
  final VoidCallback onTogglePassword;
  final VoidCallback onSwitchStage;

  bool get _signup => stage == _LoginPanelStage.signUp;

  @override
  Widget build(BuildContext context) => AutofillGroup(
    // iOS otherwise presents Save Password when the Login route is retired,
    // covering the final door/camera frame. Existing autofill still works.
    onDisposeAction: AutofillContextAction.cancel,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _formVisibility(
          key: 'login-email-visibility',
          busy: busy,
          progress: progress,
          start: .36,
          child: _ImmersiveAuthField(
            controller: controller.email,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            autofillHints: const [AutofillHints.email],
            hintText: 'auth.email'.tr,
            icon: Icons.mail_outline_rounded,
          ),
        ),
        const SizedBox(height: 12),
        _formVisibility(
          key: 'login-password-visibility',
          busy: busy,
          progress: progress,
          start: .28,
          child: _ImmersiveAuthField(
            controller: controller.password,
            focusNode: passwordFocusNode,
            obscureText: !passwordVisible,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => onSubmit(),
            autofillHints: const [AutofillHints.password],
            hintText: 'auth.password'.tr,
            icon: Icons.lock_outline_rounded,
            suffix: _OpaqueIconButton(
              tooltip: passwordVisible
                  ? 'auth.hide_password'.tr
                  : 'auth.show_password'.tr,
              onTap: onTogglePassword,
              icon: passwordVisible
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
              size: 44,
              iconSize: 20,
            ),
          ),
        ),
        if (_signup) ...[
          const SizedBox(height: 12),
          _formVisibility(
            key: 'login-code-visibility',
            busy: busy,
            progress: progress,
            start: .20,
            child: Row(
              children: [
                Expanded(
                  child: _ImmersiveAuthField(
                    controller: controller.code,
                    keyboardType: TextInputType.number,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => onSubmit(),
                    autofillHints: const [AutofillHints.oneTimeCode],
                    hintText: 'auth.verification_code'.tr,
                    icon: Icons.verified_user_outlined,
                  ),
                ),
                const SizedBox(width: 10),
                AppReactiveBuilder(
                  () => _CompactSendCodeButton(
                    loading: !busy && controller.isSendingCode.value,
                    enabled: !busy && !controller.isSendingCode.value,
                    onTap: controller.sendSignupCode,
                  ),
                ),
              ],
            ),
          ),
        ],
        _formVisibility(
          key: 'login-feedback-visibility',
          busy: busy,
          progress: progress,
          start: .14,
          child: _AuthFeedback(controller: controller),
        ),
        const SizedBox(height: 12),
        SizedBox(
          key: submitAnchorKey,
          height: 56,
          child: showFallbackButton
              ? _ImmersiveActionButton(
                  label: canRetryPreparation
                      ? 'common.retry'.tr
                      : _signup
                      ? 'auth.create_account'.tr
                      : 'auth.log_in'.tr,
                  onTap: canRetryPreparation
                      ? onRetryPreparation
                      : busy
                      ? null
                      : onSubmit,
                  fillColor: Colors.black,
                  foregroundColor: Colors.white,
                  loading: busy && !canRetryPreparation,
                )
              : null,
        ),
        const SizedBox(height: 10),
        _formVisibility(
          key: 'login-switch-visibility',
          busy: busy,
          progress: progress,
          start: .07,
          child: _OpaqueTextButton(
            label: _signup
                ? 'auth.switch_to_login'.tr
                : 'auth.switch_to_signup'.tr,
            onTap: busy ? null : onSwitchStage,
          ),
        ),
        _formVisibility(
          key: 'login-privacy-visibility',
          busy: busy,
          progress: progress,
          start: 0,
          child: TextButton(
            onPressed: busy
                ? null
                : () => appNavigation.go(AppRouteCatalog.privacy),
            child: Text(
              Localizations.localeOf(context).languageCode == 'zh'
                  ? '隐私与授权'
                  : 'Privacy & permissions',
            ),
          ),
        ),
      ],
    ),
  );
}

Widget _formVisibility({
  required String key,
  required bool busy,
  required double progress,
  required double start,
  required Widget child,
}) {
  final opacity = (1 - ((progress - start) / .18).clamp(0.0, 1.0)).toDouble();
  final hidden = busy || opacity < 1;
  return ExcludeSemantics(
    excluding: hidden,
    child: IgnorePointer(
      ignoring: hidden,
      child: Opacity(
        key: ValueKey<String>(key),
        opacity: opacity,
        child: child,
      ),
    ),
  );
}

class _ImmersiveAuthField extends StatelessWidget {
  const _ImmersiveAuthField({
    required this.controller,
    required this.hintText,
    required this.icon,
    this.obscureText = false,
    this.keyboardType,
    this.textInputAction,
    this.focusNode,
    this.onSubmitted,
    this.autofillHints,
    this.suffix,
  });

  final TextEditingController controller;
  final String hintText;
  final IconData icon;
  final bool obscureText;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final FocusNode? focusNode;
  final ValueChanged<String>? onSubmitted;
  final Iterable<String>? autofillHints;
  final Widget? suffix;

  @override
  Widget build(BuildContext context) {
    return AppGlassField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscureText,
      keyboardType: keyboardType,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      autofillHints: autofillHints,
      hintText: hintText,
      prefixIcon: icon,
      suffix: suffix,
      decoration: const InputDecoration(
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
      ),
    );
  }
}

class _ImmersiveActionButton extends StatelessWidget {
  const _ImmersiveActionButton({
    required this.label,
    required this.onTap,
    required this.fillColor,
    required this.foregroundColor,
    this.icon,
    this.loading = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final Color fillColor;
  final Color foregroundColor;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: fillColor,
      disabledBackgroundColor: fillColor,
      foregroundColor: foregroundColor,
      disabledForegroundColor: foregroundColor,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        height: 1.15,
      ),
    );
    final content = loading
        ? Semantics(
            liveRegion: true,
            label: '$label, ${'common.loading'.tr}',
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2.4,
                color: foregroundColor,
              ),
            ),
          )
        : Text(label);
    return SizedBox(
      width: double.infinity,
      height: 56,
      child: icon == null
          ? FilledButton(
              onPressed: loading ? null : onTap,
              style: style,
              child: content,
            )
          : FilledButton.icon(
              onPressed: loading ? null : onTap,
              icon: loading ? const SizedBox.shrink() : Icon(icon),
              label: content,
              style: style,
            ),
    );
  }
}

class _CompactSendCodeButton extends StatelessWidget {
  const _CompactSendCodeButton({
    required this.loading,
    required this.enabled,
    required this.onTap,
  });

  final bool loading;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _RoundIconButton(
      icon: Icons.send_rounded,
      tooltip: 'auth.send_code'.tr,
      onTap: enabled ? onTap : null,
      loading: loading,
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.loading = false,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    if (!loading) {
      return _OpaqueIconButton(
        icon: icon,
        tooltip: tooltip,
        onTap: onTap,
        size: 52,
        iconSize: 22,
      );
    }
    return Container(
      width: 52,
      height: 52,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: MaasoGlassTheme.of(context).surface,
        borderRadius: BorderRadius.circular(16),
      ),
      child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: MaasoGlassTheme.of(context).action,
        ),
      ),
    );
  }
}

class _OpaqueIconButton extends StatelessWidget {
  const _OpaqueIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 52,
    this.iconSize = 22,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    return AppGlassIconButton(
      icon: icon,
      tooltip: tooltip,
      onPressed: onTap,
      size: size,
      iconSize: iconSize,
    );
  }
}

class _OpaqueTextButton extends StatelessWidget {
  const _OpaqueTextButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      style: TextButton.styleFrom(
        foregroundColor: MaasoGlassTheme.of(context).foregroundPrimary,
        minimumSize: const Size(48, 48),
      ),
      child: Text(label),
    );
  }
}

class _EnvironmentChoiceButton extends StatelessWidget {
  const _EnvironmentChoiceButton({
    required this.environment,
    required this.selected,
    required this.onTap,
  });

  final MaasoEnvironment environment;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return AppGlassButton(
      label: switch (environment) {
        MaasoEnvironment.test => 'auth.environment.test'.tr,
        MaasoEnvironment.production => 'auth.environment.production'.tr,
      },
      icon: selected
          ? Icons.radio_button_checked_rounded
          : Icons.radio_button_off_rounded,
      onPressed: onTap,
      primary: selected,
      fullWidth: true,
      minHeight: 52,
    );
  }
}

class _AuthFeedback extends StatelessWidget {
  const _AuthFeedback({required this.controller});

  final LoginController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AppReactiveBuilder(() {
          final error = controller.error.value;
          final notice = controller.notice.value;
          final message = (error == null || error.isEmpty) ? notice : error;
          if (message == null || message.isEmpty) {
            return const SizedBox.shrink();
          }
          final isError = error != null && error.isNotEmpty;
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: DecoratedBox(
              key: const ValueKey<String>('login-feedback-background'),
              decoration: BoxDecoration(
                color: MaasoGlassTheme.of(context).surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      isError
                          ? Icons.error_outline_rounded
                          : Icons.check_circle_outline_rounded,
                      size: 16,
                      color: isError
                          ? ColorConstant.errorColor
                          : ColorConstant.successColor,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        message,
                        style: TextStyle(
                          color: MaasoGlassTheme.of(context).foregroundPrimary,
                          fontSize: 12,
                          height: 1.35,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }),
        LoginCredentialCleanupRetry(controller: controller),
      ],
    );
  }
}

/// Retry affordance kept public so the fault/retry contract can be exercised
/// without booting the Unity-backed login world in widget tests.
class _LoginDoorwayCoverCurve extends Curve {
  const _LoginDoorwayCoverCurve();

  @override
  double transformInternal(double t) => t * t * (3 - 2 * t);
}

class LoginCredentialCleanupRetry extends StatelessWidget {
  const LoginCredentialCleanupRetry({required this.controller, super.key});

  final LoginController controller;

  @override
  Widget build(BuildContext context) {
    return AppReactiveBuilder(() {
      if (!controller.canRetryCredentialCleanup.value) {
        return const SizedBox.shrink();
      }
      final retrying = controller.isRetryingCredentialCleanup.value;
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: KeyedSubtree(
          key: const ValueKey<String>('login-credential-cleanup-retry'),
          child: _ImmersiveActionButton(
            label: 'common.retry'.tr,
            icon: Icons.refresh_rounded,
            onTap: retrying
                ? null
                : () => unawaited(controller.retryCredentialCleanup()),
            fillColor: MaasoGlassTheme.of(context).action,
            foregroundColor: MaasoGlassTheme.of(context).onAction,
            loading: retrying,
          ),
        ),
      );
    });
  }
}

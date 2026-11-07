import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/unity_avatar_view.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/agent/application/avatar/unity_avatar_runtime.dart';

/// Add to the offline MaterialApp so a covered Home hides its native underlay.
final offlineAvatarRouteObserver = RouteObserver<ModalRoute<dynamic>>();

/// Owns only the existing Unity renderer and its renderer-neutral selector.
/// No account, remote catalog, download service, or second renderer is installed.
class OfflineAvatarController extends ChangeNotifier {
  OfflineAvatarController({
    UnityAvatarRuntime? unity,
    ActiveAvatarRuntime? active,
    TargetPlatform? platform,
    bool? isWeb,
    this.readyTimeout = const Duration(seconds: 25),
  }) : _providedUnity = unity,
       _providedActive = active,
       _platform = platform ?? defaultTargetPlatform,
       _isWeb = isWeb ?? kIsWeb {
    if (readyTimeout <= Duration.zero ||
        readyTimeout > const Duration(minutes: 2)) {
      throw ArgumentError('Invalid avatar readiness timeout.');
    }
  }

  // This existing Unity receiver URI restores the scene's bundled model. The
  // offline scene bakes in the redistributable OpenMaaso.vrm asset at build time.
  static const bundledModelUri = 'unity://masso/avatar_agent';

  final UnityAvatarRuntime? _providedUnity;
  final ActiveAvatarRuntime? _providedActive;
  final TargetPlatform _platform;
  final bool _isWeb;
  final Duration readyTimeout;
  UnityAvatarRuntime? _unity;
  ActiveAvatarRuntime? _active;
  bool _ownsUnity = false;
  bool _ownsActive = false;
  bool _installed = false;
  bool _closed = false;
  bool _wantedVisible = false;
  bool _modelLoaded = false;
  int _loadedModelEpoch = -1;
  int _generation = 0;
  int _speechSequence = 0;
  bool _speaking = false;
  Timer? _mouthTimer;
  Future<bool>? _loadFuture;
  Future<void> _visibilityTail = Future<void>.value();
  Worker? _readyWorker;
  Worker? _presentationWorker;
  final Set<Completer<bool>> _readinessWaiters = {};
  String? _error;
  bool _notificationScheduled = false;

  bool get supported =>
      !_isWeb &&
      const {TargetPlatform.iOS, TargetPlatform.android}.contains(_platform);
  AvatarRuntime? get runtime => _active?.current;
  bool get loading => _loadFuture != null && !_closed && _wantedVisible;
  bool get ready =>
      !_closed &&
      _wantedVisible &&
      _modelLoaded &&
      runtime?.modelLoadEpoch == _loadedModelEpoch &&
      runtime?.isReady.value == true &&
      runtime?.presentationReady.value == true;
  String? get error => _error;

  /// Lightweight registration only. Unity starts after the Home view mounts.
  Future<void> install() async {
    if (_installed || _closed) return;
    _installed = true;
    if (!supported) {
      _error = '此平台的离线 Unity 角色尚未就绪；对话和本地作品仍可使用。';
      _notify();
      return;
    }
    final existingUnity = appServices.peek<UnityAvatarRuntime>();
    final existingActive = appServices.peek<ActiveAvatarRuntime>();
    if (existingUnity != null || existingActive != null) {
      // Reusing a renderer installed by an unrelated account runtime could
      // inherit its authority or remote avatar. The standalone path owns both.
      throw StateError(
        'The offline avatar must own a fresh runtime registration.',
      );
    }
    _unity = appServices.put<UnityAvatarRuntime>(
      _providedUnity ?? UnityAvatarRuntime(avatarLoadTimeout: readyTimeout),
    );
    _ownsUnity = true;
    _active = appServices.put<ActiveAvatarRuntime>(
      _providedActive ?? ActiveAvatarRuntime(),
    );
    _ownsActive = true;
    _active!.register(_unity!);
    _readyWorker = _unity!.isReady.listen((value) {
      if (!value) {
        _modelLoaded = false;
        _mouthTimer?.cancel();
      }
      _notify();
      if (value && _wantedVisible && _loadFuture == null && !_closed) {
        scheduleMicrotask(() {
          if (_wantedVisible && !_closed) unawaited(load());
        });
      }
    });
    _presentationWorker = _unity!.presentationReady.listen((_) => _notify());
  }

  Future<bool> load() {
    if (_closed || !supported) return Future.value(false);
    final inFlight = _loadFuture;
    if (inFlight != null) return inFlight;
    _wantedVisible = true;
    final generation = ++_generation;
    final completion = Completer<bool>();
    _loadFuture = completion.future;
    _error = null;
    _notify();
    unawaited(
      _load(generation).then(
        (loaded) {
          if (identical(_loadFuture, completion.future)) _loadFuture = null;
          if (!completion.isCompleted) completion.complete(loaded);
          _notify();
        },
        onError: (Object _, StackTrace _) {
          if (identical(_loadFuture, completion.future)) _loadFuture = null;
          if (!_closed && generation == _generation) {
            _error = '3D 角色未就绪，请确认此构建包含离线 Unity 播放器后重试。';
          }
          if (!completion.isCompleted) completion.complete(false);
          _notify();
        },
      ),
    );
    return completion.future;
  }

  Future<bool> _load(int generation) async {
    if (!_installed) await install();
    final current = runtime;
    if (current == null || !_isCurrent(generation)) return false;
    await _visibility(false, generation);
    await current.resume();
    await current.prepareRenderer();
    if (!await _waitFor(current.isReady, generation)) {
      if (_isCurrent(generation)) {
        _error = 'Unity 播放器未就绪。请使用包含离线角色的构建，或点击重试。';
      }
      return false;
    }
    if (!_isCurrent(generation)) return false;
    await current.loadAvatar(bundledModelUri, const {
      'assetName': 'OpenMaaso',
      'framing': 'front_full_body',
    });
    if (!_isCurrent(generation)) return false;
    _modelLoaded = true;
    _loadedModelEpoch = current.modelLoadEpoch;
    await current.setFraming('front_full_body');
    await current.setWorldFraming(AvatarWorldFraming.heroFullBody);
    await current.setWorldLighting(AvatarWorldLighting.day);
    if (!await _waitFor(current.presentationReady, generation)) {
      if (_isCurrent(generation)) _error = '3D 角色已加载，正在等待原生显示连接；可点击重试。';
      return false;
    }
    if (!_isCurrent(generation)) return false;
    await _visibility(true, generation);
    _error = null;
    return ready;
  }

  bool _isCurrent(int generation) =>
      !_closed && _wantedVisible && generation == _generation;

  Future<bool> _waitFor(RxBool state, int generation) async {
    if (!_isCurrent(generation)) return false;
    if (state.value) return true;
    final completion = Completer<bool>();
    _readinessWaiters.add(completion);
    final observer = state.listen((value) {
      if (value && !completion.isCompleted) {
        completion.complete(_isCurrent(generation));
      }
    });
    try {
      if (state.value && !completion.isCompleted) {
        completion.complete(_isCurrent(generation));
      }
      return await completion.future.timeout(
        readyTimeout,
        onTimeout: () => false,
      );
    } finally {
      observer.dispose();
      _readinessWaiters.remove(completion);
    }
  }

  Future<void> _visibility(bool visible, int generation) {
    final action = _visibilityTail.then((_) async {
      if (visible && !_isCurrent(generation)) return;
      await _active?.setLocalAvatarVisible(visible);
    });
    _visibilityTail = action.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return action;
  }

  Future<void> setVisible(bool visible) async {
    if (_closed) return;
    if (visible) {
      _wantedVisible = true;
      await load();
      return;
    }
    _wantedVisible = false;
    final generation = ++_generation;
    _loadFuture = null;
    for (final waiter in _readinessWaiters.toList()) {
      if (!waiter.isCompleted) waiter.complete(false);
    }
    _notify();
    await speechEnded();
    await _visibility(false, generation);
  }

  /// Called by actual TTS playback callbacks, never by model-authored code.
  Future<void> speechStarted() async {
    if (_closed) return;
    _speaking = true;
    final current = runtime;
    if (ready && current is AvatarConversationPhaseRuntime) {
      await (current as AvatarConversationPhaseRuntime).setConversationPhase(
        'speaking',
        sequence: ++_speechSequence,
      );
    }
  }

  /// A word-progress pulse is a local TTS timing fallback, not phoneme data.
  Future<void> speechProgress() async {
    if (!_speaking || !ready) return;
    _mouthTimer?.cancel();
    await runtime?.setMouthOpen(0.32);
    final generation = _generation;
    _mouthTimer = Timer(const Duration(milliseconds: 100), () {
      if (!_closed && generation == _generation) {
        unawaited(runtime?.setMouthOpen(0) ?? Future<void>.value());
      }
    });
  }

  Future<void> speechEnded() => _closed ? Future<void>.value() : _stopSpeech();

  Future<void> _stopSpeech() async {
    _speaking = false;
    _mouthTimer?.cancel();
    _mouthTimer = null;
    final current = runtime;
    await current?.stopLipSync();
    await current?.setMouthOpen(0);
    if (current is AvatarConversationPhaseRuntime &&
        current!.isReady.value &&
        current.presentationReady.value) {
      await (current as AvatarConversationPhaseRuntime).setConversationPhase(
        'stopped',
        sequence: ++_speechSequence,
      );
    }
  }

  void _notify() {
    if (_closed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      if (_notificationScheduled) return;
      _notificationScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _notificationScheduled = false;
        if (!_closed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _wantedVisible = false;
    final generation = ++_generation;
    _loadFuture = null;
    for (final waiter in _readinessWaiters.toList()) {
      if (!waiter.isCompleted) waiter.complete(false);
    }
    _readyWorker?.dispose();
    _presentationWorker?.dispose();
    _mouthTimer?.cancel();
    await _stopSpeech();
    await _visibility(false, generation);
    if (_ownsActive &&
        identical(appServices.peek<ActiveAvatarRuntime>(), _active)) {
      await appServices.delete<ActiveAvatarRuntime>();
    }
    if (_ownsUnity &&
        identical(appServices.peek<UnityAvatarRuntime>(), _unity)) {
      await appServices.delete<UnityAvatarRuntime>();
    }
  }

  @override
  void dispose() {
    unawaited(close());
    super.dispose();
  }
}

/// Mobile Unity is an existing full-screen native underlay. Its containing
/// Scaffold/background must be transparent while this controller is ready.
class OfflineAvatarView extends StatefulWidget {
  const OfflineAvatarView({
    super.key,
    required this.controller,
    this.active = true,
    this.viewportSafeArea = const AvatarViewportSafeArea(
      top: 0.1,
      bottom: 0.28,
    ),
  });
  final OfflineAvatarController controller;
  final bool active;
  final AvatarViewportSafeArea viewportSafeArea;

  @override
  State<OfflineAvatarView> createState() => _OfflineAvatarViewState();
}

class _OfflineAvatarViewState extends State<OfflineAvatarView>
    with WidgetsBindingObserver, RouteAware {
  ModalRoute<dynamic>? _route;
  bool _routeVisible = true;
  bool _foreground = true;
  bool get _active => widget.active && _routeVisible && _foreground;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_changed);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(widget.controller.setVisible(_active));
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (identical(route, _route)) return;
    offlineAvatarRouteObserver.unsubscribe(this);
    _route = route;
    if (route != null) {
      _routeVisible = route.isCurrent;
      offlineAvatarRouteObserver.subscribe(this, route);
    }
  }

  @override
  void didUpdateWidget(covariant OfflineAvatarView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      unawaited(oldWidget.controller.setVisible(false));
      widget.controller.addListener(_changed);
    }
    if (oldWidget.active != widget.active ||
        oldWidget.controller != widget.controller) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(widget.controller.setVisible(_active));
      });
    }
  }

  @override
  void didPushNext() {
    _routeVisible = false;
    unawaited(widget.controller.setVisible(false));
  }

  @override
  void didPopNext() {
    _routeVisible = true;
    unawaited(widget.controller.setVisible(_active));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    unawaited(widget.controller.setVisible(_active));
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    offlineAvatarRouteObserver.unsubscribe(this);
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_changed);
    unawaited(widget.controller.setVisible(false));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (_active && controller.supported)
          UnityAvatarView(
            backgroundColor: Colors.transparent,
            viewportActive: _active,
            viewportSafeArea: widget.viewportSafeArea,
            showLoadingPlaceholder: false,
          ),
        if (!controller.ready)
          ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final height = constraints.hasBoundedHeight
                    ? constraints.maxHeight
                    : 600.0;
                final safe = widget.viewportSafeArea;
                return Padding(
                  padding: EdgeInsets.fromLTRB(
                    16,
                    height * safe.top.clamp(0.0, 0.45),
                    16,
                    height * safe.bottom.clamp(0.0, 0.45),
                  ),
                  child: LayoutBuilder(
                    builder: (context, content) {
                      final statusHeight = (content.maxHeight * 0.3).clamp(
                        0.0,
                        112.0,
                      );
                      return Column(
                        children: [
                          Expanded(
                            child: Image.asset(
                              'assets/brand/offline_avatar_preview.png',
                              key: const Key('offline-avatar-poster'),
                              fit: BoxFit.contain,
                              semanticLabel: '本地角色全身静态预览',
                              errorBuilder: (_, _, _) => const Center(
                                child: Icon(
                                  Icons.person_outline_rounded,
                                  size: 48,
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: statusHeight,
                            child: SingleChildScrollView(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    controller.loading
                                        ? '静态预览 · 正在准备本地 3D 角色…'
                                        : '静态预览 · ${controller.error ?? '本地 3D 角色尚未就绪'}',
                                    textAlign: TextAlign.center,
                                    style: Theme.of(
                                      context,
                                    ).textTheme.bodySmall,
                                  ),
                                  if (controller.loading) ...[
                                    const SizedBox(height: 8),
                                    const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    ),
                                  ] else if (controller.supported)
                                    TextButton(
                                      onPressed: () =>
                                          unawaited(controller.load()),
                                      child: const Text('重试'),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

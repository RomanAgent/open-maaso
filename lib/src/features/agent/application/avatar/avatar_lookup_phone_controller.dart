import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/turn_trace.dart';
import 'package:maaso/src/features/agent_space/application/agent_space_controller.dart';

import 'avatar_projection_production_authority.dart';
import 'avatar_runtime.dart';

/// Presents an admitted online lookup through the existing phone overlay.
/// This never loads a renderer, waits before a tool runs, or retries a busy pose.
class AvatarLookupPhoneController with WidgetsBindingObserver {
  AvatarLookupPhoneController({
    this.agentId = 'self',
    AvatarRuntime? Function()? runtimeProvider,
    bool Function()? canPresent,
    Listenable? presentationChanges,
    this.minimumPresentationDuration = const Duration(milliseconds: 1600),
    DateTime Function()? now,
  }) : _runtimeProvider =
           runtimeProvider ??
           (() => appServices.peek<ActiveAvatarRuntime>()?.current),
       _usesRegisteredRuntime = runtimeProvider == null,
       _canPresent = canPresent ?? _homeCanPresent,
       _presentationChanges = presentationChanges,
       _now = now ?? DateTime.now {
    if (minimumPresentationDuration.isNegative) {
      throw ArgumentError.value(
        minimumPresentationDuration,
        'minimumPresentationDuration',
      );
    }
  }

  static int _nextInteraction = 0;
  final String agentId;
  final AvatarRuntime? Function() _runtimeProvider;
  final bool _usesRegisteredRuntime;
  final bool Function() _canPresent;
  final Listenable? _presentationChanges;
  final Duration minimumPresentationDuration;
  final DateTime Function() _now;
  final List<Worker> _workers = [];
  final Set<Future<void>> _pending = {};
  final Set<_LookupPhoneOwner> _releasing = {};
  Listenable? _routeChanges;
  _LookupPhoneOwner? _owner;
  bool _observing = false;
  bool _closed = false;

  static bool _homeCanPresent() =>
      Uri.tryParse(appNavigation.currentRoute)?.path == AppRouteCatalog.home &&
      !AvatarProductionOwnership.ownsRenderer &&
      !(appServices.peek<AgentSpaceController>()?.isReturningHome ?? false);

  /// An optional, idempotent release for one handler invocation. Starting the
  /// native animation is deliberately not a dependency of the handler Future.
  void Function()? begin({
    required bool Function() isCurrent,
    Future<void>? cancelled,
  }) {
    try {
      if (_closed || agentId != 'self' || !_allowed(isCurrent)) return null;
      final renderer = _runtimeProvider();
      final registry = _usesRegisteredRuntime
          ? appServices.peek<ActiveAvatarRuntime>()
          : null;
      if (renderer == null ||
          !renderer.isReady.value ||
          !renderer.presentationReady.value ||
          registry?.localAvatarVisible == false) {
        return null;
      }
      cancelCurrent();
      final owner = _LookupPhoneOwner(
        renderer: renderer,
        registry: registry,
        interactionId: 'lookup-${++_nextInteraction}',
        isCurrent: isCurrent,
        startedAt: _now(),
      );
      _owner = owner;
      _watch(owner);
      if (!_current(owner)) {
        _finish(owner);
        return null;
      }
      owner.started = true;
      _track(_start(owner));
      if (cancelled != null) {
        unawaited(
          cancelled.then<void>(
            (_) => _finish(owner),
            onError: (Object _, StackTrace _) => _finish(owner),
          ),
        );
      }
      return () => _completeNormally(owner);
    } on Object {
      // Optional body presentation must never prevent an admitted tool call.
      cancelCurrent();
      return null;
    }
  }

  bool _allowed(bool Function() isCurrent) {
    final state = WidgetsBinding.instance.lifecycleState;
    return !_closed &&
        (state == null || state == AppLifecycleState.resumed) &&
        isCurrent() &&
        _canPresent();
  }

  bool _sameRenderer(_LookupPhoneOwner owner) =>
      identical(_runtimeProvider(), owner.renderer) &&
      owner.renderer.modelLoadEpoch == owner.modelEpoch &&
      owner.renderer.backgroundTaskWorkPresentationEpoch ==
          owner.presentationEpoch &&
      (!_usesRegisteredRuntime ||
          (identical(appServices.peek<ActiveAvatarRuntime>(), owner.registry) &&
              identical(owner.registry?.current, owner.renderer) &&
              owner.registry?.localAvatarVisible != false));

  bool _current(_LookupPhoneOwner owner) =>
      !owner.ended &&
      identical(_owner, owner) &&
      _allowed(() => owner.normalCompletion || owner.isCurrent()) &&
      _sameRenderer(owner) &&
      owner.renderer.isReady.value &&
      owner.renderer.presentationReady.value;

  Future<void> _start(_LookupPhoneOwner owner) async {
    try {
      TurnTrace.event('search.phone.started');
      await owner.renderer.setPhoneInteraction(
        interactionId: owner.interactionId,
        phase: AvatarPhoneInteractionPhase.reading,
      );
      if (!_current(owner)) {
        _finish(owner);
        return;
      }
      await owner.renderer.setPhoneInteraction(
        interactionId: owner.interactionId,
        phase: AvatarPhoneInteractionPhase.replying,
      );
      if (!_current(owner)) _finish(owner);
    } on Object {
      // Busy, unsupported and transport errors all degrade to the same lookup.
      // A stale completion is never permission to replay the pickup.
      _finish(owner);
    }
  }

  void cancelCurrent() {
    final owner = _owner;
    if (owner != null) _finish(owner);
  }

  void _completeNormally(_LookupPhoneOwner owner) {
    if (owner.ended || owner.normalCompletion) return;
    try {
      if (!_current(owner)) {
        _finish(owner);
        return;
      }
      // The handler and answer never wait for this minimum. A completed turn
      // may release its turn guard while this already-admitted pickup finishes;
      // account, renderer, Home, lifecycle and cancellation fences still apply.
      owner.normalCompletion = true;
      final elapsed = _now().difference(owner.startedAt);
      final remaining = minimumPresentationDuration - elapsed;
      if (remaining <= Duration.zero) {
        _finish(owner);
      } else {
        owner.completionTimer = Timer(remaining, () => _finish(owner));
      }
    } on Object {
      _finish(owner);
    }
  }

  /// The desk may retain its job intent while the same actor puts its phone
  /// away. This is only a native presentation gate, never a generation wait.
  bool isReleasingFor(AvatarRuntime renderer) => _releasing.any(
    (owner) => identical(owner.renderer, renderer) && _sameRenderer(owner),
  );

  void _finish(_LookupPhoneOwner owner) {
    if (owner.ended) return;
    owner.ended = true;
    owner.completionTimer?.cancel();
    owner.completionTimer = null;
    if (identical(_owner, owner)) {
      _owner = null;
      _unwatch();
    }
    if (!owner.started) return;
    try {
      // The matching renderer has already removed a phone after model loss.
      // Never dispatch an old account's stop into its replacement renderer.
      if (!_sameRenderer(owner) || !owner.renderer.isReady.value) return;
      _releasing.add(owner);
      _track(
        Future<void>.sync(
              () => owner.renderer.setPhoneInteraction(
                interactionId: owner.interactionId,
                phase: AvatarPhoneInteractionPhase.none,
              ),
            )
            .timeout(const Duration(seconds: 5))
            .whenComplete(() => _releasing.remove(owner)),
      );
      TurnTrace.event('search.phone.ended');
    } on Object {
      // Releasing the decorative overlay cannot alter the tool outcome.
    }
  }

  void _watch(_LookupPhoneOwner owner) {
    WidgetsBinding.instance.addObserver(this);
    _observing = true;
    _workers.add(ever<bool>(owner.renderer.isReady, (_) => _refresh()));
    if (!identical(owner.renderer.presentationReady, owner.renderer.isReady)) {
      _workers.add(
        ever<bool>(owner.renderer.presentationReady, (_) => _refresh()),
      );
    }
    if (owner.registry != null) {
      _workers.add(
        ever<AvatarBackendKind>(owner.registry!.backend, (_) => _refresh()),
      );
      final graph = appProviderContainer.listen<int>(
        appServiceGraphRevisionProvider,
        (_, _) => _refresh(),
      );
      _workers.add(Worker(graph.close));
    }
    _routeChanges =
        _presentationChanges ??
        (appNavigation.isConfigured
            ? appNavigation.router.routerDelegate
            : null);
    _routeChanges?.addListener(_refresh);
  }

  void _refresh() {
    final owner = _owner;
    if (owner == null) return;
    try {
      if (!_current(owner)) _finish(owner);
    } on Object {
      _finish(owner);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) cancelCurrent();
  }

  void _unwatch() {
    for (final worker in _workers) {
      worker.dispose();
    }
    _workers.clear();
    _routeChanges?.removeListener(_refresh);
    _routeChanges = null;
    if (_observing) WidgetsBinding.instance.removeObserver(this);
    _observing = false;
  }

  void _track(Future<void> operation) {
    late final Future<void> tracked;
    tracked = operation
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _pending.remove(tracked));
    _pending.add(tracked);
  }

  Future<void> dispose() async {
    if (!_closed) {
      _closed = true;
      cancelCurrent();
      _unwatch();
    }
    while (_pending.isNotEmpty) {
      await Future.wait<void>(_pending.toList(growable: false));
    }
  }
}

final class _LookupPhoneOwner {
  _LookupPhoneOwner({
    required this.renderer,
    required this.registry,
    required this.interactionId,
    required this.isCurrent,
    required this.startedAt,
  }) : modelEpoch = renderer.modelLoadEpoch,
       presentationEpoch = renderer.backgroundTaskWorkPresentationEpoch;

  final AvatarRuntime renderer;
  final ActiveAvatarRuntime? registry;
  final String interactionId;
  final bool Function() isCurrent;
  final DateTime startedAt;
  final int modelEpoch;
  final int presentationEpoch;
  bool started = false;
  bool ended = false;
  bool normalCompletion = false;
  Timer? completionTimer;
}

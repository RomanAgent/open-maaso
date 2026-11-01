import 'dart:async';

import 'package:flutter/material.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_glass_theme.dart';

typedef ChatWindowPresentationBuilder =
    Widget Function(BuildContext context, Widget child, double opacity);

/// Whether descendants may expose message actions, including overlay entries.
/// An idle fade or modal suppression closes actions before the pixels disappear.
class ChatWindowVisibilityScope extends InheritedWidget {
  const ChatWindowVisibilityScope({
    required this.visible,
    required super.child,
    super.key,
  });

  final bool visible;

  static bool visibleOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<ChatWindowVisibilityScope>()
          ?.visible ??
      true;

  @override
  bool updateShouldNotify(ChatWindowVisibilityScope oldWidget) =>
      visible != oldWidget.visible;
}

/// Fades an idle chat window while preserving its original wake-up hit region.
/// A custom presenter can apply opacity to a native material and Flutter text
/// together without wrapping a platform view in Flutter's opacity layer.
class ChatWindowVisibility extends StatefulWidget {
  const ChatWindowVisibility({
    required this.child,
    this.enabled = true,
    this.keepVisible = false,
    this.suppressed = false,
    this.dismissToken,
    this.resumeAfterSuppression = true,
    this.activityToken,
    this.explicitWakeOnly = false,
    this.onUserInteraction,
    this.idleDuration = const Duration(seconds: 30),
    this.presentationBuilder,
    super.key,
  }) : assert(idleDuration > Duration.zero);

  final Widget child;
  final bool enabled;
  final bool keepVisible;

  /// Modal suppression wins over activity and idle visibility preferences.
  /// Suppressed windows neither draw nor intercept gestures meant for the scene.
  final bool suppressed;

  /// A non-chat control can dismiss the window without becoming wake activity.
  final Object? dismissToken;
  final bool resumeAfterSuppression;
  final Object? activityToken;

  /// In this mode [activityToken] must contain explicit input activity only.
  /// Playback, programmatic scrolling and app resume cannot reveal the window.
  final bool explicitWakeOnly;
  final VoidCallback? onUserInteraction;
  final Duration idleDuration;
  final ChatWindowPresentationBuilder? presentationBuilder;

  @override
  State<ChatWindowVisibility> createState() => _ChatWindowVisibilityState();
}

class _ChatWindowVisibilityState extends State<ChatWindowVisibility>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _opacity;
  Timer? _idleTimer;
  final Set<int> _heldPointers = {};
  bool _visible = true;
  bool _resumed = true;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _visible = !widget.suppressed;
    _opacity = AnimationController(
      vsync: this,
      value: _visible ? 1 : 0,
      duration: MaasoGlassTheme.motionEmphasized,
    );
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    _resumed = lifecycle == null || lifecycle == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    _restartTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    if (_reduceMotion) _opacity.value = _visible ? 1 : 0;
  }

  @override
  void didUpdateWidget(covariant ChatWindowVisibility oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.suppressed) {
      _idleTimer?.cancel();
      _setVisible(false, immediate: true);
      _releaseHiddenPointers();
    } else if (oldWidget.dismissToken != widget.dismissToken ||
        (oldWidget.suppressed &&
            !(oldWidget.resumeAfterSuppression &&
                widget.resumeAfterSuppression))) {
      _idleTimer?.cancel();
      _setVisible(false, immediate: true);
      _releaseHiddenPointers();
    } else if (oldWidget.suppressed ||
        oldWidget.enabled != widget.enabled ||
        oldWidget.activityToken != widget.activityToken) {
      _wake();
    } else if (oldWidget.keepVisible != widget.keepVisible) {
      if (widget.keepVisible) {
        _automaticActivity();
      } else {
        // Finishing playback/thinking is not new interaction. In particular,
        // do not undo a HUD dismissal when an existing task finishes later.
        _restartTimer();
      }
    } else if (oldWidget.idleDuration != widget.idleDuration) {
      _restartTimer();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _resumed = state == AppLifecycleState.resumed;
    _idleTimer?.cancel();
    _heldPointers.clear();
    if (_resumed && widget.resumeAfterSuppression && !widget.explicitWakeOnly) {
      _wake();
    } else {
      _opacity.value = _visible ? 1 : 0;
      if (_resumed) _restartTimer();
    }
  }

  void _restartTimer() {
    _idleTimer?.cancel();
    if (!widget.enabled ||
        widget.suppressed ||
        !mounted ||
        !_resumed ||
        widget.keepVisible ||
        _heldPointers.isNotEmpty ||
        !_visible) {
      return;
    }
    _idleTimer = Timer(widget.idleDuration, () => _setVisible(false));
  }

  void _setVisible(bool visible, {bool immediate = false}) {
    if (!mounted || (visible && widget.suppressed)) return;
    if (_visible == visible && !immediate) return;
    if (_visible != visible) setState(() => _visible = visible);
    if (immediate || _reduceMotion || !_resumed || !widget.enabled) {
      _opacity.stop();
      if (_opacity.value != (visible ? 1 : 0)) {
        _opacity.value = visible ? 1 : 0;
      }
    } else if (_opacity.value != (visible ? 1 : 0)) {
      unawaited(_opacity.animateTo(visible ? 1 : 0, curve: Curves.easeOut));
    } else {
      // A reverse transition can arrive before the old animation's first tick.
      // Its current value already matches, but the old target no longer does.
      _opacity.stop();
    }
  }

  void _releaseHiddenPointers() {
    if (widget.explicitWakeOnly) {
      // IgnorePointer affects new hits only. Cancel existing window gestures
      // so lifting a held finger cannot activate an invisible task/message.
      for (final pointer in _heldPointers) {
        WidgetsBinding.instance.cancelPointer(pointer);
      }
    }
    _heldPointers.clear();
  }

  void _wake() {
    if (widget.suppressed) return;
    _setVisible(true);
    _restartTimer();
  }

  void _automaticActivity() {
    if (!widget.explicitWakeOnly || _visible) _wake();
  }

  void _userInteraction() {
    if (widget.suppressed) return;
    widget.onUserInteraction?.call();
    _wake();
  }

  void _onPointerDown(PointerDownEvent event) {
    _heldPointers.add(event.pointer);
    _idleTimer?.cancel();
    // Hidden taps belong to the wake layer. Do not expose child actions until
    // that first gesture has completed.
    if (_visible) _userInteraction();
  }

  void _onPointerEnd(PointerEvent event) {
    _heldPointers.remove(event.pointer);
    _restartTimer();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification ||
        notification is ScrollUpdateNotification ||
        notification is ScrollEndNotification ||
        notification is OverscrollNotification) {
      _automaticActivity();
    }
    return false;
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _opacity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChatWindowVisibilityScope(
    visible: _visible && !widget.suppressed,
    child: IgnorePointer(
      ignoring: widget.suppressed,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerEnd,
        onPointerCancel: _onPointerEnd,
        onPointerSignal: (_) => _automaticActivity(),
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: AnimatedBuilder(
            animation: _opacity,
            child: widget.child,
            builder: (context, child) {
              final interactive = _visible && _opacity.value > 0;
              final protectedChild = IgnorePointer(
                ignoring: !interactive,
                child: ExcludeFocus(
                  excluding: !interactive,
                  child: ExcludeSemantics(
                    excluding: !interactive,
                    child: child!,
                  ),
                ),
              );
              final presentation =
                  widget.presentationBuilder?.call(
                    context,
                    protectedChild,
                    _opacity.value,
                  ) ??
                  Opacity(opacity: _opacity.value, child: protectedChild);
              return Stack(
                fit: StackFit.passthrough,
                children: [
                  presentation,
                  if (!interactive && !widget.suppressed)
                    Positioned.fill(
                      child: ExcludeSemantics(
                        child: GestureDetector(
                          key: const ValueKey('chat-window-wake-region'),
                          behavior: HitTestBehavior.opaque,
                          onTap: _userInteraction,
                          onPanStart: widget.explicitWakeOnly
                              ? null
                              : (_) => _userInteraction(),
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    ),
  );
}

/// Activity shared by the home composer and its bounded conversation window.
class HomeChatInteraction extends ChangeNotifier {
  HomeChatInteraction() {
    focusNode.addListener(_focusChanged);
  }

  final FocusNode focusNode = FocusNode(debugLabel: 'home-chat-input');
  int _activityToken = 0;
  int get activityToken => _activityToken;
  bool get hasFocus => focusNode.hasFocus || _nativeFocused;
  Object? _composerOwner;
  bool _nativeFocused = false;
  bool _disposed = false;
  double _composerExtent = 124;
  double get composerExtent => _composerExtent;

  void claimComposer(Object owner) {
    if (_disposed || identical(owner, _composerOwner)) {
      return;
    }
    _composerOwner = owner;
    _nativeFocused = false;
  }

  void setNativeInputFocus(Object owner, bool focused) {
    if (_disposed ||
        !identical(owner, _composerOwner) ||
        _nativeFocused == focused) {
      return;
    }
    _nativeFocused = focused;
    if (focused) {
      activity();
    } else {
      notifyListeners();
    }
  }

  void setComposerExtent(Object owner, double extent) {
    if (_disposed ||
        !identical(owner, _composerOwner) ||
        !extent.isFinite ||
        extent <= 0 ||
        (_composerExtent - extent).abs() < .5) {
      return;
    }
    _composerExtent = extent;
    notifyListeners();
  }

  void releaseComposer(Object owner) {
    if (_disposed || !identical(owner, _composerOwner)) {
      return;
    }
    _composerOwner = null;
    _nativeFocused = false;
  }

  final _excludedPointers = <int>{};
  int _dismissToken = 0;
  bool _menuExpanded = false;
  bool _dismissedByHud = false;
  int get dismissToken => _dismissToken;
  bool get menuExpanded => _menuExpanded;
  bool get resumeAfterSuppression => !_menuExpanded && !_dismissedByHud;

  void _focusChanged() {
    if (hasFocus) {
      activity();
    } else {
      // Losing input focus to a menu must not count as a new chat action.
      notifyListeners();
    }
  }

  void pagePointerDown(PointerDownEvent event) {
    if (_excludedPointers.remove(event.pointer)) {
      return;
    }
    dismissForHud();
  }

  void chatPointerDown(
    PointerDownEvent event, {
    required bool wakeOnPointerDown,
  }) {
    _excludedPointers.add(event.pointer);
    if (wakeOnPointerDown) activity(event);
  }

  void dismissForHud([PointerDownEvent? event]) {
    if (event != null) {
      _excludedPointers.add(event.pointer);
    }
    _dismissedByHud = true;
    _dismissToken++;
    notifyListeners();
  }

  void setMenuExpanded(bool expanded) {
    if (_menuExpanded == expanded) {
      return;
    }
    _menuExpanded = expanded;
    dismissForHud();
  }

  void activity([Object? source]) {
    _dismissedByHud = false;
    _activityToken++;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    focusNode.removeListener(_focusChanged);
    focusNode.dispose();
    super.dispose();
  }
}

/// Owns one stable input focus and activity signal for the home route.
class HomeChatInteractionScope extends StatefulWidget {
  const HomeChatInteractionScope({required this.child, super.key});

  final Widget child;

  static HomeChatInteraction? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_HomeChatInteractionInherited>()
      ?.notifier;

  @override
  State<HomeChatInteractionScope> createState() =>
      _HomeChatInteractionScopeState();
}

class _HomeChatInteractionScopeState extends State<HomeChatInteractionScope> {
  final HomeChatInteraction _interaction = HomeChatInteraction();

  @override
  Widget build(BuildContext context) => _HomeChatInteractionInherited(
    notifier: _interaction,
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _interaction.pagePointerDown,
      child: widget.child,
    ),
  );

  @override
  void dispose() {
    _interaction.dispose();
    super.dispose();
  }
}

/// Hit-tested children mark their pointer before the ancestor's page listener.
/// Header controls and the open menu may dismiss chat, but never wake it.
class HomeChatActivityExclusion extends StatelessWidget {
  const HomeChatActivityExclusion({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) =>
        HomeChatInteractionScope.maybeOf(context)?.dismissForHud(event),
    child: child,
  );
}

/// Marks a real chat hit before the page listener sees the same pointer.
/// History defers its wake until the hidden region's first tap has completed.
class HomeChatActivityRegion extends StatelessWidget {
  const HomeChatActivityRegion({
    required this.child,
    this.wakeOnPointerDown = true,
    super.key,
  });

  final Widget child;
  final bool wakeOnPointerDown;

  @override
  Widget build(BuildContext context) => Listener(
    behavior: HitTestBehavior.translucent,
    onPointerDown: (event) => HomeChatInteractionScope.maybeOf(
      context,
    )?.chatPointerDown(event, wakeOnPointerDown: wakeOnPointerDown),
    child: child,
  );
}

class _HomeChatInteractionInherited
    extends InheritedNotifier<HomeChatInteraction> {
  const _HomeChatInteractionInherited({
    required super.notifier,
    required super.child,
  });
}

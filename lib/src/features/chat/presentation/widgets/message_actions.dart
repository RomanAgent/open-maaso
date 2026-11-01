import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_native_frost_group.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/features/chat/data/chat_reply_feedback_store.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';

/// Physical placement of the action menu, independent of message permissions.
enum MessageActionSidePolicy { bySender, left }

/// On-demand actions for the selected message. The overlay does not reserve
/// reading space or pass through the conversation's native mask/text filter.
class MessageActionsAnchor extends StatefulWidget {
  static void dismissActive() =>
      _MessageActionsAnchorState._activeMenu?._hide();
  const MessageActionsAnchor({
    required this.message,
    required this.child,
    this.enabled = true,
    this.sidePolicy = MessageActionSidePolicy.bySender,
    this.onReport,
    super.key,
  });

  final ChatMessage message;
  final Widget child;
  final bool enabled;
  final MessageActionSidePolicy sidePolicy;
  final VoidCallback? onReport;

  @override
  State<MessageActionsAnchor> createState() => _MessageActionsAnchorState();
}

class _MessageActionsAnchorState extends State<MessageActionsAnchor>
    with SingleTickerProviderStateMixin {
  static _MessageActionsAnchorState? _activeMenu;
  final _portal = OverlayPortalController();
  final _focus = FocusNode(debugLabel: 'message-actions');
  late final AnimationController _motion;
  List<double> _motionStarts = const [];
  ScrollPosition? _scroll;
  ChatReplyFeedbackStore? _store;
  ChatReplyFeedbackTarget? _target;
  ChatReplyFeedback? _feedback;
  Timer? _copyTimer;
  Object? _openedIdentity;
  String _openedText = '';
  int _generation = 0;
  bool _open = false;
  bool _readingFeedback = false;
  bool _savingFeedback = false;
  bool _copied = false;
  bool _copyFailed = false;
  bool _hideScheduled = false;
  bool _windowVisible = true;
  bool _closing = false;
  bool _reduceMotion = false;
  bool _surfaceReady = false;
  int _surfaceGeneration = 0;

  @override
  void initState() {
    super.initState();
    _motion =
        AnimationController(vsync: this, duration: MaasoFrostTokens.motionPanel)
          ..addStatusListener((status) {
            if (status == AnimationStatus.completed && _closing) _hide();
          });
  }

  double _itemOpacity(int index) {
    if (!_surfaceReady) return 0;
    if (_reduceMotion) return _closing ? 0 : 1;
    if (index >= _motionStarts.length) return 0;
    final stagger = _motionStarts.length > 4
        ? .42 / (_motionStarts.length - 1)
        : .14;
    final progress = Curves.easeInOut.transform(
      ((_motion.value - index * stagger) / .58).clamp(0.0, 1.0),
    );
    final start = _motionStarts[index];
    return start + ((_closing ? 0.0 : 1.0) - start) * progress;
  }

  void _closeAnimated() {
    if (!_open || _closing) return;
    if (_reduceMotion || !_surfaceReady) {
      _hide();
      return;
    }
    _motionStarts = List.generate(_motionStarts.length, _itemOpacity);
    _generation++;
    _copyTimer?.cancel();
    setState(() => _closing = true);
    // Closing also runs forwards, so both transitions follow reading order.
    _motion.forward(from: 0);
  }

  bool get _isUser =>
      widget.message.isUserMessage || widget.message.senderId == 'user';

  bool get _canReport =>
      !_isUser &&
      widget.message.id != null &&
      widget.message.content.trim().isNotEmpty &&
      widget.onReport != null;

  int get _itemCount => (_isUser ? 2 : 4) + (_canReport ? 1 : 0);

  Object get _identity => (
    widget.message.id,
    widget.message.sessionId,
    widget.message.senderId,
    widget.message.receiverId,
    widget.message.content,
    widget.message.timestamp,
    widget.message.deliveryStatus,
  );

  String _label(String chinese, String english) =>
      Localizations.localeOf(context).languageCode == 'zh' ? chinese : english;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final media = MediaQuery.of(context);
    _reduceMotion = media.disableAnimations || media.accessibleNavigation;
    _windowVisible = ChatWindowVisibilityScope.visibleOf(context);
    if (!_windowVisible || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      _scheduleHide();
    }
  }

  @override
  void didUpdateWidget(MessageActionsAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled ||
        _open &&
            (_openedIdentity != _identity ||
                (oldWidget.onReport == null) != (widget.onReport == null))) {
      _scheduleHide();
    }
  }

  void _scheduleHide() {
    if (!_open || _hideScheduled) return;
    _hideScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _hideScheduled = false;
      if (mounted) _hide();
    });
  }

  void _toggle() {
    if (!widget.enabled || !_windowVisible) return;
    if (_open) {
      _closeAnimated();
      return;
    }
    _activeMenu?._hide();
    _activeMenu = this;
    final generation = ++_generation;
    _openedIdentity = _identity;
    _openedText = widget.message.content;
    _store = _isUser ? null : ChatReplyFeedbackStore.maybeCurrent();
    _target = _store?.capture(widget.message);
    _feedback = null;
    _readingFeedback = _target != null;
    _savingFeedback = false;
    _copied = false;
    _copyFailed = false;
    _scroll = Scrollable.maybeOf(context)?.position;
    _scroll?.addListener(_hide);
    _focus.requestFocus();
    setState(() {
      _open = true;
      _closing = false;
      _surfaceReady = false;
      _surfaceGeneration++;
      _motionStarts = List.filled(_itemCount, 0);
    });
    _motion.value = 0;
    _portal.show();
    if (!AppNativeFrostRegion.available(context)) _onSurfaceReady();
    final target = _target;
    if (target != null) unawaited(_readFeedback(target, generation));
  }

  void _onSurfaceReady() {
    if (!_current(_generation) || _surfaceReady) return;
    setState(() => _surfaceReady = true);
    if (_reduceMotion) {
      _motion.value = 1;
    } else {
      _motion.forward(from: 0);
    }
  }

  bool _current(int generation) =>
      mounted &&
      _open &&
      !_closing &&
      widget.enabled &&
      _windowVisible &&
      _openedIdentity == _identity &&
      generation == _generation;

  Future<void> _readFeedback(
    ChatReplyFeedbackTarget target,
    int generation,
  ) async {
    try {
      final feedback = await _store!.read(target);
      if (_current(generation)) setState(() => _feedback = feedback);
    } catch (_) {
      if (_current(generation)) setState(() => _target = null);
    } finally {
      if (_current(generation)) setState(() => _readingFeedback = false);
    }
  }

  Future<void> _rate(ChatReplyFeedback choice) async {
    final store = _store;
    final target = _target;
    if (!_current(_generation) ||
        store == null ||
        target == null ||
        _savingFeedback) {
      return;
    }
    final generation = _generation;
    setState(() => _savingFeedback = true);
    try {
      final feedback = await store.toggle(target, choice);
      if (_current(generation)) setState(() => _feedback = feedback);
    } catch (_) {
      if (_current(generation)) setState(() => _target = null);
    } finally {
      if (_current(generation)) setState(() => _savingFeedback = false);
    }
  }

  void _report() {
    if (!_current(_generation) || !_canReport) return;
    final report = widget.onReport!;
    _hide();
    report();
  }

  Future<void> _copy() async {
    if (!_current(_generation)) return;
    final generation = _generation;
    final text = _openedText;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (!_current(generation)) return;
      setState(() {
        _copied = true;
        _copyFailed = false;
      });
      _copyTimer?.cancel();
      _copyTimer = Timer(const Duration(seconds: 2), () {
        if (_current(generation)) setState(() => _copied = false);
      });
    } catch (_) {
      if (_current(generation)) setState(() => _copyFailed = true);
    }
  }

  void _hide() {
    if (!_open) return;
    _generation++;
    _motion.stop();
    _copyTimer?.cancel();
    _scroll?.removeListener(_hide);
    _scroll = null;
    _portal.hide();
    if (identical(_activeMenu, this)) _activeMenu = null;
    if (mounted) {
      setState(() {
        _open = false;
        _closing = false;
      });
    }
  }

  @override
  void dispose() {
    _generation++;
    _copyTimer?.cancel();
    _scroll?.removeListener(_hide);
    if (identical(_activeMenu, this)) _activeMenu = null;
    _motion.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TapRegion(
    groupId: this,
    onTapOutside: (_) => _hide(),
    child: FocusableActionDetector(
      enabled: widget.enabled,
      focusNode: _focus,
      mouseCursor: widget.enabled
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      onFocusChange: (focused) {
        if (!focused) _hide();
      },
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _toggle();
            return null;
          },
        ),
        DismissIntent: CallbackAction<DismissIntent>(
          onInvoke: (_) {
            _hide();
            return null;
          },
        ),
      },
      child: OverlayPortal.overlayChildLayoutBuilder(
        controller: _portal,
        overlayChildBuilder: _buildActions,
        child: Semantics(
          button: widget.enabled,
          expanded: widget.enabled ? _open && !_closing : null,
          onTap: widget.enabled ? _toggle : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            excludeFromSemantics: true,
            onTap: widget.enabled ? _toggle : null,
            child: widget.child,
          ),
        ),
      ),
    ),
  );

  Widget _buildActions(BuildContext context, OverlayChildLayoutInfo layout) {
    if (!_windowVisible ||
        !widget.enabled ||
        _openedIdentity != _identity ||
        !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return const SizedBox.shrink();
    }
    final rect = MatrixUtils.transformRect(
      layout.childPaintTransform,
      Offset.zero & layout.childSize,
    );
    final media = MediaQuery.of(context);
    final view = View.of(context);
    final bottom = math.max(
      media.viewInsets.bottom,
      view.viewInsets.bottom / view.devicePixelRatio,
    );
    final safe = Rect.fromLTRB(
      media.padding.left + 8,
      media.padding.top + 8,
      layout.overlaySize.width - media.padding.right - 8,
      layout.overlaySize.height - math.max(media.padding.bottom, bottom) - 8,
    );
    if (safe.isEmpty) return const SizedBox.shrink();
    final clockWidth = math.max(24.0, media.textScaler.scale(5.5) * 3 + 8);
    final actionCount = _itemCount - 1;
    final width = math.min(safe.width, clockWidth);
    final opensLeft =
        widget.sidePolicy == MessageActionSidePolicy.left || _isUser;
    final sideSpace = opensLeft
        ? rect.left - safe.left
        : safe.right - rect.right;
    final beside = sideSpace >= width + 8;
    final height = math.min(
      safe.height,
      actionCount * 24 + media.textScaler.scale(5.5) * 1.3 + 8,
    );
    final besideLeft = opensLeft ? rect.left - width - 8 : rect.right + 8;
    final fallbackLeft = opensLeft ? rect.left : rect.right - width;
    final left = (beside ? besideLeft : fallbackLeft).clamp(
      safe.left,
      safe.right - width,
    );
    final top =
        (beside
                ? rect.center.dy - height / 2
                : rect.bottom + height + 8 <= safe.bottom
                ? rect.bottom + 8
                : rect.top - height - 8)
            .clamp(safe.top, safe.bottom - height);
    final glass = MaasoGlassTheme.of(context);
    final native = AppNativeFrostRegion.available(context);
    final buttonStyle = IconButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size.square(24),
      maximumSize: const Size.square(24),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: VisualDensity.standard,
    );
    final canRate =
        _target != null &&
        _store?.isCurrent == true &&
        !_readingFeedback &&
        !_savingFeedback;
    Widget rating(
      ChatReplyFeedback choice,
      IconData icon,
      IconData selectedIcon,
      String label,
    ) => IconButton(
      key: ValueKey('message-feedback-${choice.name}'),
      tooltip: canRate || _readingFeedback || _savingFeedback
          ? label
          : '$label · ${_label('暂不可评价', 'Rating unavailable')}',
      isSelected: _feedback == choice,
      onPressed: canRate ? () => unawaited(_rate(choice)) : null,
      icon: Icon(icon, size: 10),
      selectedIcon: Icon(selectedIcon, size: 10, color: glass.accentText),
      style: buttonStyle,
      constraints: const BoxConstraints.tightFor(width: 24, height: 24),
    );
    final local = widget.message.timestamp.toLocal();
    final time =
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    final items = <Widget>[
      if (!_isUser) ...[
        rating(
          ChatReplyFeedback.excellent,
          Icons.thumb_up_outlined,
          Icons.thumb_up_rounded,
          _label('回复优秀', 'Good response'),
        ),
        rating(
          ChatReplyFeedback.poor,
          Icons.thumb_down_outlined,
          Icons.thumb_down_rounded,
          _label('回复不佳', 'Poor response'),
        ),
      ],
      IconButton(
        key: const ValueKey('message-copy-action'),
        tooltip: _copyFailed
            ? _label('复制失败，请重试', 'Copy failed. Try again')
            : _copied
            ? _label('已复制', 'Copied')
            : _label('复制', 'Copy'),
        onPressed: () => unawaited(_copy()),
        icon: Icon(
          _copyFailed
              ? Icons.error_outline
              : _copied
              ? Icons.check_rounded
              : Icons.copy_outlined,
          size: 10,
        ),
        style: buttonStyle,
        constraints: const BoxConstraints.tightFor(width: 24, height: 24),
      ),
      if (_canReport)
        IconButton(
          key: const ValueKey('message-report-action'),
          tooltip: _label('举报此回复', 'Report response'),
          onPressed: _report,
          icon: const Icon(Icons.flag_outlined, size: 10),
          style: buttonStyle,
          constraints: const BoxConstraints.tightFor(width: 24, height: 24),
        ),
      SizedBox(
        width: clockWidth,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Tooltip(
            message:
                '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} $time',
            child: Text(
              time,
              key: const ValueKey('message-action-time'),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 5.5,
                height: 1.3,
                color: glass.foregroundSecondary,
              ),
            ),
          ),
        ),
      ),
    ];
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: TapRegion(
        groupId: this,
        child: FocusTraversalGroup(
          child: AnimatedBuilder(
            animation: _motion,
            builder: (context, _) {
              final opacities = List.generate(items.length, _itemOpacity);
              final opacity = opacities.reduce(math.max);
              return _MessageActionSurface(
                key: const ValueKey('message-action-menu'),
                native: native,
                opacity: opacity,
                onReady: _onSurfaceReady,
                generation: _surfaceGeneration,
                child: IgnorePointer(
                  ignoring: _closing || !_surfaceReady,
                  child: ExcludeFocus(
                    excluding: _closing || !_surfaceReady,
                    child: Material(
                      color: Colors.transparent,
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var index = 0; index < items.length; index++)
                              Opacity(
                                key: ValueKey('message-action-opacity-$index'),
                                opacity: opacity == 0
                                    ? 0
                                    : opacities[index] / opacity,
                                child: Transform.translate(
                                  offset: Offset(
                                    0,
                                    -3 * (1 - opacities[index]),
                                  ),
                                  child: items[index],
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// A separate, bounded sampler for the open menu. Its mask never joins the
/// conversation mask; there is one native view for the whole menu.
class _MessageActionSurface extends StatelessWidget {
  const _MessageActionSurface({
    required this.native,
    required this.opacity,
    required this.onReady,
    required this.generation,
    required this.child,
    super.key,
  });

  final bool native;
  final double opacity;
  final VoidCallback onReady;
  final int generation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final fill = glass.surface.withValues(
      alpha: MaasoFrostTokens.messageFillAlpha,
    );
    return AppNativeFrostGroup(
      key: ValueKey(('message-action-frost', generation)),
      enabled: native,
      opacity: opacity,
      deferRevealUntilReady: true,
      onReady: onReady,
      topFadeHeight: 0,
      bottomFadeHeight: 0,
      child: Builder(
        builder: (context) => AppNativeFrostRegion.available(context)
            ? AppNativeFrostRegion(
                radius: MaasoFrostTokens.messageRadius,
                child: child,
              )
            : AppGlassSurface(
                role: AppGlassSurfaceRole.message,
                tintColor: fill,
                cornerRadius: MaasoFrostTokens.messageRadius,
                child: child,
              ),
      ),
    );
  }
}

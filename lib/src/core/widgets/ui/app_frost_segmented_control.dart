import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

@immutable
class AppFrostSegment<T> {
  const AppFrostSegment({
    required this.value,
    required this.label,
    this.key,
    this.icon,
    this.enabled = true,
  });

  final T value;
  final String label;
  final Key? key;
  final IconData? icon;
  final bool enabled;
}

/// One borderless frosted rail, with a 48 dp target for each choice.
/// Long translations and large text reflow into a vertical radio group.
class AppFrostSegmentedControl<T> extends StatefulWidget {
  const AppFrostSegmentedControl({
    required this.segments,
    required this.selected,
    required this.onSelected,
    this.blur = false,
    super.key,
  }) : assert(segments.length >= 2);

  final List<AppFrostSegment<T>> segments;
  final T selected;
  final ValueChanged<T>? onSelected;

  /// Enable only for bounded, fixed chrome. Repeated list controls stay matte.
  final bool blur;

  @override
  State<AppFrostSegmentedControl<T>> createState() =>
      _AppFrostSegmentedControlState<T>();
}

class _AppFrostSegmentedControlState<T>
    extends State<AppFrostSegmentedControl<T>> {
  final Map<T, FocusNode> _focusNodes = <T, FocusNode>{};

  @override
  void didUpdateWidget(covariant AppFrostSegmentedControl<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    final values = widget.segments.map((segment) => segment.value).toSet();
    for (final value in _focusNodes.keys.toList()) {
      if (!values.contains(value)) _focusNodes.remove(value)!.dispose();
    }
  }

  @override
  void dispose() {
    for (final node in _focusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  void _move(int from, int delta) {
    if (widget.onSelected == null) return;
    for (var step = 1; step <= widget.segments.length; step++) {
      final index = (from + delta * step) % widget.segments.length;
      final segment = widget.segments[index];
      if (!segment.enabled) continue;
      _focusNodes[segment.value]?.requestFocus();
      widget.onSelected!(segment.value);
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final reducedMotion =
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    final labelStyle = Theme.of(context).textTheme.labelLarge!.copyWith(
      fontSize: 15,
      height: 20 / 15,
      fontWeight: FontWeight.w500,
    );
    final widths = widget.segments.map((segment) {
      final painter = TextPainter(
        text: TextSpan(text: segment.label, style: labelStyle),
        textDirection: direction,
        textScaler: scaler,
      )..layout();
      final width = painter.width + 24 + (segment.icon == null ? 0 : 26);
      painter.dispose();
      return width.clamp(48.0, double.infinity);
    }).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth - 8;
        final total = widths.fold<double>(0, (sum, width) => sum + width);
        final vertical = constraints.hasBoundedWidth && total > available;
        final equalWidth = widths.every(
          (width) => width * widths.length <= available,
        );
        final buttons = <Widget>[];
        for (var index = 0; index < widget.segments.length; index++) {
          final segment = widget.segments[index];
          final selected = segment.value == widget.selected;
          final enabled = segment.enabled && widget.onSelected != null;
          final node = _focusNodes.putIfAbsent(segment.value, FocusNode.new);
          final forward = direction == TextDirection.rtl ? -1 : 1;
          final button = CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.arrowRight): () =>
                  _move(index, forward),
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () =>
                  _move(index, -forward),
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  _move(index, 1),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  _move(index, -1),
            },
            child: Semantics(
              key: segment.key,
              label: segment.label,
              button: true,
              enabled: enabled,
              excludeSemantics: true,
              onTap: enabled ? () => widget.onSelected!(segment.value) : null,
              selected: selected,
              inMutuallyExclusiveGroup: true,
              // Selection is exclusive even during a transition. Fading each
              // segment independently leaves two selected capsules on screen.
              child: DecoratedBox(
                key: selected
                    ? const ValueKey('app-frost-selected-indicator')
                    : null,
                decoration: BoxDecoration(
                  color: selected ? glass.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(
                    MaasoGlassTheme.capsuleRadius,
                  ),
                  boxShadow: selected
                      ? <BoxShadow>[
                          BoxShadow(
                            color: glass.shadow,
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ]
                      : null,
                ),
                child: TextButton(
                  focusNode: node,
                  onPressed: enabled
                      ? () => widget.onSelected!(segment.value)
                      : null,
                  style:
                      TextButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        overlayColor: Colors.transparent,
                        foregroundColor: selected
                            ? glass.accentText
                            : glass.foregroundSecondary,
                        disabledForegroundColor: glass.foregroundSecondary
                            .withValues(alpha: 0.55),
                        minimumSize: const Size(48, 48),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        textStyle: labelStyle,
                        shape: const StadiumBorder(),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ).copyWith(
                        animationDuration: reducedMotion
                            ? Duration.zero
                            : MaasoGlassTheme.motionFast,
                        side: WidgetStateProperty.resolveWith((states) {
                          return states.contains(WidgetState.focused) &&
                                  FocusManager.instance.highlightMode ==
                                      FocusHighlightMode.traditional
                              ? BorderSide(color: glass.accentText, width: 1.5)
                              : BorderSide.none;
                        }),
                      ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (segment.icon != null) ...<Widget>[
                        Icon(segment.icon, size: 18),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Text(segment.label, textAlign: TextAlign.center),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          buttons.add(
            vertical || !constraints.hasBoundedWidth
                ? button
                : Expanded(
                    flex: equalWidth ? 1 : widths[index].ceil(),
                    child: button,
                  ),
          );
        }
        return AppGlassSurface(
          role: AppGlassSurfaceRole.control,
          blur: widget.blur,
          tintColor: glass.muted.withValues(alpha: 0.84),
          padding: const EdgeInsets.all(4),
          cornerRadius: vertical ? 28 : MaasoGlassTheme.capsuleRadius,
          child: vertical
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: buttons,
                )
              : Row(mainAxisSize: MainAxisSize.min, children: buttons),
        );
      },
    );
  }
}

/// Keeps the existing TabBarView, swipe gesture and controller in sync.
class AppFrostTabBar extends StatelessWidget {
  const AppFrostTabBar({
    required this.labels,
    this.controller,
    this.blur = false,
    super.key,
  });

  final List<String> labels;
  final TabController? controller;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final tabs = controller ?? DefaultTabController.of(context);
    assert(tabs.length == labels.length);
    return ListenableBuilder(
      listenable: tabs,
      builder: (context, _) => AppFrostSegmentedControl<int>(
        selected: tabs.index,
        blur: blur,
        segments: <AppFrostSegment<int>>[
          for (var index = 0; index < labels.length; index++)
            AppFrostSegment(value: index, label: labels[index]),
        ],
        onSelected: (index) => tabs.animateTo(
          index,
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : MaasoGlassTheme.motionStandard,
        ),
      ),
    );
  }
}

/// Optional hub navigation stays below the destination's existing page header.
class AppFrostSectionHeader extends StatelessWidget {
  const AppFrostSectionHeader({
    required this.header,
    this.navigation,
    super.key,
  });

  final Widget header;
  final Widget? navigation;

  @override
  Widget build(BuildContext context) {
    if (navigation == null) return header;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[header, navigation!],
    );
    final media = MediaQuery.of(context);
    if (media.size.height <= 0 ||
        media.size.height >= 480 ||
        media.textScaler.scale(1) < 1.5) {
      return content;
    }
    // Large text on short displays must leave room for the active page body.
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.55,
      ),
      child: SingleChildScrollView(child: content),
    );
  }
}

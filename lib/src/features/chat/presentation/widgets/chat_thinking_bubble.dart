import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';

/// Presentation-only turn status: it never creates a persisted chat message.
class ChatThinkingBubble extends StatefulWidget {
  const ChatThinkingBubble({
    this.thinking = true,
    this.thought,
    this.onDismissThought,
    super.key,
  });

  final bool thinking;
  final String? thought;
  final VoidCallback? onDismissThought;

  @override
  State<ChatThinkingBubble> createState() => _ChatThinkingBubbleState();
}

class _ChatThinkingBubbleState extends State<ChatThinkingBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(ChatThinkingBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnimation();
  }

  void _syncAnimation() {
    if (!widget.thinking ||
        MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context) ||
        !TickerMode.valuesOf(context).enabled) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final thought = widget.thought?.trim() ?? '';
    final glass = MaasoGlassTheme.of(context);
    return Semantics(
      container: true,
      liveRegion: true,
      label: widget.thinking ? 'chat.thinking'.tr : null,
      child: MessageFrostSurface(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.thinking)
              ExcludeSemantics(
                child: AnimatedBuilder(
                  animation: _pulse,
                  builder: (context, _) => Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(3, (index) {
                      final wave = math.sin(
                        _pulse.value * math.pi * 2 - index * .8,
                      );
                      return Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Opacity(
                          opacity: .6 + .4 * (wave + 1) / 2,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: glass.brightness == Brightness.dark
                                  ? MaasoFrostTokens.onAction
                                  : MaasoFrostTokens.composerAction,
                              shape: BoxShape.circle,
                            ),
                            child: const SizedBox.square(dimension: 5),
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            if (thought.isNotEmpty) ...[
              if (widget.thinking) const SizedBox(height: 8),
              Text(
                thought,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: messageSecondaryForeground(glass),
                ),
              ),
              if (widget.onDismissThought != null)
                Align(
                  alignment: Alignment.centerRight,
                  heightFactor: 1,
                  child: IconButton(
                    key: const ValueKey('chat-dismiss-thought'),
                    tooltip: 'home.dismiss_thought'.tr,
                    onPressed: widget.onDismissThought,
                    constraints: const BoxConstraints.tightFor(
                      width: 48,
                      height: 48,
                    ),
                    icon: const Icon(Icons.close_rounded, size: 18),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

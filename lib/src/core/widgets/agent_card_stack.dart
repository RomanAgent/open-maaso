import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_card_controller.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/core/widgets/agent_loading_card.dart';
import 'package:maaso/src/core/widgets/ui/app_card.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';

/// Renders the currently-visible [AgentCard] above the chat input.
///
/// Layout rules (per product spec):
/// * Pinned to the **bottom half** of the screen at most — never crowds out
///   the avatar.
/// * Body scrolls internally when content overflows.
/// * Animated slide-up/fade on push, slide-down/fade on dismiss.
/// * Footer renders back / skip / next slots only when their handlers are
///   provided — no greyed-out ghost buttons.
///
/// The stack listens to [AgentCardController.cards] and re-renders the
/// head of the queue.  Multi-card flows are driven by handlers swapping
/// cards in/out — the stack stays dumb.
class AgentCardStack extends StatelessWidget {
  /// Bottom inset to clear the chat input bar.  Pass the same value the
  /// chat bar uses so we sit just above it.
  final double bottomInset;

  /// Whether to repeat the latest reply above the composer.
  ///
  /// Desktop Home already renders persistent chat history, so its caller
  /// disables this while retaining loading and action cards.
  final bool showLatestReply;

  const AgentCardStack({
    super.key,
    required this.bottomInset,
    this.showLatestReply = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!appServices.isRegistered<AgentCardController>()) {
      return const SizedBox.shrink();
    }
    final controller = appServices.find<AgentCardController>();
    final maxHeight = MediaQuery.of(context).size.height * 0.5;

    return Padding(
      padding: EdgeInsets.fromLTRB(12, 0, 12, bottomInset),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SingleChildScrollView(
          reverse: true,
          physics: const BouncingScrollPhysics(),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Latest agent reply — voice-first UI used to hide this, but
              // when TTS fails or the cloud brain emits an error string
              // ("API key not configured", error trace) the user sees
              // nothing.  Surface it as a soft bubble at the top of the
              // stack so chat replies are always visible.
              if (showLatestReply) const _LatestReplyBubble(),
              // System status — model download cards.  Always above the
              // action card so users see boot state even while a confirm
              // card is in front of them.
              const AgentLoadingCards(),
              const SizedBox(height: 8),
              // Action queue — the single user-facing card the agent is
              // currently asking the user about.
              AppReactiveBuilder(() {
                final card = controller.current;
                return AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, anim) {
                    return FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: Tween(
                          begin: const Offset(0, 0.2),
                          end: Offset.zero,
                        ).animate(anim),
                        child: child,
                      ),
                    );
                  },
                  child: card == null
                      ? const SizedBox.shrink(key: ValueKey('empty'))
                      : _CardShell(key: ValueKey(card.id), card: card),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardShell extends StatelessWidget {
  final AgentCard card;
  const _CardShell({super.key, required this.card});

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    return AppCard(
      borderRadius: BorderRadius.circular(20),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (card.title != null) ...[
            Text(
              card.title!.tr,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: glass.foregroundPrimary,
              ),
            ),
            const SizedBox(height: 10),
          ],
          Flexible(
            child: SingleChildScrollView(
              physics: const BouncingScrollPhysics(),
              child: Builder(builder: card.builder),
            ),
          ),
          if (_hasAnyAction(card.actions)) ...[
            const SizedBox(height: 14),
            _CardFooter(actions: card.actions),
          ],
        ],
      ),
    );
  }

  bool _hasAnyAction(AgentCardActions a) => a.hasBack || a.hasSkip || a.hasNext;
}

class _CardFooter extends StatelessWidget {
  final AgentCardActions actions;
  const _CardFooter({required this.actions});

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];
    if (actions.hasBack) {
      children.add(
        _FooterButton(
          label: actions.backLabel!,
          onTap: actions.onBack!,
          primary: false,
        ),
      );
    }
    if (actions.hasSkip) {
      if (children.isNotEmpty) children.add(const SizedBox(width: 8));
      children.add(
        _FooterButton(
          label: actions.skipLabel!,
          onTap: actions.onSkip!,
          primary: false,
        ),
      );
    }
    // The next/confirm button gets the right edge; spacer pushes it out
    // when other buttons are present.
    if (actions.hasNext) {
      if (children.isNotEmpty) children.add(const Spacer());
      children.add(
        _FooterButton(
          label: actions.nextLabel!,
          onTap: actions.onNext!,
          primary: true,
        ),
      );
    }
    return Row(children: children);
  }
}

/// Soft chat bubble that renders the most recent agent reply text.
///
/// Reads [HomeController.latestBubble] — anything that updates that
/// observable surfaces here (cloud-brain reply, fallback error, boot
/// announcements, name-flow prompts).  Tap to dismiss.
class _LatestReplyBubble extends StatelessWidget {
  const _LatestReplyBubble();

  @override
  Widget build(BuildContext context) {
    if (!appServices.isRegistered<HomeController>()) {
      return const SizedBox.shrink();
    }
    final controller = appServices.find<HomeController>();
    return AppReactiveBuilder(() {
      final text = controller.latestBubble.value;
      if (text == null || text.isEmpty) return const SizedBox.shrink();
      final glass = MaasoGlassTheme.of(context);
      return Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Semantics(
          button: true,
          label: 'chat.dismiss_latest_reply'.tr,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: controller.dismissLatestReply,
            child: AppGlassSurface(
              role: AppGlassSurfaceRole.chrome,
              behavior: AppGlassSurfaceBehavior.staticSurface,
              cornerRadius: 18,
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.4,
                  color: glass.foregroundPrimary,
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _FooterButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final bool primary;

  const _FooterButton({
    required this.label,
    required this.onTap,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final bg = primary ? ColorConstant.primaryColor : Colors.transparent;
    final fg = primary ? Colors.white : glass.foregroundPrimary;
    return Material(
      color: bg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: primary ? BorderSide.none : BorderSide(color: glass.staticBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
          child: Text(
            label.tr,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}

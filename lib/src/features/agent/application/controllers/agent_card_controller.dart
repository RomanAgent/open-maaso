import 'package:flutter/widgets.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

/// One row of buttons on the card footer.  Any slot can be null to hide
/// that button entirely.  Labels are pre-localized strings owned by the
/// caller — the controller doesn't translate.
class AgentCardActions {
  final String? backLabel;
  final VoidCallback? onBack;
  final String? skipLabel;
  final VoidCallback? onSkip;
  final String? nextLabel;
  final VoidCallback? onNext;

  const AgentCardActions({
    this.backLabel,
    this.onBack,
    this.skipLabel,
    this.onSkip,
    this.nextLabel,
    this.onNext,
  });

  bool get hasBack => backLabel != null && onBack != null;
  bool get hasSkip => skipLabel != null && onSkip != null;
  bool get hasNext => nextLabel != null && onNext != null;
}

/// Declarative description of one agent-pushed floating card.
///
/// [type] is the discriminator that determines what UI [build] returns — kept
/// as a string (not enum) so the cloud brain can emit it via tool-call JSON
/// without binding to a Dart enum on the wire.
class AgentCard {
  final String id;
  final String type;
  final String? title;
  final Map<String, dynamic> props;

  /// How the card renders its body.  Footer buttons come from [actions] and
  /// are rendered by the stack — don't duplicate them here.
  final WidgetBuilder builder;

  /// Footer button row.  If every slot is null/empty the footer is omitted.
  final AgentCardActions actions;

  AgentCard({
    String? id,
    required this.type,
    required this.builder,
    this.title,
    this.props = const {},
    this.actions = const AgentCardActions(),
  }) : id = id ?? 'card_${DateTime.now().microsecondsSinceEpoch}';
}

/// Floating-card queue manager.
///
/// Mental model — Claude Code's approval flow.  Agent pushes cards via
/// [push]; only the [current] one is visible at any time, sitting just
/// above the chat input.  The user advances/retreats/dismisses with the
/// footer buttons rendered by [AgentCardStack].
///
/// Lifetime: registered globally in [main.dart].  Multiple pushers (boot
/// controller, agent skills, slash commands) share the same queue.
class AgentCardController extends AppController {
  /// Pending queue.  Index 0 is the visible card.  We don't render multiple
  /// at once — the stack reads `cards.first`.
  final RxList<AgentCard> cards = <AgentCard>[].obs;

  AgentCard? get current => cards.isEmpty ? null : cards.first;
  bool get hasCards => cards.isNotEmpty;

  void push(AgentCard card) {
    cards.add(card);
  }

  /// Replace the current card without changing the queue length — useful for
  /// multi-step flows where step N's "next" handler swaps in step N+1.
  void replaceCurrent(AgentCard card) {
    if (cards.isEmpty) {
      cards.add(card);
    } else {
      cards[0] = card;
    }
  }

  /// Pop the current card.  Caller wires this into the footer's `next`/`skip`
  /// handlers after their own work is done.
  void dismissCurrent() {
    if (cards.isNotEmpty) cards.removeAt(0);
  }

  void dismissById(String id) {
    cards.removeWhere((c) => c.id == id);
  }

  void clear() => cards.clear();
}

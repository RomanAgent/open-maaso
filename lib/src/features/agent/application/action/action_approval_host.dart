import 'action_approval_service.dart';
import 'action_definition.dart';

/// One bounded, display-only argument binding shown to the owner.
final class ActionApprovalPresentationField {
  const ActionApprovalPresentationField({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;
}

/// Bounded display-only content for an approval prompt.
final class ActionApprovalPresentation {
  const ActionApprovalPresentation({
    required this.title,
    required this.description,
    required this.targetLabel,
    required this.consequenceLabel,
    required this.exactText,
    this.argumentFields = const <ActionApprovalPresentationField>[],
  });

  final String title;
  final String description;
  final String targetLabel;
  final String consequenceLabel;
  final String? exactText;
  final List<ActionApprovalPresentationField> argumentFields;
}

/// Immutable presentation request for one exact, already-pending approval.
///
/// Raw action arguments, account identifiers, and opaque approval targets are
/// deliberately absent. Identity and authority stay in the caller-owned
/// [ActionApprovalService].
final class ActionApprovalPrompt {
  const ActionApprovalPrompt({
    required this.fingerprint,
    required this.actionId,
    required this.expiresAt,
    required this.presentation,
    required this.risk,
    required this.consequencePolicy,
  });

  final String fingerprint;
  final String actionId;
  final DateTime expiresAt;
  final ActionApprovalPresentation presentation;
  final ActionRisk risk;
  final ActionConsequencePolicy consequencePolicy;
}

/// Stable reason for withdrawing an already-visible approval prompt.
enum ActionApprovalCancellationReason {
  authorityStale('approval.stale'),
  expired('approval.timeout'),
  hostFailed('approval.host_unavailable'),
  decisionSettled('approval.closed');

  const ActionApprovalCancellationReason(this.code);

  final String code;
}

/// Caller-owned handle for one visible approval prompt.
///
/// [dismiss] is idempotent and its Future may complete only after the prompt
/// is no longer visible. The decision Future must likewise complete only after
/// a user decision has closed the prompt.
abstract interface class ActionApprovalSession {
  Future<ActionApprovalDecision> get decision;

  Future<void> dismiss(ActionApprovalCancellationReason reason);
}

/// Presentation-only boundary for one-shot action confirmation.
///
/// This is trusted root-shell infrastructure, not an adapter extension point.
/// Implementations must use a non-dismissible root modal barrier, trap keyboard
/// focus inside the prompt, render every presentation field, and render
/// exactText verbatim when present. The Host must live outside account runtime
/// subtrees so account retirement cannot remove its dismissal authority.
/// AppControl retains the returned session so it can force dismissal when any
/// authority fence becomes stale.
abstract interface class ActionApprovalHost {
  /// Sticky recovery signal for quarantined account-boundary holds.
  ///
  /// When surfaces are visible this Future completes after the last one is
  /// removed. With no visible surfaces it is already complete.
  Future<void> get whenAllDismissed;

  ActionApprovalSession present(ActionApprovalPrompt prompt);

  /// Emergency close for a failed or partially completed session operation.
  ///
  /// The Future may complete only after every approval surface owned by this
  /// Host is no longer visible. AppControl deliberately keeps its cross-account
  /// boundary hold when both session dismissal and this emergency path fail.
  Future<void> dismissAll(ActionApprovalCancellationReason reason);
}

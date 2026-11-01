/// A durable additional model-call ceiling, shared on this device by every
/// companion surface for an account/environment and Agent. Monetary/token reservations remain the account provider gateway's
/// responsibility; this value must never be presented as measured billing.
final class SurfacePlayCallBudget {
  const SurfacePlayCallBudget({
    this.maximumCalls = 64,
    this.maximumCallsPerMinute = 8,
  });
  final int maximumCalls;
  final int maximumCallsPerMinute;
  void validate() {
    if (maximumCalls < 1 ||
        maximumCalls > 512 ||
        maximumCallsPerMinute < 1 ||
        maximumCallsPerMinute > 30) {
      throw ArgumentError('invalid_play_call_budget');
    }
  }
}

enum SurfacePlayCallReservationStatus {
  reserved,
  rateLimited,
  totalExhausted,
  unavailable,
  duplicate,
}

/// Admission is checked against the durable companion ledger. A temporary rolling
/// window carries its next safe wake-up time; it never releases unknown holds.
final class SurfacePlayCallReservation {
  const SurfacePlayCallReservation._(this.status, [this.nextAllowedAt]);
  static const reserved = SurfacePlayCallReservation._(
    SurfacePlayCallReservationStatus.reserved,
  );
  static const totalExhausted = SurfacePlayCallReservation._(
    SurfacePlayCallReservationStatus.totalExhausted,
  );
  static const unavailable = SurfacePlayCallReservation._(
    SurfacePlayCallReservationStatus.unavailable,
  );
  static const duplicate = SurfacePlayCallReservation._(
    SurfacePlayCallReservationStatus.duplicate,
  );
  factory SurfacePlayCallReservation.rateLimited(DateTime nextAllowedAt) =>
      SurfacePlayCallReservation._(
        SurfacePlayCallReservationStatus.rateLimited,
        nextAllowedAt.toUtc(),
      );
  final SurfacePlayCallReservationStatus status;
  final DateTime? nextAllowedAt;
  bool get isReserved => status == SurfacePlayCallReservationStatus.reserved;
}

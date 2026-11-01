/// Host-owned presentation phases. These are absent from model action schemas.
enum AvatarBackgroundTaskWorkPhase { start, end }

enum AvatarBackgroundTaskWorkDisposition {
  applied,
  waitingForPresentation,
  rejected,
}

/// A closed host presentation outcome; never part of the model action schema.
class AvatarBackgroundTaskWorkResult {
  const AvatarBackgroundTaskWorkResult(this.disposition, {this.code = ''});

  final AvatarBackgroundTaskWorkDisposition disposition;
  final String code;

  bool get applied =>
      disposition == AvatarBackgroundTaskWorkDisposition.applied;
  bool get retryable =>
      disposition == AvatarBackgroundTaskWorkDisposition.waitingForPresentation;
}

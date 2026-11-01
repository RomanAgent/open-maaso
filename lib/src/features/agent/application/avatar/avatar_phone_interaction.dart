/// A remote conversation is presented as a phone, without exposing bone control.
enum AvatarPhoneInteractionPhase { reading, replying, none }

class AvatarPhoneInteractionException implements Exception {
  const AvatarPhoneInteractionException(this.code);
  final String code;

  @override
  String toString() => 'AvatarPhoneInteractionException($code)';
}

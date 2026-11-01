import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/privacy/application/privacy_service.dart';
import 'package:maaso/src/features/privacy/domain/privacy_models.dart';

/// Capture once for the producer's owner. Never borrow a replacement account's
/// consent when an old HTTP request, socket or native join resumes after await.
final class CloudVoicePrivacyGate {
  CloudVoicePrivacyGate.capture()
    : _privacy = appServices.maybeFind<PrivacyService>();
  final PrivacyService? _privacy;
  Stream<PrivacyRevocation> get revocations =>
      _privacy?.revocations.where(
        (event) => event.affects('volcengine', PrivacyScopes.cloudVoice),
      ) ??
      const Stream.empty();

  void requireCurrent() {
    if (_privacy == null ||
        !_privacy.isCurrent ||
        !identical(_privacy, appServices.maybeFind<PrivacyService>())) {
      throw const PrivacyException('PRIVACY_CONTEXT_CHANGED');
    }
  }

  Future<void> require() async {
    requireCurrent();
    await _privacy!.requireConsent(
      recipientId: 'volcengine',
      scope: PrivacyScopes.cloudVoice,
    );
    requireCurrent();
  }
}

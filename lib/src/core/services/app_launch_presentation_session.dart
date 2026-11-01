import 'package:maaso/src/core/foundation/app_framework.dart';

/// One cold-start Home entrance per process. An explicit new login can present
/// its own doorway, but still consumes Home's pending cold-start entrance.
/// Ordinary route returns and resume never create a new entrance.
final class AppLaunchPresentationSession {
  static AppLaunchPresentationSession ensure() =>
      appServices.maybeFind<AppLaunchPresentationSession>() ??
      appServices.put(AppLaunchPresentationSession(), permanent: true);

  bool _entranceAvailable = true;

  /// Claim immediately before presenting an entrance, or when a visible Home
  /// preview has already served as the launch presentation. Retries restore the
  /// ordinary pose without replaying the walk. This grants no avatar authority.
  bool consumeEntrance() {
    final available = _entranceAvailable;
    _entranceAvailable = false;
    return available;
  }

  bool consumeAuthenticatedDoorway() {
    _entranceAvailable = false;
    return true;
  }
}

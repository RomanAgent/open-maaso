import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';

void main() {
  final routes = AppPlatformCapabilities.routeAvailabilityRequirements.keys
      .followedBy(AppPlatformCapabilities.routeActionRequirements.keys)
      .toSet();
  final resolver = AppPlatformCapabilitySnapshotResolver(routeIds: routes);

  AppCapabilitySnapshot snapshot(AppHostPlatform platform) =>
      AppCapabilitySnapshot.materialize(
        generation: 0,
        draft: resolver.resolve(
          AppCapabilitySnapshotContext(
            hostPlatform: platform,
            rolloutGeneration: 0,
          ),
        ),
      );

  test('cloud LLM and TTS paths are ready on every platform', () {
    for (final platform in AppHostPlatform.values) {
      final current = snapshot(platform);
      expect(current.allows(AppCapabilityKey.cloudLlm), isTrue);
      expect(current.allows(AppCapabilityKey.cloudTts), isTrue);
    }
  });

  test('advanced and local model paths are hidden outside desktop', () {
    for (final platform in AppHostPlatform.values) {
      final current = snapshot(platform);
      final desktop = switch (platform) {
        AppHostPlatform.macos ||
        AppHostPlatform.windows ||
        AppHostPlatform.linux => true,
        _ => false,
      };
      for (final capability in <AppActionCapability>[
        AppActionCapability.advancedAiSettings,
        AppActionCapability.onDeviceLlm,
        AppActionCapability.onDeviceSpeechModels,
      ]) {
        final decision = current.decision(
          AppCapabilityKey.platformAction(capability),
        )!;
        expect(
          decision.isUsable,
          desktop,
          reason: '${platform.name}:$capability',
        );
        expect(decision.isVisible, desktop);
        expect(
          decision.reasonCodes,
          desktop ? isEmpty : contains('unsupported_host_platform'),
        );
      }
      expect(
        current.exposes(AppCapabilityKey.route('advanced_features')),
        desktop,
      );
    }
  });

  test('ordinary unsupported hardware stays visible but unavailable', () {
    final current = snapshot(AppHostPlatform.web);
    final bluetooth = current.decision(
      AppCapabilityKey.platformAction(AppActionCapability.bluetooth),
    )!;

    expect(bluetooth.isVisible, isTrue);
    expect(bluetooth.admission, AppCapabilityAdmission.allowed);
    expect(bluetooth.readiness, AppCapabilityReadiness.unavailable);
    expect(bluetooth.canExecute, isFalse);
  });

  test('unknown required keys fail closed with a stable reason', () {
    final current = snapshot(AppHostPlatform.macos);
    final unknown = AppCapabilityKey.skill('not_registered');

    expect(current.allows(unknown), isFalse);
    expect(
      current.rejected(<AppCapabilityKey>[unknown])[unknown],
      const <String>{'capability_not_declared'},
    );
  });

  test('duplicate keys and malformed account context fail closed', () {
    final key = AppCapabilityKey.skill('duplicate');
    final duplicate = AppCapabilityDecision.available(key);
    expect(
      () => AppCapabilitySnapshotDraft(
        context: AppCapabilitySnapshotContext(
          hostPlatform: AppHostPlatform.macos,
          rolloutGeneration: 0,
        ),
        decisions: <AppCapabilityDecision>[duplicate, duplicate],
      ),
      throwsFormatException,
    );
    expect(
      () => AppCapabilitySnapshotContext(
        hostPlatform: AppHostPlatform.macos,
        rolloutGeneration: 0,
        accountScopeDigest: 'digest',
      ),
      throwsFormatException,
    );
    for (final malformedDigest in <String>[
      'raw-account-uuid',
      'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    ]) {
      expect(
        () => AppCapabilitySnapshotContext(
          hostPlatform: AppHostPlatform.macos,
          rolloutGeneration: 0,
          accountScopeDigest: malformedDigest,
          accountGeneration: 1,
        ),
        throwsFormatException,
        reason: malformedDigest,
      );
    }
  });
}

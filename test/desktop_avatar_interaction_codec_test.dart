import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/desktop/application/desktop_avatar_interaction.dart';

void main() {
  test('DesktopAvatarInteractionV1 accepts the exact bounded contract', () {
    final interaction = DesktopAvatarInteractionV1.tryFromJson(<String, Object>{
      'version': 1,
      'type': 'tap',
      'normalizedX': 0.25,
      'normalizedY': 1,
      'region': 'head',
      'generation': 7,
      'timestampMs': 1234,
    });

    expect(interaction, isNotNull);
    expect(interaction!.type, DesktopAvatarInteractionType.tap);
    expect(interaction.region, DesktopAvatarInteractionRegion.head);
    expect(interaction.normalizedX, 0.25);
    expect(interaction.normalizedY, 1);
    expect(interaction.generation, 7);
    expect(interaction.timestampMs, 1234);
    expect(interaction.toJson(), <String, Object>{
      'version': 1,
      'type': 'tap',
      'normalizedX': 0.25,
      'normalizedY': 1.0,
      'region': 'head',
      'generation': 7,
      'timestampMs': 1234,
    });
  });

  test(
    'DesktopAvatarInteractionV1 rejects malformed or unbounded payloads',
    () {
      final valid = <String, Object>{
        'version': 1,
        'type': 'tap',
        'normalizedX': 0.5,
        'normalizedY': 0.5,
        'region': 'avatar',
        'generation': 1,
        'timestampMs': 0,
      };
      final invalid = <Object?>[
        null,
        <String, Object>{...valid, 'extra': true},
        <String, Object>{...valid}..remove('region'),
        <String, Object>{...valid, 'version': 1.0},
        <String, Object>{...valid, 'type': 'drag'},
        <String, Object>{...valid, 'normalizedX': double.nan},
        <String, Object>{...valid, 'normalizedX': -0.01},
        <String, Object>{...valid, 'normalizedY': 1.01},
        <String, Object>{...valid, 'region': 'neck'},
        <String, Object>{...valid, 'generation': 0},
        <String, Object>{
          ...valid,
          'generation': DesktopAvatarInteractionV1.maximumGeneration + 1,
        },
        <String, Object>{...valid, 'generation': 1.0},
        <String, Object>{...valid, 'timestampMs': -1},
        <String, Object>{
          ...valid,
          'timestampMs': DesktopAvatarInteractionV1.maximumSafeInteger + 1,
        },
        <String, Object>{...valid, 'timestampMs': 1.0},
        <Object, Object>{...valid, 3: 'non-string key'},
      ];

      for (final payload in invalid) {
        expect(
          DesktopAvatarInteractionV1.tryFromJson(payload),
          isNull,
          reason: '$payload',
        );
      }
    },
  );

  test('DesktopAvatarInteractionV1 constructor enforces numeric bounds', () {
    expect(
      () => DesktopAvatarInteractionV1(
        normalizedX: double.infinity,
        normalizedY: 0,
        region: DesktopAvatarInteractionRegion.avatar,
        generation: 1,
        timestampMs: 0,
      ),
      throwsArgumentError,
    );
    expect(
      () => DesktopAvatarInteractionV1(
        normalizedX: 0,
        normalizedY: 0,
        region: DesktopAvatarInteractionRegion.avatar,
        generation: DesktopAvatarInteractionV1.maximumGeneration + 1,
        timestampMs: 0,
      ),
      throwsArgumentError,
    );
  });
}

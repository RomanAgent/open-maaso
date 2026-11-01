import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';

import 'identity_test_support.dart';

void main() {
  test('names use Unicode codepoints rather than UTF-16 length', () {
    expect(IdentityNames.validate(List.filled(40, '🌟').join()), isNull);
    expect(
      IdentityNames.validate(List.filled(41, '🌟').join()),
      IdentityNameError.tooLong,
    );
    expect(IdentityNames.require(' 星河 '), '星河');
    expect(IdentityNames.validate(' '), IdentityNameError.empty);
    for (final text in [
      'Star\n',
      'A\tB',
      'A\u0000B',
      'A\u0085B',
      'A\u202eB',
      'A\u2066B',
      'A\u2028B',
    ]) {
      expect(
        IdentityNames.validate(text),
        IdentityNameError.invalidCharacters,
        reason: 'control characters cannot impersonate labels',
      );
    }
  });

  test('first profile and migrated partial profile remain incomplete', () {
    expect(
      identityFixture(version: 0, player: '', agent: '').completed,
      isFalse,
    );
    expect(identityFixture(player: '', agent: 'Existing').completed, isFalse);
    expect(identityFixture().completed, isTrue);
    expect(() => identityFixture(playerId: ''), throwsFormatException);
    expect(
      () => identityFixture(playerId: 'same', agentId: 'same'),
      throwsFormatException,
    );
  });

  test('wire profile requires exact typed public fields', () {
    final data = <String, Object?>{
      'playerActorId': 'player-a',
      'playerName': 'Star',
      'agentActorId': 'agent-a',
      'agentName': 'Wheat',
      'version': 2,
    };
    expect(IdentityProfile.fromJson(data).completed, isTrue);
    expect(
      () => IdentityProfile.fromJson({...data, 'accountUuid': 'private'}),
      throwsFormatException,
    );
    expect(
      () => IdentityProfile.fromJson({...data, 'version': 2.0}),
      throwsFormatException,
    );
    expect(
      () => IdentityProfile.fromJson({...data, 'playerName': ' Star '}),
      throwsFormatException,
    );
  });
}

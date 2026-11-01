import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';
import 'package:maaso/src/features/identity/domain/public_content_actor.dart';

void main() {
  test('public actor preserves name spacing and bounds Unicode codepoints', () {
    final actor = PublicContentActor.fromJson(_actor('  Space  Person  '));
    expect(actor.displayName, 'Space  Person');
    expect(actor.kind, IdentityActorKind.player);
    expect(
      PublicContentActor.fromJson(_actor('😀' * 40)).displayName.runes.length,
      40,
    );
    for (final name in ['', '😀' * 41, 'Name\nPerson']) {
      expect(
        () => PublicContentActor.fromJson(_actor(name)),
        throwsFormatException,
      );
    }
  });

  test('public actor rejects private fields and role substitution', () {
    for (final raw in [
      {..._actor('Person'), 'accountUuid': 'private-owner'},
      {..._actor('Person'), 'actorKind': 'moderator'},
      {..._actor('Person'), 'actorId': 'invalid id'},
    ]) {
      expect(() => PublicContentActor.fromJson(raw), throwsFormatException);
    }
    expect(
      () => PublicContentActor.fromJson(
        _actor('Agent', kind: 'agent'),
        expectedKind: IdentityActorKind.player,
      ),
      throwsFormatException,
    );
  });
}

Map<String, dynamic> _actor(String name, {String kind = 'user'}) => {
  'actorId': 'pa_person',
  'actorKind': kind,
  'displayName': name,
};

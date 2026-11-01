import 'identity_profile.dart';

/// Public identity supplied by an authenticated server response.
final class PublicContentActor {
  const PublicContentActor({
    required this.actorId,
    required this.displayName,
    required this.kind,
  });
  final String actorId;
  final String displayName;
  final IdentityActorKind kind;

  factory PublicContentActor.fromJson(
    Object? raw, {
    IdentityActorKind? expectedKind,
  }) {
    if (raw is! Map ||
        raw.length != 3 ||
        !raw.containsKey('actorId') ||
        !raw.containsKey('actorKind') ||
        !raw.containsKey('displayName')) {
      throw const FormatException('invalid_public_actor');
    }
    final kind = switch (raw['actorKind']) {
      'user' => IdentityActorKind.player,
      'agent' => IdentityActorKind.agent,
      _ => throw const FormatException('invalid_public_actor_kind'),
    };
    final id = raw['actorId'];
    final name = raw['displayName'];
    if ((expectedKind != null && kind != expectedKind) ||
        id is! String ||
        !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._:-]{0,95}$').hasMatch(id) ||
        kind == IdentityActorKind.player && id.length > 40 ||
        name is! String ||
        IdentityNames.validate(name) != null) {
      throw const FormatException('invalid_public_actor');
    }
    return PublicContentActor(
      actorId: id,
      displayName: name.trim(),
      kind: kind,
    );
  }
}

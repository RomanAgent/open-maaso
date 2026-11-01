/// Public role is attached to the actor, never inferred from their name or text.
enum IdentityActorKind { player, agent }

enum IdentityNameError { empty, tooLong, invalidCharacters }

abstract final class IdentityNames {
  static const maxCodepoints = 40;

  static IdentityNameError? validate(String raw) {
    final value = raw.trim();
    if (value.isEmpty) return IdentityNameError.empty;
    if (value.runes.length > maxCodepoints) return IdentityNameError.tooLong;
    if (raw.runes.any(
      (rune) =>
          rune < 0x20 ||
          (rune >= 0x7f && rune <= 0x9f) ||
          (rune >= 0x202a && rune <= 0x202e) ||
          (rune >= 0x2066 && rune <= 0x2069) ||
          (rune >= 0xd800 && rune <= 0xdfff) ||
          rune == 0xfffd ||
          rune == 0x2028 ||
          rune == 0x2029,
    )) {
      return IdentityNameError.invalidCharacters;
    }
    return null;
  }

  static String require(String raw) {
    if (validate(raw) != null) {
      throw const FormatException('invalid_identity_name');
    }
    return raw.trim();
  }
}

/// Authenticated server snapshot. Empty names/IDs are allowed only before the
/// first revision. Account UUIDs and credentials do not belong in this model.
final class IdentityProfile {
  IdentityProfile({
    required this.playerActorId,
    required this.playerName,
    required this.agentActorId,
    required this.agentName,
    required this.version,
  }) {
    if (version < 0 || version > 9007199254740991) {
      throw const FormatException('invalid_identity_version');
    }
    for (final id in [playerActorId, agentActorId]) {
      if (id.isNotEmpty && !RegExp(r'^[A-Za-z0-9._:-]{1,128}$').hasMatch(id)) {
        throw const FormatException('invalid_identity_actor');
      }
      if (version > 0 && id.isEmpty) {
        throw const FormatException('missing_identity_actor');
      }
    }
    if (playerActorId.isNotEmpty && playerActorId == agentActorId) {
      throw const FormatException('identity_actors_must_differ');
    }
    for (final name in [playerName, agentName]) {
      if (name.isNotEmpty &&
          (IdentityNames.validate(name) != null || name != name.trim())) {
        throw const FormatException('invalid_identity_name');
      }
    }
  }

  final String playerActorId;
  final String playerName;
  final String agentActorId;
  final String agentName;
  final int version;

  bool get completed =>
      version > 0 &&
      IdentityNames.validate(playerName) == null &&
      IdentityNames.validate(agentName) == null;

  factory IdentityProfile.fromJson(Object? raw) {
    const keys = {
      'playerActorId',
      'playerName',
      'agentActorId',
      'agentName',
      'version',
    };
    if (raw is! Map ||
        raw.length != keys.length ||
        !raw.keys.every(keys.contains)) {
      throw const FormatException('invalid_identity_profile');
    }
    if (raw['version'] is! int ||
        keys
            .where((key) => key != 'version')
            .any((key) => raw[key] is! String)) {
      throw const FormatException('invalid_identity_profile');
    }
    return IdentityProfile(
      playerActorId: raw['playerActorId'] as String,
      playerName: raw['playerName'] as String,
      agentActorId: raw['agentActorId'] as String,
      agentName: raw['agentName'] as String,
      version: raw['version'] as int,
    );
  }
}

enum IdentityFailure {
  unavailable,
  authenticationRequired,
  contextChanged,
  conflict,
  rejected,
  invalidResponse,
}

final class IdentityException implements Exception {
  const IdentityException(this.failure);
  final IdentityFailure failure;
  @override
  String toString() => 'IdentityException(${failure.name})';
}

abstract interface class IdentityGateway {
  String get requestContextKey;
  Future<IdentityProfile> fetch({required String expectedContextKey});
  Future<IdentityProfile> update({
    required String expectedContextKey,
    required int expectedVersion,
    required String playerName,
    required String agentName,
  });
}

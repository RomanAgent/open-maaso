import 'identity_profile.dart';

/// Human-entered local names. They carry no server actors or revision.
final class IdentityLocalNames {
  IdentityLocalNames({required String playerName, required String agentName})
    : playerName = IdentityNames.require(playerName),
      agentName = IdentityNames.require(agentName);

  final String playerName;
  final String agentName;

  Map<String, Object?> toJson() => {
    'playerName': playerName,
    'agentName': agentName,
  };

  factory IdentityLocalNames.fromJson(Object? raw) {
    if (raw is! Map ||
        raw.length != 2 ||
        raw['playerName'] is! String ||
        raw['agentName'] is! String) {
      throw const FormatException('invalid_local_identity_names');
    }
    return IdentityLocalNames(
      playerName: raw['playerName'] as String,
      agentName: raw['agentName'] as String,
    );
  }
}

/// Private account cache. Cached server facts are never publication authority.
final class IdentityLocalState {
  const IdentityLocalState({this.serverProfile, this.pendingNames});
  final IdentityProfile? serverProfile;
  final IdentityLocalNames? pendingNames;

  IdentityLocalNames? get names =>
      pendingNames ??
      (serverProfile?.completed == true
          ? IdentityLocalNames(
              playerName: serverProfile!.playerName,
              agentName: serverProfile!.agentName,
            )
          : null);

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'serverProfile': switch (serverProfile) {
      final p? => {
        'playerActorId': p.playerActorId,
        'playerName': p.playerName,
        'agentActorId': p.agentActorId,
        'agentName': p.agentName,
        'version': p.version,
      },
      null => null,
    },
    'pendingNames': pendingNames?.toJson(),
  };

  factory IdentityLocalState.fromJson(Object? raw) {
    if (raw is! Map ||
        raw.length != 3 ||
        raw['schemaVersion'] != 1 ||
        !raw.containsKey('serverProfile') ||
        !raw.containsKey('pendingNames')) {
      throw const FormatException('invalid_local_identity_state');
    }
    return IdentityLocalState(
      serverProfile: raw['serverProfile'] == null
          ? null
          : IdentityProfile.fromJson(raw['serverProfile']),
      pendingNames: raw['pendingNames'] == null
          ? null
          : IdentityLocalNames.fromJson(raw['pendingNames']),
    );
  }
}

/// Completing first-use naming may precede server identity registration.
final class IdentitySetupResult {
  IdentitySetupResult.server(IdentityProfile value)
    : profile = value,
      names = IdentityLocalNames(
        playerName: value.playerName,
        agentName: value.agentName,
      ),
      pendingSync = false {
    if (!value.completed) {
      throw const FormatException('identity_setup_incomplete');
    }
  }

  const IdentitySetupResult.local(this.names)
    : profile = null,
      pendingSync = true;

  final IdentityProfile? profile;
  final IdentityLocalNames names;
  final bool pendingSync;
}

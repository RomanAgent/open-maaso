import 'package:maaso/src/features/identity/domain/identity_profile.dart';

IdentityProfile identityFixture({
  int version = 1,
  String player = 'Star',
  String agent = 'Wheat',
  String playerId = 'player-1',
  String agentId = 'aa_0123456789abcdef0123456789abcdef',
}) => IdentityProfile(
  playerActorId: version == 0 ? '' : playerId,
  playerName: player,
  agentActorId: version == 0 ? '' : agentId,
  agentName: agent,
  version: version,
);

class FakeIdentityGateway implements IdentityGateway {
  FakeIdentityGateway({IdentityProfile? initial})
    : stored = initial ?? identityFixture(version: 0, player: '', agent: '');
  IdentityProfile stored;
  @override
  String requestContextKey = 'test|account-a';
  int writes = 0;
  int reads = 0;
  int? expectedVersion;
  Future<IdentityProfile> Function()? fetchOverride;
  Future<IdentityProfile> Function(String player, String agent, int version)?
  updateOverride;

  @override
  Future<IdentityProfile> fetch({required String expectedContextKey}) async {
    reads++;
    return fetchOverride == null ? stored : await fetchOverride!();
  }

  @override
  Future<IdentityProfile> update({
    required String expectedContextKey,
    required int expectedVersion,
    required String playerName,
    required String agentName,
  }) async {
    writes++;
    this.expectedVersion = expectedVersion;
    if (updateOverride != null) {
      return updateOverride!(playerName, agentName, expectedVersion);
    }
    stored = identityFixture(
      version: expectedVersion + 1,
      player: playerName,
      agent: agentName,
    );
    return stored;
  }
}

import '../domain/creator_reward_evidence.dart';

abstract interface class CreatorRewardGateway {
  Future<CreatorRewardEvidencePage> creatorRewardEvidence(String context);
}

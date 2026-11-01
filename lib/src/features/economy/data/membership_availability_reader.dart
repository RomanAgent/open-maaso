import '../domain/economy_market_info.dart';

abstract interface class MembershipAvailabilityReader {
  Future<MembershipAvailability> membershipAvailability(String context);
}

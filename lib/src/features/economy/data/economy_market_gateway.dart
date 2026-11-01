import '../domain/economy_market_info.dart';

abstract interface class EconomyMarketGateway {
  Future<MembershipAvailability> membershipAvailability(String context);
}

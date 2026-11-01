import 'dart:math';
import 'package:maaso/src/core/foundation/app_framework.dart';
import '../data/economy_http_client.dart';
import '../domain/economy_models.dart';
import '../domain/economy_market_info.dart';
import '../data/economy_market_gateway.dart';
import '../data/cosmetic_gateway.dart';
import 'cosmetic_service.dart';
import 'membership_review.dart';
import '../domain/membership_benefits.dart';
import '../data/creator_reward_gateway.dart';
import '../domain/creator_reward_evidence.dart';

final class PendingMembershipPurchase {
  PendingMembershipPurchase(this.quote, this.requestId, this.reviewedTerms);
  final ReviewedMembershipTerms reviewedTerms;
  final EconomyMembershipQuote quote;
  final String requestId;
  bool uncertain = false;
}

/// Account-scoped service. Uncertain purchase retry identity survives page
/// navigation for this account and is never silently replaced with a new key.
final class EconomyService extends AppService {
  EconomyService({
    required EconomyGateway gateway,
    void Function()? closeGateway,
    DateTime Function()? now,
    String Function()? requestId,
  }) : _gateway = gateway,
       _closeGateway = closeGateway,
       _now = now ?? DateTime.now,
       _requestId = requestId ?? _newRequestId,
       boundContextKey = gateway.requestContextKey;
  final EconomyGateway _gateway;
  final void Function()? _closeGateway;
  final DateTime Function() _now;
  final String Function() _requestId;
  final String boundContextKey;
  final _retired = false.obs;
  bool _writing = false;
  CosmeticService? _cosmetics;
  CosmeticService? get cosmetics {
    _check();
    final gateway = _gateway;
    if (gateway is! CosmeticGateway) return null;
    return _cosmetics ??= CosmeticService(
      gateway: gateway as CosmeticGateway,
      ownerIsCurrent: () => isCurrent,
    );
  }

  static String _newRequestId() {
    final random = Random.secure();
    return 'ec_${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
  }

  PendingMembershipPurchase? _pending;
  bool get isCurrent =>
      !_retired.value && boundContextKey == _gateway.requestContextKey;
  PendingMembershipPurchase? get pending => isCurrent ? _pending : null;
  bool get busy => _writing;
  bool get quoteExpired =>
      pending != null && !pending!.quote.expiresAt.isAfter(_now().toUtc());
  void _check() {
    if (!isCurrent) throw const EconomyException('context_changed');
  }

  /// Reads the account balance without loading the store catalog or creating
  /// a purchase intent.
  Future<EconomyWallet> readWallet() async {
    _check();
    final wallet = await _gateway.wallet(boundContextKey);
    _check();
    return wallet;
  }

  Future<EconomyOverview> load() async {
    _check();
    final values = await Future.wait<Object?>([
      _gateway.catalog(boundContextKey),
      _gateway.wallet(boundContextKey),
      _gateway.ledger(boundContextKey),
      _gateway.pendingRewards(boundContextKey),
      _gateway.membership(boundContextKey),
      _loadCreatorEvidence(),
    ]);
    _check();
    return EconomyOverview(
      catalog: values[0] as EconomyCatalog,
      wallet: values[1] as EconomyWallet,
      ledger: values[2] as EconomyLedgerPage,
      rewards: values[3] as List<EconomyRewardEstimate>,
      membership: values[4] as EconomyMembership,
      creatorEvidence: values[5] as CreatorRewardEvidencePage?,
    );
  }

  Future<CreatorRewardEvidencePage?> _loadCreatorEvidence() async {
    final gateway = _gateway;
    if (gateway is! CreatorRewardGateway) return null;
    try {
      return await (gateway as CreatorRewardGateway).creatorRewardEvidence(
        boundContextKey,
      );
    } catch (_) {
      // The caller rechecks the account after every read completes. An activity
      // outage must not turn verified wallet balances into unknown balances.
      return null;
    }
  }

  Future<EconomyLedgerPage> moreLedger(int beforeId) async {
    _check();
    final result = await _gateway.ledger(boundContextKey, beforeId: beforeId);
    _check();
    return result;
  }

  Future<EconomyMembershipQuote> prepareQuote(MembershipTier tier) async {
    _check();
    if (_writing || _pending?.uncertain == true) {
      throw const EconomyException('purchase_unresolved');
    }
    _writing = true;
    try {
      final terms = reviewMembershipTerms(
        await readMembershipAvailability(),
        tier,
      );
      _check();
      final quote = await _gateway.quoteMembership(
        boundContextKey,
        tier,
        expectedPolicyVersion: terms.policyVersion,
      );
      _check();
      if (quote.policyVersion != terms.policyVersion) {
        throw const EconomyException('membership_policy_changed');
      }
      if (quote.tier != tier || !quote.expiresAt.isAfter(_now().toUtc())) {
        throw const EconomyException('invalid_response');
      }
      _pending = PendingMembershipPurchase(quote, _requestId(), terms);
      return quote;
    } finally {
      _writing = false;
    }
  }

  void cancelQuote() {
    if (!_writing && _pending?.uncertain != true) _pending = null;
  }

  Future<MembershipAvailability> readMembershipAvailability() async {
    _check();
    final gateway = _gateway;
    if (gateway is! EconomyMarketGateway) {
      throw const EconomyException('market_info_unavailable');
    }
    final value = await (gateway as EconomyMarketGateway)
        .membershipAvailability(boundContextKey);
    _check();
    return value;
  }

  /// Called only by the explicit user confirmation button, never AppControl.
  Future<EconomyRedemption> confirm(String displayedQuoteId) async {
    _check();
    final intent = _pending;
    if (_writing || intent == null || intent.quote.id != displayedQuoteId) {
      throw const EconomyException('quote_not_ready');
    }
    if (quoteExpired && !intent.uncertain) {
      throw const EconomyException('QUOTE_EXPIRED');
    }
    _writing = true;
    try {
      final result = await _gateway.redeem(
        boundContextKey,
        quoteId: intent.quote.id,
        requestId: intent.requestId,
      );
      _check();
      if (result.quoteId != intent.quote.id ||
          result.price != intent.quote.price ||
          result.grant.tier != intent.quote.tier) {
        throw const EconomyException('invalid_response');
      }
      _pending = null;
      return result;
    } on EconomyException catch (error) {
      if (isCurrent && !error.definiteRefusal) intent.uncertain = true;
      rethrow;
    } catch (_) {
      if (isCurrent) intent.uncertain = true;
      throw const EconomyException('connection_unavailable');
    } finally {
      _writing = false;
    }
  }

  @override
  void onClose() {
    _retired.value = true;
    _cosmetics?.onClose();
    _cosmetics = null;
    _pending = null;
    _closeGateway?.call();
    super.onClose();
  }
}

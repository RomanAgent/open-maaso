import 'package:maaso/src/core/foundation/app_framework.dart';
import '../data/native_store_gateway.dart';
import '../domain/economy_models.dart';
import '../domain/store_payment_models.dart';
import 'store_purchase_service.dart';

/// Local selection only; payment and restore remain human-controlled UI flows.
final class MembershipSelectionController extends AppController {
  MembershipSelectionController({required this.service});
  final StorePurchaseService? service;
  final selectedTier = Rxn<MembershipTier>();
  final reviewing = false.obs;
  final restoring = false.obs;
  bool _retired = false;
  bool _userControl = false;
  bool _selectedByUser = false;
  bool get active => !_retired && service?.isCurrent == true;
  bool get busy =>
      active &&
      (reviewing.value || restoring.value || service?.busy.value == true);
  MembershipUsage? get usage => active ? service!.usage.value : null;
  MembershipTier? get currentTier {
    final value = usage;
    if (value?.expiresAt?.isBefore(DateTime.now().toUtc()) == true) return null;
    return value?.tier;
  }

  NativeStoreProduct? productFor(MembershipTier tier) {
    if (!active) return null;
    final matches = service!.products.where(
      (p) => p.product.kind == 'membership' && p.product.tier == tier,
    );
    return matches.length == 1 ? matches.single : null;
  }

  bool get canBuy =>
      active &&
      !busy &&
      service!.nativeReady.value &&
      !service!.loading.value &&
      !service!.hasUnresolved &&
      usage != null &&
      selectedTier.value != null &&
      selectedTier.value != currentTier &&
      productFor(selectedTier.value!) != null;

  @override
  Future<void> refresh() async {
    if (!active || busy) return;
    try {
      await service!.load();
    } catch (_) {
      return;
    }
    if (!active || _selectedByUser) return;
    selectedTier.value = currentTier?.isCurrent == true ? currentTier : null;
  }

  void setUserControl(bool value) => _userControl = value;
  bool select(MembershipTier? tier) {
    if (!active || busy || tier != null && !tier.isCurrent) return false;
    _selectedByUser = true;
    selectedTier.value = tier;
    return true;
  }

  bool prepare(String value) {
    if (_userControl) return false;
    if (value == 'free') return select(null);
    final matches = MembershipTier.currentTiers.where(
      (tier) => tier.wireName == value,
    );
    return matches.length == 1 && select(matches.single);
  }

  @override
  void onClose() {
    _retired = true;
    selectedTier.value = null;
    super.onClose();
  }
}

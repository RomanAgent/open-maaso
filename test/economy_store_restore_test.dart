import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/economy/application/store_purchase_service.dart';
import 'package:maaso/src/features/economy/data/native_store_gateway.dart';
import 'package:maaso/src/features/economy/domain/store_payment_models.dart';
import 'economy_store_purchase_test.dart' as fixture;

class RestoreGateway extends fixture.StoreGatewayFake {
  final proofs = <Map<String, Object?>>[];
  @override
  Future<StoreReceipt> verify(String context, Map<String, Object?> proof) {
    proofs.add(Map.of(proof));
    return super.verify(context, proof);
  }
}

void main() {
  test(
    'restoring an acknowledged transaction refreshes server renewal state',
    () async {
      final gateway = RestoreGateway();
      final native = fixture.NativeStoreFake();
      final service = StorePurchaseService(
        gateway: gateway,
        native: native,
        now: () => fixture.storeNow,
      );
      await service.load();
      native.purchased();
      await fixture.flush();
      expect(gateway.proofs.single['refreshRenewal'], null);
      await service.restore();
      native.updates.add([
        const NativeStoreEvent(
          productId: 'test.coins',
          transactionId: 'transaction-1',
          status: NativeStoreStatus.restored,
          purchaseToken: '',
          handle: 'restored',
        ),
      ]);
      await fixture.flush();
      expect(gateway.proofs.length, 2);
      expect(gateway.proofs.last['refreshRenewal'], true);
      expect(gateway.proofs.last['transactionId'], 'transaction-1');
      expect(native.buys, 0);
      service.onClose();
      await native.updates.close();
    },
  );
}

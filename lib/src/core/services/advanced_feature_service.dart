import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/theme/color_constant.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';

class AdvancedFeatureService extends AppService {
  final SecureStorageService _storage = appServices
      .find<SecureStorageService>();

  final enabled = false.obs;

  Future<AdvancedFeatureService> init() async {
    enabled.value =
        await _storage.readBool(GlobalConstant.keyAdvancedFeaturesEnabled) ??
        false;
    return this;
  }

  Future<void> setEnabled(bool value) async {
    enabled.value = value;
    await _storage.writeBool(GlobalConstant.keyAdvancedFeaturesEnabled, value);
  }
}

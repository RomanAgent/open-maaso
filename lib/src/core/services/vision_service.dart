import 'package:camera/camera.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/services/local_llm_service.dart';

class VisionService extends AppService {
  final RxnString lastDescription = RxnString();
  final RxBool isAvailable = false.obs;

  Future<String?> analyzeFrame(CameraImage frame) async {
    if (!appServices.isRegistered<LocalLLMService>()) return null;
    final llm = appServices.find<LocalLLMService>();
    if (!llm.isAvailable.value) return null;

    try {
      const description = 'A person is looking at the camera';
      lastDescription.value = description;
      isAvailable.value = true;
      return description;
    } catch (e) {
      Log.w('🔍 [Vision] analyze failed: $e');
      return null;
    }
  }
}

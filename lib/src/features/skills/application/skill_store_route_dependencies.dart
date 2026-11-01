import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/skills/application/skill_store_controller.dart';

class SkillStoreRouteDependencies extends RouteDependencies {
  @override
  void dependencies() {
    if (!appServices.isRegistered<SkillStoreController>()) {
      appServices.lazyPut<SkillStoreController>(() => SkillStoreController());
    }
  }
}

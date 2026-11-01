import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/chat/application/u2a_chat_controller.dart';

class U2aChatRouteDependencies extends RouteDependencies {
  @override
  void dependencies() {
    appServices.lazyPut<U2aChatController>(() => U2aChatController());
  }
}

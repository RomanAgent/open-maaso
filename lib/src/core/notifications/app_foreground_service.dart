import 'package:flutter/widgets.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

/// A single lifecycle gate shared by notification producers.
///
/// Background isolates never create this service. Producers must check this
/// value before emitting an EventBus event that can reach AgentRuntime.
class AppForegroundService extends AppService with WidgetsBindingObserver {
  final isForeground = false.obs;

  @override
  void onInit() {
    super.onInit();
    WidgetsBinding.instance.addObserver(this);
    final initialState = WidgetsBinding.instance.lifecycleState;
    isForeground.value =
        initialState == null || initialState == AppLifecycleState.resumed;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    isForeground.value = state == AppLifecycleState.resumed;
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    super.onClose();
  }
}

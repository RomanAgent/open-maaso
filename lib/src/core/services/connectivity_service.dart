import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

/// Single source of truth for "do we have a working network right now".
///
/// `environment_sensor_service.dart` listens to the same underlying stream
/// for its own purposes (firing env cues to the agent).  This service
/// exists separately because `AgentRuntime.chat()` needs a *cheap, hot*
/// boolean it can check on every turn without re-querying the platform.
class ConnectivityService extends AppService {
  final RxBool isOnline = true.obs;
  final Connectivity _c = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _sub;

  Future<ConnectivityService> init() async {
    final initial = await _c.checkConnectivity();
    isOnline.value = !initial.contains(ConnectivityResult.none);
    _sub = _c.onConnectivityChanged.listen((list) {
      isOnline.value = !list.contains(ConnectivityResult.none);
    });
    return this;
  }

  @override
  void onClose() {
    _sub?.cancel();
    super.onClose();
  }
}

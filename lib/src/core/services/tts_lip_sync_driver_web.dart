import 'dart:typed_data';

import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/data/events/event_bus.dart';

class TtsLipSyncDriver extends AppService {
  final RxBool isReady = false.obs;

  Future<TtsLipSyncDriver> init() async => this;

  Future<void> ensureReady() async {}

  Future<void> driveFromSamples(
    Float32List samples,
    int sampleRate, {
    String? agentId,
  }) async {
    stop(agentId: agentId);
  }

  Future<void> driveFromWavBytes(Uint8List wavBytes, {String? agentId}) async {
    stop(agentId: agentId);
  }

  Future<void> driveFromSystemTts(String text, {String? agentId}) async {
    stop(agentId: agentId);
  }

  void stop({String? agentId}) {
    EventBus().fire(LipSyncAmplitudeEvent(0, agentId: agentId));
  }
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('main registers realtime agent dependencies behind explicit config', () {
    final source = File('lib/main.dart').readAsStringSync();

    expect(source, contains('RealtimeAgentConfig.fromEnvironment('));
    expect(source, contains('_registerRealtimeAgent('));
    expect(source, contains('RealtimeActionStreamService('));
    expect(source, contains('SembastRealtimeActionCursorStore('));
    expect(source, contains('coordinator.requireCurrentRequestAuthority'));
    expect(source, isNot(contains('baseUriProvider: () => config.baseUri')));
    expect(source, contains('VolcEngineRtcNativeAdapter()'));
    expect(source, contains('VolcRtcSessionService('));
  });

  test('live media remains isolated from realtime voice chat services', () {
    final liveDirectory = Directory('lib/live');
    final liveSource = liveDirectory.existsSync()
        ? liveDirectory
              .listSync(recursive: true)
              .whereType<File>()
              .where((file) => file.path.endsWith('.dart'))
              .map((file) => file.readAsStringSync())
              .join('\n')
        : '';

    expect(
      liveSource,
      isNot(contains('service/volc_rtc_session_service.dart')),
    );
    expect(liveSource, isNot(contains('VolcRtcSessionService')));

    final mainSource = File('lib/main.dart').readAsStringSync();
    expect(mainSource, contains('VolcEngineRtcNativeAdapter()'));
    expect(mainSource, contains('VolcRtcSessionService('));
  });
}

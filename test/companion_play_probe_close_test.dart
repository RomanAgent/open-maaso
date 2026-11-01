import 'package:flutter_test/flutter_test.dart';

import '../tool/companion_play/vm_probe.dart';

void main() {
  test('close is one bounded no-argument command with no replay', () async {
    final raw = <String, Object?>{
      'invocationId': 'play_${'0' * 32}',
      'command': 'close',
    };
    final command = CompanionProbeCommand.parse(raw);
    expect(
      () => CompanionProbeCommand.parse({...raw, 'value': 'home'}),
      throwsFormatException,
    );
    var closed = 0;
    final host = CompanionProbeHost(
      admission: () =>
          () => true,
      execute: (_, _) async {
        closed++;
        return {'pageCurrent': false, 'modelCallsKnown': false};
      },
    );
    host.submit(command.encoded, host.instance);
    await Future<void>.delayed(Duration.zero);
    host.submit(command.encoded, host.instance);
    expect(closed, 1);
    final receipt = host.read(command.invocationId, command.digest);
    expect(receipt['status'], 'completed');
    expect((receipt['snapshot'] as Map)['modelCalls'], isNull);
  });
}

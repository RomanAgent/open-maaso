import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('startup registers and starts the presence service after first frame', () {
    final main = File('lib/main.dart').readAsStringSync();

    expect(
      main,
      contains(
        "import 'package:maaso/src/core/services/agent_presence_service.dart';",
      ),
    );
    expect(main, contains('AgentPresenceService('));
    expect(main, contains('await presence.restore()'));
    expect(main, contains('presence.start()'));
  });

  test('presence service gets runtime state through startup injection', () {
    final presence = File(
      'lib/src/core/services/agent_presence_service.dart',
    ).readAsStringSync();
    final main = File('lib/main.dart').readAsStringSync();

    expect(
      presence,
      isNot(
        contains(
          "import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';",
        ),
      ),
    );
    expect(
      presence,
      isNot(contains('appServices.find<AgentRuntimeRegistry>()')),
    );
    expect(main, contains('AgentPresenceService('));
    expect(main, contains('runtimeBusy:'));
    expect(main, contains('appServices.find<AgentRuntimeRegistry>()'));
    expect(main, contains(".get('self')"));
  });

  test('home controller reports user turns and input activity to presence', () {
    final controller = File(
      'lib/src/features/home/application/home_controller.dart',
    ).readAsStringSync();

    expect(
      controller,
      contains(
        "import 'package:maaso/src/core/services/agent_presence_service.dart';",
      ),
    );
    expect(controller, contains('observeUserTurn(text)'));
    expect(
      controller,
      contains('void observeInputActivity(PresenceInputActivityKind kind)'),
    );
    expect(controller, contains('observeInputActivity(kind)'));
  });

  test('home page passes input activity events into the chat bar', () {
    final page = File(
      'lib/src/features/home/presentation/home_page.dart',
    ).readAsStringSync();

    expect(page, contains('onInputActivity: (kind) {'));
    expect(page, contains('c.observeInputActivity(kind);'));
  });

  test('chat input emits text and voice activity signals', () {
    final input = File(
      'lib/src/core/widgets/chat_input_bar.dart',
    ).readAsStringSync();

    expect(
      input,
      contains(
        "import 'package:maaso/src/core/services/agent_presence_service.dart';",
      ),
    );
    expect(
      input,
      contains('ValueChanged<PresenceInputActivityKind>? onInputActivity'),
    );
    expect(input, contains('PresenceInputActivityKind.tap'));
    expect(input, contains('PresenceInputActivityKind.typing'));
    expect(input, contains('PresenceInputActivityKind.voiceModeEntry'));
    expect(input, contains('PresenceInputActivityKind.voiceUtteranceEnded'));
  });
}

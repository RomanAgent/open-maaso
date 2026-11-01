import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_host_command_router.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';

void main() {
  final command = AppControlHostCommand.host(
    actionId: 'app_control.memory_ledger.accept_memory',
    pageActionId: 'accept_memory',
    targetRoute: '/memory-ledger',
    target: '/memory-ledger#accept_memory:memory:episode-1',
    arguments: const <String, Object?>{
      'episodeId': 1,
      'expectedHeadEpisodeId': 1,
      'expectedRevision': 1,
    },
  );

  test('supports a command only when exactly one delegate supports it', () {
    final none = _FakeExecutor();
    final first = _FakeExecutor(supported: true);
    final second = _FakeExecutor(supported: true);

    expect(
      AppControlHostCommandRouter(
        <AppControlHostCommandExecutor>[],
      ).supports(command),
      isFalse,
    );
    expect(
      AppControlHostCommandRouter(<AppControlHostCommandExecutor>[
        none,
      ]).supports(command),
      isFalse,
    );
    expect(
      AppControlHostCommandRouter(<AppControlHostCommandExecutor>[
        first,
      ]).supports(command),
      isTrue,
    );
    expect(
      AppControlHostCommandRouter(<AppControlHostCommandExecutor>[
        first,
        second,
      ]).supports(command),
      isFalse,
    );
  });

  test('routes execution to the sole matching delegate', () async {
    final ignored = _FakeExecutor();
    final matched = _FakeExecutor(supported: true);
    final router = AppControlHostCommandRouter(<AppControlHostCommandExecutor>[
      ignored,
      matched,
    ]);

    final result = await router.execute(
      command: command,
      executionContext: _context(),
    );

    expect(result.isSuccess, isTrue);
    expect(ignored.executeCalls, 0);
    expect(matched.executeCalls, 1);
  });

  test(
    'zero and ambiguous matches fail closed without delegate execution',
    () async {
      final unsupported = _FakeExecutor();
      final first = _FakeExecutor(supported: true);
      final second = _FakeExecutor(supported: true);

      final noMatch = await AppControlHostCommandRouter(
        <AppControlHostCommandExecutor>[unsupported],
      ).execute(command: command, executionContext: _context());
      final ambiguous = await AppControlHostCommandRouter(
        <AppControlHostCommandExecutor>[first, second],
      ).execute(command: command, executionContext: _context());

      expect(noMatch.status, AgentUiControlResultStatus.pageNotReady);
      expect(ambiguous.status, AgentUiControlResultStatus.pageNotReady);
      expect(unsupported.executeCalls, 0);
      expect(first.executeCalls, 0);
      expect(second.executeCalls, 0);
    },
  );

  test('support drift before execute is rechecked and fails closed', () async {
    final delegate = _FakeExecutor(supported: true);
    final router = AppControlHostCommandRouter(<AppControlHostCommandExecutor>[
      delegate,
    ]);
    expect(router.supports(command), isTrue);

    delegate.supported = false;
    final result = await router.execute(
      command: command,
      executionContext: _context(),
    );

    expect(result.status, AgentUiControlResultStatus.pageNotReady);
    expect(delegate.executeCalls, 0);
  });
}

AppControlActionExecutionContext _context() =>
    AppControlActionExecutionContext.host(
      requiresCommit: true,
      authorityIsCurrent: () => true,
      staleCode: 'approval_stale',
      recordExecutionStarted: () => true,
    );

final class _FakeExecutor implements AppControlHostCommandExecutor {
  _FakeExecutor({this.supported = false});

  bool supported;
  int executeCalls = 0;

  @override
  bool supports(AppControlHostCommand command) => supported;

  @override
  Future<AgentUiControlResult<Map<String, Object?>>> execute({
    required AppControlHostCommand command,
    required AppControlActionExecutionContext executionContext,
  }) async {
    executeCalls += 1;
    return AgentUiControlResult<Map<String, Object?>>.success(
      const <String, Object?>{'ok': true},
    );
  }
}

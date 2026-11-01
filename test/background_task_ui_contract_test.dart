import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('home controller exposes background task job status and actions', () {
    final source = File(
      'lib/src/features/home/application/home_controller.dart',
    ).readAsStringSync();

    expect(
      source,
      contains(
        "import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';",
      ),
    );
    expect(source, contains('Rxn<AgentTaskJob> latestTaskJob'));
    expect(
      source,
      contains('StreamSubscription<AgentTaskJobEvent>? _taskJobSub'),
    );
    expect(source, contains('taskJobs.events.listen(_onTaskJobEvent)'));
    expect(source, contains('_latestTaskJobForCurrentScope(taskJobs)'));
    expect(
      source,
      contains('statuses: const {AgentTaskJobStatus.awaitingInput}'),
    );
    expect(source, contains('statuses: const {AgentTaskJobStatus.running}'));
    expect(source, contains('appletScopeKey: scopeKey'));
    expect(
      source,
      contains(
        'event.job.appletScopeKey != '
        'AppletLocalOwnership.currentScopeKey()',
      ),
    );
    expect(source, contains('void dismissTaskJobStatus()'));
    expect(source, contains('Future<void> retryLatestTaskJob()'));
    expect(source, contains('Future<void> cancelLatestTaskJob()'));
    expect(source, contains('cancelBackgroundTaskJob'));
    expect(source, contains('runtime.retryBackgroundTaskJob('));
    expect(
      source,
      contains('controls!.retry(server.id, expectedAttempt: expectedAttempt)'),
    );
    expect(source, contains('server.attempt == expectedAttempt'));
    expect(source, contains('_taskJobs.controlsFor(server!)'));
    expect(
      source,
      contains('controls?.canControl(server, retry: true) == true'),
    );
    expect(
      source,
      contains('controls?.canControl(server, retry: false) == true'),
    );
    expect(source, contains('if (busy || !_canExecuteHere) return;'));
    expect(source, contains('job.appletScopeKey == _appletScopeKey'));
    expect(source, contains('final activeTaskJobs = _taskJobs.jobs'));
    expect(source, contains('await Future.wait<void>('));
    expect(source, contains('activeTaskJobs.map('));
    expect(
      source,
      contains('(job) => _runtime?.cancelBackgroundTaskJob(job.id)'),
    );
    expect(
      source,
      contains(
        'latestTaskJob.value?.status == AgentTaskJobStatus.awaitingInput',
      ),
    );
  });

  test(
    'home keeps task history contextual instead of an independent overlay',
    () {
      final source = File(
        'lib/src/features/home/presentation/home_page.dart',
      ).readAsStringSync();

      expect(source, isNot(contains('_TaskJobStatusBar')));
      expect(source, isNot(contains('home-task-ledger')));
      expect(source, contains("ValueKey('home-menu-task-history')"));
      expect(source, contains('onTaskHistory: _openTaskHistory'));
      expect(source, contains('AgentCardStack('));
      expect(source, contains('showLatestReply: false'));

      final todoIndex = source.indexOf('_TodoCard()');
      final cardStackIndex = source.indexOf('AgentCardStack(');
      expect(todoIndex, greaterThanOrEqualTo(0));
      expect(cardStackIndex, greaterThan(todoIndex));
    },
  );

  test(
    'runtime does not mirror background task status into thought bubble',
    () {
      final source = File(
        'lib/src/features/agent/application/agent_runtime.dart',
      ).readAsStringSync();

      expect(
        source,
        isNot(
          contains('_thinking.add(_taskJobs.latestStatusText(job.agentId))'),
        ),
      );
    },
  );

  test('awaiting task feedback is localized in English and Chinese', () {
    final english = File(
      'lib/src/core/localization/secondary_en_us.dart',
    ).readAsStringSync();
    final chinese = File(
      'lib/src/core/localization/secondary_zh_cn.dart',
    ).readAsStringSync();

    for (final source in [english, chinese]) {
      expect(source, contains("'home.task.awaiting_input'"));
      expect(source, contains("'home.task.awaiting_input_message'"));
      expect(source, contains("'agent_runtime.background_game_clarification'"));
      expect(
        source,
        contains("'agent_runtime.background_surface_clarification'"),
      );
      expect(source, contains("'agent_runtime.background_missing_applet'"));
      expect(source, contains("'agent_runtime.background_task_resumed'"));
      expect(source, contains("'agent_runtime.awaiting_input_cancelled'"));
    }
  });

  test(
    'latest reply bubble uses the same transparent chrome glass as input',
    () {
      final source = File(
        'lib/src/core/widgets/agent_card_stack.dart',
      ).readAsStringSync();
      final start = source.indexOf('class _LatestReplyBubble');
      final end = source.indexOf('class _FooterButton');

      expect(start, greaterThanOrEqualTo(0));
      expect(end, greaterThan(start));

      final bubbleSource = source.substring(start, end);
      expect(bubbleSource, contains('role: AppGlassSurfaceRole.chrome'));
      expect(
        bubbleSource,
        contains('behavior: AppGlassSurfaceBehavior.staticSurface'),
      );
      expect(bubbleSource, isNot(contains('panelTintOpacity: 1.0')));
      expect(bubbleSource, isNot(contains('tintColor: Colors.white')));
    },
  );
}

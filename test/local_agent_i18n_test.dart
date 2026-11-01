import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/local_agent_runtime.dart';
import 'package:maaso/src/features/agent/application/local_model_action_planner.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/localization/en_us.dart';
import 'package:maaso/src/core/localization/zh_cn.dart';

void main() {
  test('planner fallback ask resolves through the configured localization', () {
    final action = LocalModelActionPlanner.parseAction(
      'not-json',
      locale: AppLocale.en,
    );
    expect(action.type, LocalAgentActionType.ask);
    expect(action.question, enUS['home.local_agent_clarify']);
  });

  test('local-agent fallback strings exist in both locales', () {
    for (final key in [
      'home.local_agent_clarify',
      'home.local_agent_commit_required',
    ]) {
      expect(enUS[key], isNotNull, reason: 'enUS missing $key');
      expect(zhCH[key], isNotNull, reason: 'zhCH missing $key');
    }
  });

  test('local planner localizes built-in manifest summaries', () async {
    List<({String role, String content})>? captured;
    final planner = LocalModelActionPlanner(
      localeProvider: () => AppLocale.zh,
      complete: (messages) async {
        captured = messages;
        return '{"type":"finish","text":"ok"}';
      },
    );

    await planner.next(
      const LocalAgentTurn(
        userText: '做一个清单',
        step: 1,
        candidates: [
          LocalSkillManifest(
            id: 'todo',
            skillName: 'Todo',
            method: 'todo_addMany',
            summary: 'Create a visible local checklist for multi-step work.',
            tags: ['todo'],
            argsSchema: {'type': 'array'},
          ),
        ],
        observations: [],
      ),
    );

    expect(captured!.first.content, contains('手机本地任务智能体'));
    expect(captured!.last.content, contains('创建可见的本地待办清单'));
    expect(captured!.last.content, isNot(contains('Create a visible')));
  });
}

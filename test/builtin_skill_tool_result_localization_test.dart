import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/local_skill_invoker.dart';
import 'package:maaso/src/features/agent/application/local_skill_manifest.dart';
import 'package:maaso/src/features/agent/application/skills/todo_skill.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill.dart';
import 'package:maaso/src/features/agent/data/skills/skill_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    appServices.testMode = true;
    appServices.reset();
    appServices.put(SecureStorageService());
    appServices.put(LocaleConfigService());
  });

  tearDown(appServices.reset);

  test(
    'built-in Skill source rejects model-visible host prose outside catalog',
    () {
      final files = <File>[
        ...Directory('lib/src/features/agent/application/skills')
            .listSync()
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart')),
        File('lib/src/features/agent/application/maaso_tts_plugin.dart'),
        File('lib/src/core/services/delayed_choice_executor.dart'),
        File('lib/src/features/agent/data/skills/tool_call_runner.dart'),
        for (final name in const [
          'alert_skill.dart',
          'face_skill.dart',
          'memory_skill.dart',
        ])
          File('lib/src/features/agent/data/skills/$name'),
      ];
      const dynamicErrorAllowlist = <String, Set<String>>{
        // Tool metadata documents the JSON shape with an ellipsis; it is not a
        // runtime result expression.
        'app_navigate_skill.dart': {'..'},
        // AgentUiControlResult.reason is an exhaustive enum-to-snake-case
        // mapping; raw coordinator messages and errors are never serialized.
        'app_control_skill.dart': {'code'},
        'avatar_camera_skill.dart': {'code'},
        // Both ternary branches are fixed snake_case protocol values; the
        // exception itself is never serialized.
        'applet_discovery_skill.dart': {'error is FormatException'},
        // Creator validates every dynamic service/state code against the
        // stable snake_case protocol before serializing it.
        // CompanionActivity's private helper is only called with fixed
        // snake_case protocol literals; it never serializes exception text.
        'companion_activity_skill.dart': {'code'},
        'creator_skill.dart': {'code'},
        'freeform_surface_skill.dart': {'code'},
        'http_skill.dart': {'reject'},
        // Contract failures are length-bounded to the protocol alphabet, with
        // a fixed execution_failed fallback; display/error prose is excluded.
        'delayed_choice_executor.dart': {'_typedContractFailureCode(result)'},
        'device_handoff_skill.dart': {'code'},
        // ProjectControl's private helper accepts fixed protocol literals or
        // a member of its explicit service-error allowlist, never raw errors.
        'project_control_skill.dart': {'code'},
        'scheduled_task_skill.dart': {'code'},
      };
      const freeTextFieldAllowlist = <String, Set<String>>{
        // These values originate outside the host prompt catalog and must remain
        // byte-for-byte unchanged.
        'app_navigate_skill.dart': {'message'},
        // Preserve the existing no-contract/off/shadow validation payload.
        // Enforce adapts failures to a redacted ToolOutcome protocol code.
        'companion_activity_skill.dart': {'message'},
        // Creator summary and prepared body are model/user-authored or loaded
        // from the current owner's selected draft; neither is host prose.
        'creator_skill.dart': {'body', 'summary'},
        // Both values are assembled by DelayedChoicePolicy from the prompt
        // catalog before they are stored on the branch.
        'delayed_choice_executor.dart': {'summary'},
        'http_skill.dart': {'body'},
      };
      final errorAssignment = RegExp(r'''["']error["']\s*:\s*([^,}\n]+)''');
      final quotedValue = RegExp(r'''^["']([^"']*)["']$''');
      final snakeCase = RegExp(r'^[a-z][a-z0-9_]*$');
      final modelTextAssignment = RegExp(
        r'''["'](message|summary|packing|body|translation|condition|advice)["']\s*:\s*([^,}\n]+)''',
      );

      for (final file in files) {
        final name = file.uri.pathSegments.last;
        final source = _withoutComments(file.readAsStringSync());
        for (final match in errorAssignment.allMatches(source)) {
          final expression = match.group(1)!.trim();
          final literal = quotedValue.firstMatch(expression)?.group(1);
          if (literal != null) {
            expect(
              snakeCase.hasMatch(literal),
              isTrue,
              reason: '$name exposes non-protocol error text: $literal',
            );
            continue;
          }
          final allowed = dynamicErrorAllowlist[name] ?? const <String>{};
          expect(
            allowed,
            contains(expression),
            reason: '$name has an unreviewed dynamic error value: $expression',
          );
        }

        for (final match in modelTextAssignment.allMatches(source)) {
          final field = match.group(1)!;
          final expression = match.group(2)!.trim();
          expect(
            quotedValue.hasMatch(expression),
            isFalse,
            reason: '$name hard-codes model-visible $field text: $expression',
          );
          if (expression.startsWith('AgentPromptCatalog.text(')) continue;
          expect(
            freeTextFieldAllowlist[name] ?? const <String>{},
            contains(field),
            reason: '$name has an unreviewed model-visible $field source',
          );
        }

        expect(
          RegExp(
            r'''["']error["']\s*:\s*[^,}\n]*(?:\.toString\(\)|\.message)''',
          ).hasMatch(source),
          isFalse,
          reason: '$name leaks an exception into a model-visible error',
        );
      }
    },
  );

  test('validation failures use locale-independent protocol codes', () {
    final todo =
        jsonDecode(
              TodoSkill().methods['todo_addMany']!(const <dynamic>[]) as String,
            )
            as Map<String, dynamic>;

    expect(todo, {'error': 'missing_items'});
  });

  test('Skill execution keeps its explicit locale across an await', () async {
    final locale = appServices.find<LocaleConfigService>();
    locale.locale.value = AppLocale.zh;
    final gate = Completer<void>();
    final skill = _LocaleScopeSkill(gate.future);
    final manager = SkillManager()..registerSkill(skill);
    final pending = manager.invokeTool(
      SkillManager.nativeToolName(skill, 'execute'),
      const <String, dynamic>{},
      locale: AppLocale.zh,
    );

    locale.locale.value = AppLocale.en;
    gate.complete();
    final decoded = jsonDecode(await pending) as Map<String, dynamic>;

    expect(
      decoded['message'],
      AgentPromptCatalog.text('app.memory.soul.header', locale: AppLocale.zh),
    );
    expect(
      decoded['message'],
      isNot(
        AgentPromptCatalog.text('app.memory.soul.header', locale: AppLocale.en),
      ),
    );
  });

  test(
    'local invoker logs exceptions but returns only a stable code',
    () async {
      final manager = SkillManager()..registerSkill(_ThrowingSkill());
      const manifest = LocalSkillManifest(
        id: 'throwing',
        skillName: 'Throwing',
        method: 'run',
        summary: 'test',
        tags: ['test'],
        argsSchema: <String, dynamic>{'type': 'object'},
        risk: LocalSkillRisk.read,
      );

      final result = await LocalSkillInvoker(
        skillManager: manager,
      ).invoke(manifest, const <String, dynamic>{});

      expect(result.status, LocalSkillResultStatus.error);
      expect(jsonDecode(result.output), {'error': 'execution_failed'});
      expect(result.output, isNot(contains('sensitive diagnostic')));
    },
  );
}

String _withoutComments(String source) => source
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .split('\n')
    .where((line) => !line.trimLeft().startsWith('//'))
    .join('\n');

class _ThrowingSkill extends AgentSkill {
  @override
  String get skillName => 'Throwing';

  @override
  String get description => 'test';

  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'run': (_) => throw StateError('sensitive diagnostic'),
  };
}

class _LocaleScopeSkill extends AgentSkill {
  _LocaleScopeSkill(this._gate);
  final Future<void> _gate;
  @override
  String get skillName => 'LocaleScope';
  @override
  String get description => 'Test invocation-local resource selection.';
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'execute': (_) async {
      await _gate;
      return jsonEncode({
        'message': AgentPromptCatalog.text('app.memory.soul.header'),
      });
    },
  };
  @override
  Map<String, Map<String, dynamic>> get nativeToolSchemas => {
    'execute': {
      'type': 'object',
      'properties': <String, Object?>{},
      'additionalProperties': false,
    },
  };
}

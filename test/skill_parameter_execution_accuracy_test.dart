import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/todo_service.dart';
import 'package:maaso/src/features/agent/application/skills/todo_skill.dart';
import '../tool/skill_routing_accuracy/evaluate_parameters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'frozen parameter/executor report uses real local effects without external calls',
    () async {
      final report = await evaluateSkillParametersAndExecution();
      final metrics = report['metrics'] as Map;
      expect(report['schemaVersion'], 2);
      expect(report['corpusPath'], parameterCorpusPath);
      expect(metrics['cases'], 38);
      expect(metrics['fixedProtocolCases'], 38);
      expect(metrics['preflightBoundaryAccuracy'], 1);
      expect(metrics['dispatchBoundaryAccuracy'], 1);
      expect(metrics['realLocalGoalCases'], 12);
      expect(metrics['localExecutionSuccessGivenFixedArguments'], 1);
      expect(metrics['prohibitedDispatchCases'], 22);
      expect(metrics['unexpectedHandlerDispatches'], 0);
      expect(metrics.containsKey('deterministicParserCases'), isFalse);
      expect(
        (report['results'] as List).cast<Map>().every(
          (row) => row['track'] == 'structured_local_executor',
        ),
        isTrue,
      );
      expect(metrics['realModelArgumentAccuracy'], isNull);
      expect(metrics['realModelEndToEndExecutionSuccess'], isNull);
      expect((report['scope'] as Map)['externalCalls'], 0);
      expect((report['scope'] as Map)['deviceCommands'], 0);
      expect((report['scope'] as Map)['networkAttempts'], 0);
      expect(metrics['calibrationCases'], 2);
      expect(metrics['wrongArgumentControlsDetected'], 2);
      const path = String.fromEnvironment('MAASO_PARAMETER_EXECUTION_REPORT');
      if (path.isNotEmpty) {
        final file = File(path);
        if (file.existsSync()) {
          throw StateError('Refusing to overwrite frozen evidence');
        }
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        );
      }
      stdout.writeln('SKILL_PARAMETER_EXECUTION ${jsonEncode(metrics)}');
    },
  );
  test('metric denominators retain failed goals and prohibited dispatches', () {
    final metrics = summarizeParameterExecution([
      {
        'track': 'structured_local_executor',
        'successFixture': true,
        'goalCorrect': false,
        'preflightBoundaryCorrect': true,
        'dispatchBoundaryCorrect': true,
        'handlerDispatches': 1,
      },
      {
        'track': 'structured_local_executor',
        'mustNotDispatch': true,
        'handlerDispatches': 1,
        'preflightBoundaryCorrect': false,
        'dispatchBoundaryCorrect': false,
      },
    ]);
    expect(metrics['localExecutionSuccessGivenFixedArguments'], 0);
    expect(metrics['unexpectedHandlerDispatches'], 1);
    expect(metrics['realModelEndToEndExecutionSuccess'], isNull);
  });

  test(
    'Todo keeps legacy positional calls and rejects partial invalid lists',
    () {
      appServices.reset();
      appServices.testMode = true;
      final service = appServices.put(TodoService());
      final skill = TodoSkill();
      final add = skill.methods['todo_add']!;
      final addMany = skill.methods['todo_addMany']!;
      final complete = skill.methods['todo_complete']!;
      final completeIndex = skill.methods['todo_completeIndex']!;

      expect(jsonDecode(add(['legacy item']))['id'], 't1');
      expect(service.items.single.text, 'legacy item');
      expect(
        jsonDecode(addMany(['["valid",7]']))['error'],
        'expected_nonempty_string_array',
      );
      expect(
        service.items.length,
        1,
        reason: 'invalid batch cannot partially write',
      );
      expect(jsonDecode(addMany(['["second"]']))['ids'], ['t2']);
      expect(jsonDecode(complete(['t1']))['status'], 'ok');
      expect(jsonDecode(completeIndex([2]))['status'], 'ok');
      expect(service.items.every((item) => item.done), isTrue);
      expect(
        skill.nativeToolSchemas,
        isNull,
        reason: 'Todo schemas are structured-prompt only',
      );
      appServices.reset();
    },
  );

  test('frozen v2 corpus contains only retained Todo protocol fixtures', () {
    final corpus =
        jsonDecode(File(parameterCorpusPath).readAsStringSync()) as Map;
    final cases = (corpus['cases'] as List).cast<Map>();
    expect(cases.map((sample) => sample['id']).toSet(), hasLength(38));
    for (final sample in cases) {
      if (sample['scenarioId'] == 'invalid-json' ||
          sample['scenarioId'] == 'wrong-envelope') {
        continue;
      }
      final envelope = jsonDecode(sample['modelOutput'] as String) as Map;
      for (final action in (envelope['actions'] as List).cast<Map>()) {
        expect(action['type'], 'skill.call');
        expect(action['tool'], startsWith('skill_todo_'));
      }
    }
  });
}

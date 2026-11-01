import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/skill_catalog.dart';

import '../tool/skill_routing_accuracy/evaluate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'accuracy corpus is fixed, bilingual, split by scenario and independently labelled',
    () {
      final bytes = File(routingCorpusPath).readAsBytesSync();
      expect(
        sha256.convert(bytes).toString(),
        File(
          'tool/skill_routing_accuracy/corpus.v2.sha256',
        ).readAsStringSync().trim(),
      );
      final corpus = jsonDecode(utf8.decode(bytes)) as Map;
      expect(corpus['schemaVersion'], 2);
      final cases = (corpus['cases'] as List).cast<Map>();
      expect(cases, hasLength(160));
      expect(cases.where((row) => row['split'] == 'train'), hasLength(94));
      expect(cases.where((row) => row['split'] == 'holdout'), hasLength(66));
      expect(
        cases.any(
          (row) =>
              (row['expectedSkills'] as List).contains('WorldControl') ||
              Uri.tryParse(row['route'] as String)?.path == '/world',
        ),
        isFalse,
      );
      expect(cases.map((row) => row['id']).toSet().length, cases.length);
      expect(cases.map((row) => row['query']).toSet().length, cases.length);
      for (final scenario in cases.map((row) => row['scenarioId']).toSet()) {
        final pair = cases
            .where((row) => row['scenarioId'] == scenario)
            .toList();
        expect(pair.map((row) => row['locale']).toSet(), {'zh', 'en'});
        expect(pair.map((row) => row['split']).toSet(), hasLength(1));
      }
      expect(
        cases.map((row) => row['category']).toSet(),
        containsAll([
          'colloquial',
          'alias',
          'page',
          'followup',
          'missing_arguments',
          'negative',
          'ambiguous',
        ]),
      );
      expect(
        cases
            .where((row) => row['category'] == 'followup')
            .every((row) => (row['history'] as List).isNotEmpty),
        isTrue,
      );
    },
  );

  test('active bilingual corpus targets match retained host capabilities', () {
    final activeHostNames = {
      for (final spec in SkillCatalog.all)
        if (spec.isAvailable && spec.hostRouting != null)
          spec.hostRouting!.skillName,
    };
    const retiredNames = {
      'RealWeather',
      'TripPlan',
      'SetTheme',
      'Calc',
      'AvatarMotionLearning',
      'Translate',
      'Creator',
    };
    for (final path in [routingCorpusPath, routingChallengeCorpusPath]) {
      final corpus = jsonDecode(File(path).readAsStringSync()) as Map;
      final cases = (corpus['cases'] as List).cast<Map>();
      for (final sample in cases) {
        final expected = (sample['expectedSkills'] as List).cast<String>();
        final support = ((sample['allowedSupportSkills'] as List?) ?? const [])
            .cast<String>();
        expect(
          activeHostNames.containsAll({...expected, ...support}),
          isTrue,
          reason:
              '${sample['id']}: every target must have an available host definition',
        );
        expect(
          {...expected, ...support}.intersection(retiredNames),
          isEmpty,
          reason: sample['id'] as String,
        );
      }
    }
  });

  test(
    'production selector produces a reproducible accuracy report without execution',
    () {
      const split = String.fromEnvironment(
        'MAASO_SKILL_EVAL_SPLIT',
        defaultValue: 'train',
      );
      const output = String.fromEnvironment('MAASO_SKILL_EVAL_REPORT');
      const corpusPath = String.fromEnvironment(
        'MAASO_SKILL_EVAL_CORPUS',
        defaultValue: routingCorpusPath,
      );
      const snapshot = String.fromEnvironment('MAASO_SKILL_EVAL_SNAPSHOT');
      final frozenCatalog = snapshot.isEmpty
          ? null
          : (jsonDecode(File(snapshot).readAsStringSync())
                    as Map<String, dynamic>)['catalog']
                as Map<String, dynamic>;
      final report = evaluateSkillRoutingAccuracy(
        split: split,
        frozenCatalog: frozenCatalog,
        corpusPath: corpusPath,
      );
      expect((report['metrics'] as Map)['cases'], greaterThan(0));
      expect(
        (report['results'] as List).cast<Map>().every(
          (row) =>
              row['argumentsEvaluated'] == false &&
              row['executionEvaluated'] == false,
        ),
        isTrue,
      );
      if (output.isNotEmpty) {
        final file = File(output);
        if (file.existsSync()) {
          throw StateError('Refusing to overwrite frozen evaluation: $output');
        }
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(report)}\n',
        );
      }
      stdout.writeln(
        'SKILL_ROUTING_ACCURACY ${jsonEncode({'split': split, 'metrics': report['metrics'], 'byLocale': report['byLocale'], 'corpusSha256': report['corpusSha256'], 'catalogSha256': report['catalogSha256']})}',
      );
    },
  );
}

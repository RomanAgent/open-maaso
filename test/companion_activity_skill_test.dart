import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/maaso_feature_flag_service.dart';
import 'package:maaso/src/features/agent/application/skills/companion_activity_skill.dart';
import 'package:maaso/src/features/companion_activity/application/companion_activity_service.dart';
import 'package:maaso/src/features/companion_activity/data/companion_activity_store.dart';
import 'package:maaso/src/features/companion_activity/domain/companion_activity_models.dart';
import 'package:sembast/sembast_memory.dart';
import 'package:timezone/data/latest.dart' as tz_data;

void main() {
  setUpAll(tz_data.initializeTimeZones);

  Future<(CompanionActivityService, CompanionActivitySkill)> subject() async {
    final scope = ActivityScope(accountId: 'account-a', facadeGeneration: 1);
    final database = await databaseFactoryMemory.openDatabase(
      'companion_skill_${DateTime.now().microsecondsSinceEpoch}.db',
    );
    final service = CompanionActivityService(
      store: SembastCompanionActivityStore(database: database, scope: scope),
      rolloutMode: () => FeatureRolloutMode.enforce,
    );
    final template = ActivityTaskTemplate(
      id: 'template-walk',
      scope: scope,
      title: 'Walk together',
      cadence: ActivityCadence.daily,
      defaultAwardPoints: 20,
    );
    await service.registerTemplate(
      operationId: 'template-1',
      template: template,
      recurrence: ActivityRecurrenceRule(
        timeZoneId: 'Etc/UTC',
        offsetAtCreationMinutes: 0,
        localStartMinute: 8 * 60,
        firstLocalDate: ActivityLocalDate(2026, 8, 30),
      ),
    );
    return (
      service,
      CompanionActivitySkill(
        service: service,
        clock: () => DateTime.utc(2026, 8, 30, 9),
      ),
    );
  }

  test('exposes only bounded read-only summary and surface methods', () async {
    final (_, skill) = await subject();

    expect(skill.skillName, 'CompanionActivity');
    expect(skill.methods.keys, <String>[
      'activitySummary',
      'activityBuildSurface',
    ]);
    expect(skill.nativeToolSchemas.keys, skill.methods.keys);
    expect(skill.methods.keys, isNot(contains('activityCreateOccurrence')));
    expect(skill.methods.keys, isNot(contains('reviewEvidence')));
    expect(skill.methods.keys, isNot(contains('redeem')));
    expect(skill.description, contains('cannot create occurrences'));
    expect(skill.description, contains('approve evidence'));
  });

  test(
    'summary is bounded and buildSurface returns persistable widget',
    () async {
      final (service, skill) = await subject();
      await service.createOccurrence(
        operationId: 'occurrence-1',
        templateId: 'template-walk',
        localDate: ActivityLocalDate(2026, 8, 30),
      );

      final summary =
          jsonDecode(
                await skill.methods['activitySummary']!(<dynamic>[
                      jsonEncode(<String, Object?>{'asOf': '2026-08-30'}),
                    ])
                    as String,
              )
              as Map;
      final surface =
          jsonDecode(
                await skill.methods['activityBuildSurface']!(<dynamic>[
                      jsonEncode(<String, Object?>{'asOf': '2026-08-30'}),
                    ])
                    as String,
              )
              as Map;

      expect(summary['status'], 'ok');
      expect(summary['balance'], 0);
      expect(summary['tasks'], hasLength(1));
      expect(surface['status'], 'ok');
      expect((surface['widget'] as Map)['kind'], 'surface');
      expect((surface['surface'] as Map)['rendering'], 'dom');
      expect((surface['surface'] as Map)['js'], isEmpty);
      expect(jsonEncode(surface).toLowerCase(), isNot(contains('https://')));
    },
  );

  test('malformed arguments return machine-readable errors', () async {
    final (_, skill) = await subject();

    final missing =
        jsonDecode(
              await skill.methods['activitySummary']!(<dynamic>[]) as String,
            )
            as Map;
    final invalidDate =
        jsonDecode(
              await skill.methods['activitySummary']!(<dynamic>[
                    jsonEncode(<String, Object?>{'asOf': 'not-a-date'}),
                  ])
                  as String,
            )
            as Map;
    final extraField =
        jsonDecode(
              await skill.methods['activitySummary']!(<dynamic>[
                    jsonEncode(<String, Object?>{
                      'asOf': '2026-08-30',
                      'approveEvidence': true,
                    }),
                  ])
                  as String,
            )
            as Map;

    expect(missing, <String, Object?>{
      'error': 'invalid_arguments',
      'message': 'expected exactly one argument object',
    });
    expect(invalidDate, <String, Object?>{
      'error': 'invalid_arguments',
      'message': 'invalid activity local date',
    });
    expect(extraField, <String, Object?>{
      'error': 'invalid_arguments',
      'message': 'unexpected argument field',
    });
  });
}

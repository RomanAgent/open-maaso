import 'dart:convert';
import 'dart:io';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';

const projectBuildV2TestScope = 'test|owner';
const projectBuildV2OtherRun = 'pb_run_00000000-0000-0000-0000-000000000004';

Map<String, Object?> projectBuildV2WireFixture() => projectBuildV2Object(
  jsonDecode(
    File(
      'tool/fixtures/project_build_wire_v1.json',
    ).readAsStringSync().replaceAll('"schemaVersion": 1', '"schemaVersion": 2'),
  ),
);
ProjectBuildV2CreateRequest projectBuildV2Input() =>
    ProjectBuildV2CreateRequest.fromJson(
      projectBuildV2Object(projectBuildV2WireFixture()['createRequest']),
    );
ProjectBuildV2Receipt projectBuildV2Receipt() => ProjectBuildV2Receipt.fromJson(
  projectBuildV2Object(projectBuildV2WireFixture()['createReceipt']),
);
List<Map<String, Object?>> projectBuildV2Events() =>
    (projectBuildV2Object(projectBuildV2WireFixture()['eventsPage'])['events']
            as List)
        .map(projectBuildV2Object)
        .toList();
ProjectBuildV2EventPage projectBuildV2Page(
  List<Map<String, Object?>> events, {
  int after = 0,
}) => ProjectBuildV2EventPage.fromJson(
  {
    'events': events,
    'nextTaskSequence': events.isEmpty ? after : events.last['taskSequence'],
    'hasMore': false,
  },
  taskId: projectBuildV2Receipt().taskId,
  afterTaskSequence: after,
);
Map<String, Object?> projectBuildV2RetryEvent() {
  final previous = projectBuildV2Events().last;
  final snapshot = {
    ...projectBuildV2Object(previous['snapshot']),
    'runId': projectBuildV2OtherRun,
    'attempt': 2,
    'status': 'queued',
    'statusVersion': 1,
    'snapshotSequence': 1,
    'snapshotTaskSequence': 4,
    'updatedAt': '2026-09-28T06:00:03Z',
    'errorCode': '',
  };
  return {
    ...previous,
    'runId': projectBuildV2OtherRun,
    'sequence': 1,
    'taskSequence': 4,
    'type': 'run.retried',
    'at': snapshot['updatedAt'],
    'snapshot': snapshot,
  };
}

import 'dart:convert';
import 'dart:io';
import 'package:maaso/src/features/project_build/domain/project_build_contract.dart';

const projectBuildTestScope = 'test|owner';
const projectBuildOtherRun = 'pb_run_00000000-0000-0000-0000-000000000004';

Map<String, Object?> projectBuildWireFixture() => projectBuildObject(
  jsonDecode(
    File('tool/fixtures/project_build_wire_v1.json').readAsStringSync(),
  ),
);
ProjectBuildCreateRequest projectBuildInput() =>
    ProjectBuildCreateRequest.fromJson(
      projectBuildObject(projectBuildWireFixture()['createRequest']),
    );
ProjectBuildReceipt projectBuildReceipt() => ProjectBuildReceipt.fromJson(
  projectBuildObject(projectBuildWireFixture()['createReceipt']),
);
List<Map<String, Object?>> projectBuildEvents() =>
    (projectBuildObject(projectBuildWireFixture()['eventsPage'])['events']
            as List)
        .map(projectBuildObject)
        .toList();
ProjectBuildEventPage projectBuildPage(
  List<Map<String, Object?>> events, {
  int after = 0,
}) => ProjectBuildEventPage.fromJson(
  {
    'events': events,
    'nextTaskSequence': events.isEmpty ? after : events.last['taskSequence'],
    'hasMore': false,
  },
  taskId: projectBuildReceipt().taskId,
  afterTaskSequence: after,
);
Map<String, Object?> projectBuildRetryEvent() {
  final previous = projectBuildEvents().last;
  final snapshot = {
    ...projectBuildObject(previous['snapshot']),
    'runId': projectBuildOtherRun,
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
    'runId': projectBuildOtherRun,
    'sequence': 1,
    'taskSequence': 4,
    'type': 'run.retried',
    'at': snapshot['updatedAt'],
    'snapshot': snapshot,
  };
}

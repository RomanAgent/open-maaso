import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/project_build/domain/project_build_contract.dart';
import 'support/project_build_fixtures.dart';

void main() {
  test('shared Go/Dart wire fixture decodes and round trips typed state', () {
    final fixture = projectBuildWireFixture();
    final input = projectBuildInput();
    expect(input.toJson(), fixture['createRequest']);
    final receipt = projectBuildReceipt();
    expect(receipt.toJson(), fixture['createReceipt']);
    final page = ProjectBuildEventPage.fromJson(
      projectBuildObject(fixture['eventsPage']),
      taskId: receipt.taskId,
      afterTaskSequence: 0,
    );
    expect(page.events.map((event) => event.snapshot.status), [
      ProjectBuildStatus.queued,
      ProjectBuildStatus.running,
      ProjectBuildStatus.failed,
    ]);
    for (final event in page.events) {
      expect(
        ProjectBuildEvent.fromJson(event.toJson()).sameEvent(event),
        isTrue,
      );
    }
    expect(page.nextTaskSequence, 3);
    final snapshot = ProjectBuildSnapshot.fromJson(
      projectBuildObject(fixture['snapshot']),
    );
    expect(snapshot.sameState(page.events.last.snapshot), isTrue);
    for (final operation in ProjectBuildOperation.values) {
      final raw = projectBuildObject(fixture['${operation.name}Command']);
      expect(
        ProjectBuildCommand.fromJson(raw, operation: operation).toJson(),
        raw,
      );
    }
  });

  test(
    'rejects success, foreign image kind, unknown fields and unsafe counters',
    () {
      final raw = projectBuildObject(projectBuildWireFixture()['snapshot']);
      for (final patch in <Map<String, Object?>>[
        {'status': 'succeeded'},
        {'status': 'completed'},
        {'schemaVersion': 1.0},
        {'kind': 'creator_image'},
        {'result': {}},
        {'ownerScope': 'other'},
        {'attempt': 1001},
        {'snapshotTaskSequence': projectBuildMaximumSequence + 1},
        {'snapshotSequence': 1.0},
        {'taskId': 'arbitrary_id'},
        {'requirementRevision': 2},
        {'errorCode': 'raw exception: SECRET'},
      ]) {
        expect(
          () => ProjectBuildSnapshot.fromJson({...raw, ...patch}),
          throwsA(anything),
        );
      }
    },
  );

  test('page rejects gaps, cursor mismatch and empty continuation', () {
    final events = projectBuildEvents();
    expect(() => projectBuildPage([events[1]]), throwsFormatException);
    for (final raw in [
      {'events': events, 'nextTaskSequence': 4, 'hasMore': false},
      {'events': [], 'nextTaskSequence': 0, 'hasMore': true},
    ]) {
      expect(
        () => ProjectBuildEventPage.fromJson(
          raw,
          taskId: projectBuildReceipt().taskId,
          afterTaskSequence: 0,
        ),
        throwsFormatException,
      );
    }
  });

  test('input counts Unicode code points and emits canonical locale only', () {
    final base = projectBuildInput();
    ProjectBuildCreateRequest input(String text, String locale) =>
        ProjectBuildCreateRequest(
          requestId: base.requestId,
          agentId: base.agentId,
          projectKind: base.projectKind,
          requirements: text,
          locale: locale,
        );
    expect(input(List.filled(12000, '😀').join(), 'zh-Hans-CN').locale, 'zh');
    expect(
      () => input(List.filled(12001, '😀').join(), 'en'),
      throwsFormatException,
    );
    expect(input('清单', 'zh@@').locale, 'en');
    expect(input('清单', 'fr-FR').locale, 'en');
    expect(input('清单', 'ZH-cn').locale, 'zh');
  });

  test('retry resets run sequence while task cursor stays monotonic', () {
    final retry = ProjectBuildEvent.fromJson(projectBuildRetryEvent());
    expect(retry.sequence, 1);
    expect(retry.taskSequence, 4);
    expect(retry.snapshot.statusVersion, 1);
    expect(
      projectBuildPage([projectBuildRetryEvent()], after: 3).nextTaskSequence,
      4,
    );
  });
}

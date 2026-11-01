import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/project_build/application/project_build_v2_tasks.dart';
import 'package:maaso/src/features/project_build/domain/project_build_v2_contract.dart';
import 'package:maaso/src/features/project_build/presentation/project_build_saved_management.dart';

// Reuse the real repository, signed fixture and HTTP harness already exercised
// by delivery tests. Importing this library does not invoke its test main().
import 'project_build_v2_delivery_test.dart' as delivery;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late delivery.Harness h;
  late Map<String, Object?> wire;
  late AgentWidget item;
  final posts = <Map<String, Object?>>[];
  var currentHead = 2;
  Map<String, Object?> obj(Object? v) => projectBuildV2Object(v);
  String revision(String key) => obj(wire[key])['revisionId']! as String;
  Map<String, Object?> history() {
    final all = obj(wire['revisionsAfterFork']);
    return {
      ...all,
      'currentHeadVersion': currentHead,
      'currentRevisionId': (obj(wire['head$currentHead'])['projects'] as List)
          .single['currentRevisionId'],
      'revisions': (all['revisions'] as List)
          .where(
            (r) => obj(r)['revisionId'] != revision('thirdRevisionDocument'),
          )
          .toList(),
    };
  }

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    posts.clear();
    currentHead = 2;
    wire = obj(
      jsonDecode(
        File('tool/fixtures/project_head_v2_wire.json').readAsStringSync(),
      ),
    );
    h = delivery.Harness(appletScope: AppletLocalOwnership.deviceLegacyScope);
    await h.init(enabled: false);
    h.head = 4;
    h.inventory['projects'] = wire['head2'];
    h.inventory['revisions'] = history();
    for (final key in ['firstRevisionDocument', 'secondRevisionDocument']) {
      h.documents[revision(key)] = obj(wire[key]);
    }
    h.specialRequest = (request) async {
      if (request.method != 'POST') return null;
      final body = obj(jsonDecode(request.body));
      posts.add({'path': request.url.path, ...body});
      if (request.url.path.endsWith('/rollback')) {
        currentHead = 3;
        h.inventory['projects'] = wire['head3'];
        h.inventory['revisions'] = history();
        return delivery.ok({
          ...obj(wire['rollbackReceipt']),
          'requestId': body['requestId'],
        });
      }
      if (request.url.path.endsWith('/delete')) {
        h.deleted = true;
        return delivery.ok({
          ...obj(wire['deleteReceipt']),
          'requestId': body['requestId'],
          'headVersion': currentHead + 1,
          'deletedRevisionId': body['expectedRevision'],
        });
      }
      return http.Response('{}', 404);
    };
    final candidate = ProjectBuildV2Candidate.fromJson(
      obj(wire['secondRevisionDocument']),
    );
    item = AgentWidget(
      id: 7,
      agentId: 'self',
      title: 'Saved project',
      kind: 'surface',
      createdAt: DateTime.now(),
      spec: {
        'rendering': 'projectBundle',
        'surfaceId': candidate.bundle.manifest.projectId,
        'bundleReference': {
          'packageSchema': 2,
          'projectId': candidate.bundle.manifest.projectId,
          'revisionId': candidate.reference.revisionId,
          'candidateDigest': candidate.reference.candidateDigest,
          'reportDigest': candidate.reference.reportDigest,
        },
      },
    );
    AppletLocalOwnership.stamp(item);
    appServices.put<ProjectBuildV2Tasks>(h.tasks);
  });
  tearDown(() async {
    await appServices.reset();
    await h.close();
  });

  Future<void> tap(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pump();
    await tester.runAsync(() async {
      await tester.tap(finder);
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
  }

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 120; i++) {
      await tester.pump(const Duration(milliseconds: 25));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 25)),
      );
      final confirming =
          find
              .byKey(const ValueKey('project-build-delete-confirmation'))
              .evaluate()
              .isNotEmpty ||
          find
              .byKey(const ValueKey('project-build-rollback-confirmation'))
              .evaluate()
              .isNotEmpty;
      if (confirming) {
        final dialog =
            find
                .byKey(const ValueKey('project-build-delete-confirmation'))
                .evaluate()
                .isNotEmpty
            ? find.byKey(const ValueKey('project-build-delete-confirmation'))
            : find.byKey(const ValueKey('project-build-rollback-confirmation'));
        if (ModalRoute.of(tester.element(dialog))?.animation?.isCompleted ??
            true) {
          return;
        }
      }
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty &&
          (confirming ||
              find.byType(LinearProgressIndicator).evaluate().isEmpty) &&
          !tester.binding.hasScheduledFrame) {
        return;
      }
    }
    throw StateError('saved_management_fixture_did_not_settle');
  }

  Future<void> mount(
    WidgetTester tester, {
    double width = 375,
    double scale = 1,
  }) async {
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: appProviderContainer,
        child: MaterialApp(
          navigatorKey: rootNavigatorKey,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                body: TextButton(
                  key: const ValueKey('manage'),
                  onPressed: () =>
                      unawaited(showProjectBuildSavedManagement(context, item)),
                  child: const Text('Manage'),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tap(tester, find.byKey(const ValueKey('manage')));
    await settle(tester);
  }

  testWidgets(
    'viewing history never changes head; native confirmation is required for rollback',
    (tester) async {
      await mount(tester);
      expect(
        find.byKey(const ValueKey('project-build-saved-management')),
        findsOneWidget,
      );
      expect(posts, isEmpty);
      final first = revision('firstRevisionDocument');
      await tester.ensureVisible(
        find.byKey(ValueKey('project-build-open-$first')),
      );
      await tap(tester, find.byKey(ValueKey('project-build-open-$first')));
      await settle(tester);
      expect(h.presentations, 1);
      expect(posts, isEmpty);
      expect(currentHead, 2);
      await tap(tester, find.byKey(ValueKey('project-build-restore-$first')));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('project-build-rollback-confirmation')),
        findsOneWidget,
      );
      expect(posts, isEmpty);
      await tap(
        tester,
        find.byKey(const ValueKey('project-build-confirm-rollback')),
      );
      await settle(tester);
      expect(posts, hasLength(1));
      expect(posts.single['expectedHeadVersion'], 2);
      expect(posts.single['targetRevision'], first);
      expect(currentHead, 3);
      expect(
        find.byKey(ValueKey('project-build-restore-$first')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'delete cancel has no request; confirm carries the visible head version',
    (tester) async {
      await mount(tester, width: 320, scale: 2);
      await tap(tester, find.byKey(const ValueKey('project-build-delete')));
      await settle(tester);
      expect(
        find.byKey(const ValueKey('project-build-delete-confirmation')),
        findsOneWidget,
      );
      expect(posts, isEmpty);
      await tap(tester, find.text('common.cancel'.tr));
      await settle(tester);
      expect(posts, isEmpty);
      expect(h.deleted, isFalse);
      await tap(tester, find.byKey(const ValueKey('project-build-delete')));
      await settle(tester);
      await tap(
        tester,
        find.byKey(const ValueKey('project-build-confirm-delete')),
      );
      await settle(tester);
      expect(posts, hasLength(1));
      expect(posts.single['expectedHeadVersion'], 2);
      expect(
        posts.single['expectedRevision'],
        revision('secondRevisionDocument'),
      );
      expect(h.cleanupCount, 1);
      expect(h.deleted, isTrue);
      expect(
        find.byKey(const ValueKey('project-build-saved-management')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('account retirement while confirmation is open cannot dispatch', (
    tester,
  ) async {
    await mount(tester);
    await tap(tester, find.byKey(const ValueKey('project-build-delete')));
    await settle(tester);
    h.current = false;
    await tap(
      tester,
      find.byKey(const ValueKey('project-build-confirm-delete')),
    );
    await settle(tester);
    expect(posts, isEmpty);
    expect(h.deleted, isFalse);
    expect(tester.takeException(), isNull);
  });

  for (final action in ['history', 'delete', 'restore']) {
    for (final coverWithOtherPage in [false, true]) {
      testWidgets(
        'account switch closes $action management routes and preserves unrelated page=$coverWithOtherPage',
        (tester) async {
          appServices.put(SecureStorageService());
          appServices.put(AppEnvironmentService());
          final auth = appServices.put(AuthSessionService());
          await mount(tester);
          if (action == 'delete') {
            await tap(
              tester,
              find.byKey(const ValueKey('project-build-delete')),
            );
            await settle(tester);
          } else if (action == 'restore') {
            final first = revision('firstRevisionDocument');
            await tap(
              tester,
              find.byKey(ValueKey('project-build-restore-$first')),
            );
            await settle(tester);
          }
          if (coverWithOtherPage) {
            unawaited(
              rootNavigatorKey.currentState!.push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(
                    body: Text('Unrelated page', key: ValueKey('unrelated')),
                  ),
                ),
              ),
            );
            await tester.pumpAndSettle();
          }

          auth.session.value = MaasoAuthSession(
            accountUuid: 'another-account',
            accessToken: 'test-access',
            refreshToken: 'test-refresh',
            expiresAt: DateTime.now().add(const Duration(days: 1)),
          );
          await tester.pumpAndSettle();

          for (final key in [
            'project-build-saved-management',
            'project-build-delete-confirmation',
            'project-build-rollback-confirmation',
          ]) {
            expect(
              find.byKey(ValueKey(key), skipOffstage: false),
              findsNothing,
            );
          }
          if (coverWithOtherPage) {
            expect(find.byKey(const ValueKey('unrelated')), findsOneWidget);
            rootNavigatorKey.currentState!.pop();
            await tester.pumpAndSettle();
          }
          expect(find.byKey(const ValueKey('manage')), findsOneWidget);
          expect(posts, isEmpty);
          expect(h.deleted, isFalse);
          expect(currentHead, 2);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}

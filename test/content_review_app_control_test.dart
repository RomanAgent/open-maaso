import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/content_engagement/application/content_review_controller.dart';
import 'package:maaso/src/features/content_engagement/application/content_review_page_actions.dart';
import 'package:maaso/src/features/content_engagement/data/content_engagement_client.dart';
import 'package:maaso/src/features/content_engagement/domain/content_review.dart';
import 'package:maaso/src/features/content_engagement/presentation/content_review_panel.dart';
import 'package:maaso/src/features/identity/application/identity_page_adapter.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/application/identity_setup_controller.dart';
import 'package:maaso/src/features/identity/presentation/identity_setup_page.dart';
import 'identity_test_support.dart';

Map<String, Object?> _row({String? appeal}) => {
  'id': 'rv_one',
  'kind': 'comment',
  'targetId': 'article',
  'state': 'rejected',
  'version': 2,
  'createdAt': '2026-09-13T00:00:00Z',
  'commentText': 'My actual comment',
  'appealState': ?appeal,
};
http.Response _ok(Object data) =>
    http.Response(jsonEncode({'code': 'OK', 'data': data}), 200);
ContentEngagementClient _client(
  Future<http.Response> Function(http.Request) handle,
) => ContentEngagementClient(
  baseUri: () => Uri.parse('https://example.test/'),
  accountId: () => 'owner',
  accessToken: () async => 'mounted-token',
  client: MockClient(handle),
);
AppControlActionExecutionContext _authority() =>
    AppControlActionExecutionContext.host(
      requiresCommit: false,
      authorityIsCurrent: () => true,
      staleCode: 'stale',
    );
Future<IdentitySetupController> _mount(
  WidgetTester tester,
  AgentUiControlService control,
) async {
  final c = IdentitySetupController(
    service: IdentityService(
      gateway: FakeIdentityGateway(initial: identityFixture()),
    ),
  );
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: IdentitySetupPage(
          controller: c,
          route: '/identity',
          uiControl: control,
          onCompleted: (_) async {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return c;
}

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);
  testWidgets(
    'route adapter prepares visible appeal but only player submits real write',
    (tester) async {
      final requests = <http.Request>[];
      final client = _client((r) async {
        requests.add(r);
        return r.method == 'GET'
            ? _ok({
                'items': [_row()],
              })
            : _ok({
                'id': 'ra_one',
                'reviewId': 'rv_one',
                'reviewVersion': 2,
                'state': 'pending',
                'version': 1,
              });
      });
      appServices.put<ContentEngagementClient>(client);
      final control = AgentUiControlService();
      final c = await _mount(tester, control);
      final lease = control.coordinator
          .begin(
            sessionId: 'review-test',
            purpose: 'Prepare appeal',
            targetRoute: '/identity',
          )
          .value!;
      final adapter = control.adapters
          .resolve<IdentityPageAdapter>(route: '/identity', lease: lease)
          .value!;
      Future<bool> run(
        String id, [
        Map<String, Object?> args = const {},
      ]) async => (await adapter.executeAppControlAction(
        lease: lease,
        actionId: id,
        arguments: args,
        executionContext: _authority(),
      )).isSuccess;
      expect(adapter.actionById('submit_review_appeal'), isNull);
      expect(await run(ContentReviewPageActions.openAction), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('My actual comment'), findsOneWidget);
      expect(await run(ContentReviewPageActions.refreshAction), isTrue);
      expect(
        await run(ContentReviewPageActions.prepareAction, {
          'reviewId': 'rv_one',
          'reason': 'Please check this context',
        }),
        isTrue,
      );
      await tester.pumpAndSettle();
      final field = find.byKey(const ValueKey('review-appeal-reason'));
      expect(
        tester.widget<TextField>(field).controller!.text,
        'Please check this context',
      );
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
      expect(await run('submit_review_appeal'), isFalse);
      final submit = find.byKey(const ValueKey('review-appeal-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final post = requests.where((r) => r.method == 'POST').single;
      expect(jsonDecode(post.body), {
        'expectedVersion': 2,
        'reason': 'Please check this context',
      });
      expect(find.textContaining('Appeal submitted.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(control.adapters.length, 0);
      expect(await run(ContentReviewPageActions.openAction), isFalse);
      c.onClose();
      await control.coordinator.dispose();
    },
  );
  testWidgets('typing takes control and account retirement hides modal data', (
    tester,
  ) async {
    final client = _client(
      (_) async => _ok({
        'items': [_row()],
      }),
    );
    appServices.put<ContentEngagementClient>(client);
    final control = AgentUiControlService();
    final c = await _mount(tester, control);
    final lease = control.coordinator
        .begin(
          sessionId: 'review-user',
          purpose: 'Prepare',
          targetRoute: '/identity',
        )
        .value!;
    final adapter = control.adapters
        .resolve<IdentityPageAdapter>(route: '/identity', lease: lease)
        .value!;
    Future<bool> run(String id, [Map<String, Object?> args = const {}]) async =>
        (await adapter.executeAppControlAction(
          lease: lease,
          actionId: id,
          arguments: args,
          executionContext: _authority(),
        )).isSuccess;
    expect(await run(ContentReviewPageActions.openAction), isTrue);
    await tester.pumpAndSettle();
    expect(
      await run(ContentReviewPageActions.prepareAction, {
        'reviewId': 'rv_one',
        'reason': 'draft',
      }),
      isTrue,
    );
    await tester.pumpAndSettle();
    final field = find.byKey(const ValueKey('review-appeal-reason'));
    await tester.ensureVisible(field);
    await tester.enterText(field, 'My own reason');
    await tester.pump();
    expect(
      await run(ContentReviewPageActions.prepareAction, {
        'reviewId': 'rv_one',
        'reason': 'overwrite',
      }),
      isFalse,
    );
    expect(tester.widget<TextField>(field).controller!.text, 'My own reason');
    client.onClose();
    await tester.pump();
    expect(find.text('My actual comment'), findsNothing);
    expect(find.byKey(const ValueKey('review-appeal-submit')), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    c.onClose();
    await control.coordinator.dispose();
  });
  test(
    'a later reviewed version can be appealed after explicit reopening',
    () async {
      var version = 2;
      final client = _client(
        (r) async => r.method == 'GET'
            ? _ok({
                'items': [
                  {..._row(), 'version': version},
                ],
              })
            : _ok({
                'id': 'ra_one',
                'reviewId': 'rv_one',
                'reviewVersion': 2,
                'state': 'pending',
                'version': 1,
              }),
      );
      final controller = ContentReviewController(client);
      await controller.refresh();
      expect(controller.prepare('rv_one', 'First reason'), isTrue);
      expect(await controller.submitByUser(), isTrue);
      expect(controller.appealed('rv_one'), isTrue);
      version = 4;
      await controller.refresh();
      expect(controller.appealed('rv_one'), isFalse);
      expect(controller.prepare('rv_one', 'Review the new decision'), isTrue);
      controller.dispose();
      client.onClose();
    },
  );
  for (final state in ['pending', 'upheld']) {
    testWidgets(
      'persisted $state appeal prevents repeated submission after reopen',
      (tester) async {
        final client = _client(
          (_) async => _ok({
            'items': [_row(appeal: state)],
          }),
        );
        final c = ContentReviewController(client);
        await c.refresh();
        expect(c.appealed('rv_one'), isTrue);
        expect(c.prepare('rv_one', 'repeat'), isFalse);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ContentReviewPanel(gateway: client, controller: c),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('My actual comment'), findsOneWidget);
        expect(
          find.byKey(const ValueKey('review-appeal-rv_one')),
          findsNothing,
        );
        expect(
          find.textContaining(
            state == 'upheld'
                ? 'original decision was upheld'
                : 'Appeal submitted',
          ),
          findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        c.dispose();
        client.onClose();
        expect(tester.takeException(), isNull);
      },
    );
  }
  test(
    'review projection rejects unknown appeal states and leaked consumption text',
    () {
      for (final row in [
        {..._row(), 'appealState': 'approved'},
        {..._row(), 'kind': 'consumption'},
        {..._row(), 'commentText': 'x' * 181},
      ]) {
        expect(() => ContentReview.fromJson(row), throwsFormatException);
      }
    },
  );
  test(
    'retired context discards a late refresh and all appeal drafts',
    () async {
      final wait = Completer<http.Response>();
      final client = _client((_) => wait.future);
      final c = ContentReviewController(client);
      final task = c.refresh();
      client.onClose();
      wait.complete(
        _ok({
          'items': [_row()],
        }),
      );
      expect(await task, isFalse);
      expect(c.items, isEmpty);
      expect(c.prepare('rv_one', 'reason'), isFalse);
      c.dispose();
    },
  );
}

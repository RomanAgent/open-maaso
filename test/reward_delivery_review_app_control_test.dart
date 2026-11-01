import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/app_control_page_adapter.dart';
import 'package:maaso/src/features/content_engagement/application/content_review_page_actions.dart';
import 'package:maaso/src/features/content_engagement/data/content_engagement_client.dart';
import 'package:maaso/src/features/identity/application/identity_page_adapter.dart';
import 'package:maaso/src/features/identity/application/identity_service.dart';
import 'package:maaso/src/features/identity/application/identity_setup_controller.dart';
import 'package:maaso/src/features/identity/presentation/identity_setup_page.dart';
import 'identity_test_support.dart';
import 'reward_delivery_review_test.dart' show deliveryReviewJson;

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);
  testWidgets(
    'real identity route prepares delivery appeal and requires player submission',
    (tester) async {
      final requests = <http.Request>[];
      final client = ContentEngagementClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => 'owner',
        accessToken: () async => 'mounted-token',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'code': 'OK',
              'data': request.method == 'GET'
                  ? {
                      'items': [deliveryReviewJson(state: 'rejected')],
                    }
                  : {
                      'id': 'ra_delivery',
                      'reviewId': 'rv_delivery',
                      'reviewVersion': 2,
                      'state': 'pending',
                      'version': 1,
                    },
            }),
            200,
          );
        }),
      );
      appServices.put<ContentEngagementClient>(client);
      final control = AgentUiControlService();
      final controller = IdentitySetupController(
        service: IdentityService(
          gateway: FakeIdentityGateway(initial: identityFixture()),
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: IdentitySetupPage(
              controller: controller,
              route: '/identity',
              uiControl: control,
              onCompleted: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final lease = control.coordinator
          .begin(
            sessionId: 'delivery-review',
            purpose: 'Prepare appeal',
            targetRoute: '/identity',
          )
          .value!;
      final adapter = control.adapters
          .resolve<IdentityPageAdapter>(route: '/identity', lease: lease)
          .value!;
      Future<bool> run(
        String action, [
        Map<String, Object?> arguments = const {},
      ]) async => (await adapter.executeAppControlAction(
        lease: lease,
        actionId: action,
        arguments: arguments,
        executionContext: AppControlActionExecutionContext.host(
          requiresCommit: false,
          authorityIsCurrent: () => true,
          staleCode: 'stale',
        ),
      )).isSuccess;
      expect(adapter.actionById('submit_review_appeal'), isNull);
      expect(await run(ContentReviewPageActions.openAction), isTrue);
      await tester.pumpAndSettle();
      expect(find.textContaining('Reward review'), findsOneWidget);
      expect(
        await run(ContentReviewPageActions.prepareAction, {
          'reviewId': 'rv_delivery',
          'reason': 'Review my original record',
        }),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(requests.where((r) => r.method == 'POST'), isEmpty);
      expect(await run('submit_review_appeal'), isFalse);
      final submit = find.byKey(const ValueKey('review-appeal-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      final post = requests.where((r) => r.method == 'POST').single;
      expect(post.headers['authorization'], 'Bearer mounted-token');
      expect(post.url.path, '/v1/moderation/reviews/rv_delivery/appeals');
      expect(jsonDecode(post.body), {
        'expectedVersion': 2,
        'reason': 'Review my original record',
      });
      client.onClose();
      await tester.pump();
      expect(find.textContaining('Reward review'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(control.adapters.length, 0);
      controller.onClose();
      await control.coordinator.dispose();
    },
  );
}

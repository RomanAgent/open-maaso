import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/content_engagement/domain/content_review.dart';
import 'package:maaso/src/features/content_engagement/presentation/content_review_panel.dart';

Map<String, Object?> deliveryReviewJson({String state = 'pending'}) => {
  'id': 'rv_delivery',
  'kind': 'delivery',
  'targetId': 'game-1',
  'state': state,
  'version': 2,
  'reasonCode': 'pool_already_settled',
  'createdAt': '2026-09-13T00:00:00Z',
  'delivery': {
    'origin': 'content',
    'exceptionReason': 'pool_already_settled',
    'activityOccurredAt': '2026-09-12T10:00:00Z',
    'qualifiedAt': '2026-09-12T10:00:05Z',
  },
};

void main() {
  test('owner review accepts qualified delivery and processing state', () {
    final row = ContentReview.fromJson(deliveryReviewJson(state: 'processing'));
    expect(row.kind.name, 'delivery');
    expect(row.state.name, 'processing');
  });
  test(
    'delivery rejects unsupported states, private details and altered time order',
    () {
      final original = deliveryReviewJson();
      final details = original['delivery']! as Map<String, Object?>;
      for (final invalid in [
        {...original, 'kind': 'comment', 'state': 'processing'},
        {...original, 'kind': 'consumption'},
        {...original, 'delivery': null},
        {
          ...original,
          'delivery': {...details, 'origin': 'world'},
        },
        {...original, 'commentText': 'Private consumer comment'},
        {
          ...original,
          'delivery': {...details, 'ownerAccountUuid': 'private'},
        },
        {
          ...original,
          'delivery': {...details, 'sourceId': 'world:private:1'},
        },
        {
          ...original,
          'delivery': {...details, 'exceptionReason': 'funding_capacity'},
        },
        {
          ...original,
          'delivery': {...details, 'qualifiedAt': '2026-01-01T00:00:00Z'},
        },
      ]) {
        expect(() => ContentReview.fromJson(invalid), throwsFormatException);
      }
    },
  );
  for (final state in ['processing', 'approved', 'pending', 'rejected']) {
    testWidgets(
      'delivery $state displays honest status and human appeal boundary',
      (tester) async {
        final gateway = _DeliveryGateway(state);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: ContentReviewPanel(gateway: gateway)),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('Reward review'), findsOneWidget);
        expect(
          find.textContaining(
            'Final reward settlement is separate from this review status',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('wallet'), findsNothing);
        expect(find.textContaining('Activity (UTC)'), findsOneWidget);
        expect(find.text('Approved'), findsNothing);
        expect(
          find.text('Accepted by a reward pool'),
          state == 'approved' ? findsOneWidget : findsNothing,
        );
        expect(
          find.text('Retry queued or in progress'),
          state == 'processing' ? findsOneWidget : findsNothing,
        );
        expect(
          find.byKey(const ValueKey('review-appeal-rv_delivery')),
          state == 'rejected' ? findsOneWidget : findsNothing,
        );
        expect(gateway.writes, 0);
        if (state == 'rejected') {
          await tester.tap(
            find.byKey(const ValueKey('review-appeal-rv_delivery')),
          );
          await tester.pumpAndSettle();
          await tester.enterText(
            find.byKey(const ValueKey('review-appeal-reason')),
            'Check the original evidence',
          );
          await tester.pump();
          expect(gateway.writes, 0);
          final submit = find.byKey(const ValueKey('review-appeal-submit'));
          await tester.ensureVisible(submit);
          await tester.tap(submit);
          await tester.pumpAndSettle();
          expect(gateway.writes, 1);
        }
        gateway.active = false;
        gateway.changes.add(null);
        await tester.pump();
        expect(find.textContaining('Reward review'), findsNothing);
        expect(
          find.byKey(const ValueKey('review-appeal-submit')),
          findsNothing,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await gateway.changes.close();
      },
    );
  }
}

class _DeliveryGateway implements ContentReviewGateway {
  _DeliveryGateway(this.state);
  final String state;
  bool active = true;
  int writes = 0;
  final changes = StreamController<void>.broadcast(sync: true);
  @override
  String get contextKey => 'owner';
  @override
  bool get reviewActive => active;
  @override
  Stream<void> get reviewChanges => changes.stream;
  @override
  Future<List<ContentReview>> reviews() async => [
    ContentReview.fromJson(deliveryReviewJson(state: state)),
  ];
  @override
  Future<void> appealReview(ContentReview review, String reason) async {
    writes++;
  }
}

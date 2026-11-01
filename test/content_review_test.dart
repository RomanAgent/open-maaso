import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/content_engagement/application/content_review_controller.dart';
import 'package:maaso/src/features/content_engagement/data/content_engagement_client.dart';
import 'package:maaso/src/features/content_engagement/domain/content_engagement.dart';
import 'package:maaso/src/features/content_engagement/domain/content_review.dart';
import 'package:maaso/src/features/content_engagement/presentation/content_review_panel.dart';

Map<String, Object?> _row({String state = 'rejected'}) => {
  'id': 'rv_one',
  'kind': 'comment',
  'targetId': 'game',
  'state': state,
  'version': 2,
  'createdAt': '2026-09-13T00:00:00Z',
};
http.Response _ok(Object data) =>
    http.Response(jsonEncode({'code': 'OK', 'data': data}), 200);
ContentEngagementClient _client(
  Future<http.Response> Function(http.Request) handle, {
  String Function()? account,
}) => ContentEngagementClient(
  baseUri: () => Uri.parse('https://example.test/'),
  accountId: account ?? () => 'owner',
  accessToken: () async => 'mounted-token',
  client: MockClient(handle),
);

class _Gateway implements ContentReviewGateway {
  @override
  String contextKey = 'account-one';
  @override
  bool reviewActive = true;
  final changes = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get reviewChanges => changes.stream;
  int writes = 0;
  Completer<void>? wait;
  bool fail = false;
  @override
  Future<List<ContentReview>> reviews() async => [
    ContentReview.fromJson(_row()),
  ];
  @override
  Future<void> appealReview(ContentReview review, String reason) async {
    writes++;
    if (fail) throw Exception('unavailable');
    await wait?.future;
  }

  void retire() {
    reviewActive = false;
    changes.add(null);
  }
}

void main() {
  test('review client sends only current token and exact CAS appeal', () async {
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
    final rows = await client.reviews();
    await client.appealReview(rows.single, 'Please check the context');
    expect(requests.first.url.queryParameters, {'limit': '50'});
    expect(requests.last.headers['authorization'], 'Bearer mounted-token');
    expect(jsonDecode(requests.last.body), {
      'expectedVersion': 2,
      'reason': 'Please check the context',
    });
    client.onClose();
  });
  test(
    'review rejects malformed identity/duplicate page and stale account response',
    () async {
      final duplicate = _client(
        (_) async => _ok({
          'items': [_row(), _row()],
        }),
      );
      await expectLater(duplicate.reviews(), throwsFormatException);
      duplicate.onClose();
      expect(
        () => ContentReview.fromJson({..._row(), 'state': 'auto_approved'}),
        throwsFormatException,
      );
      expect(
        () => ContentReview.fromJson({..._row(), 'id': '../private'}),
        throwsFormatException,
      );
      var account = 'first';
      final waiting = Completer<http.Response>();
      final client = _client((_) => waiting.future, account: () => account);
      final future = client.reviews();
      await Future<void>.delayed(Duration.zero);
      account = 'second';
      waiting.complete(
        _ok({
          'items': [_row()],
        }),
      );
      await expectLater(
        future,
        throwsA(
          isA<ContentEngagementException>().having(
            (e) => e.code,
            'code',
            'CONTEXT_CHANGED',
          ),
        ),
      );
      client.onClose();
    },
  );
  test(
    'preparation cannot submit and user takeover blocks Agent draft',
    () async {
      final g = _Gateway();
      final c = ContentReviewController(g);
      await c.refresh();
      expect(c.prepare('rv_one', 'Context', fromAgent: true), isTrue);
      expect(g.writes, 0);
      c.userControl = true;
      expect(c.prepare('rv_one', 'Replaced', fromAgent: true), isFalse);
      expect(c.draft, 'Context');
      expect(c.prepare('rv_one', 'x' * 601), isFalse);
      g.fail = true;
      expect(await c.submitByUser(), isFalse);
      expect(c.draft, 'Context');
      g.fail = false;
      expect(await c.submitByUser(), isTrue);
      expect(c.appealed('rv_one'), isTrue);
      expect(c.canSubmit, isFalse);
      c.dispose();
      await g.changes.close();
    },
  );
  test(
    'account retirement clears cached rows and late appeal result',
    () async {
      final g = _Gateway()..wait = Completer<void>();
      final c = ContentReviewController(g);
      await c.refresh();
      c.prepare('rv_one', 'Context');
      final pending = c.submitByUser();
      g.retire();
      expect(c.items, isEmpty);
      expect(c.draft, isEmpty);
      expect(c.selected, isNull);
      g.wait!.complete();
      expect(await pending, isFalse);
      expect(c.appealed('rv_one'), isFalse);
      c.dispose();
      await g.changes.close();
    },
  );
  testWidgets(
    'appeal visible draft requires human submit and hides on retirement',
    (tester) async {
      final g = _Gateway();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ContentReviewPanel(gateway: g)),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('review-appeal-rv_one')));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('review-appeal-reason')),
        'Please review the full context',
      );
      await tester.pump();
      expect(g.writes, 0);
      await tester.ensureVisible(
        find.byKey(const ValueKey('review-appeal-submit')),
      );
      await tester.tap(find.byKey(const ValueKey('review-appeal-submit')));
      await tester.pumpAndSettle();
      expect(g.writes, 1);
      expect(
        find.text('Appeal submitted. A different reviewer will assess it.'),
        findsOneWidget,
      );
      g.retire();
      await tester.pump();
      expect(find.textContaining('game'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await g.changes.close();
    },
  );
  test('client close synchronously retires open review projection', () async {
    final client = _client(
      (_) async => _ok({
        'items': [_row()],
      }),
    );
    final c = ContentReviewController(client);
    await c.refresh();
    expect(c.items, hasLength(1));
    client.onClose();
    expect(c.items, isEmpty);
    expect(c.active, isFalse);
    c.dispose();
  });
}

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/content_engagement/data/content_engagement_client.dart';
import 'package:maaso/src/features/content_engagement/domain/comment_reporting.dart';
import 'package:maaso/src/features/content_engagement/domain/content_engagement.dart';
import 'package:maaso/src/features/content_engagement/presentation/comment_report_button.dart';

const _target = CommentReportTarget(
  surface: CommentReportSurface.agentGame,
  contentId: 'game',
  commentId: 'agc_root',
);

class _Reporter implements ContentCommentReporter {
  @override
  String contextKey = 'first';
  int calls = 0;
  bool fail = false;
  Completer<CommentReportReceipt>? wait;
  @override
  Future<CommentReportReceipt> reportComment(
    CommentReportTarget target,
    CommentReportReason reason,
  ) async {
    calls++;
    expect(target.commentId, 'agc_root');
    expect(reason, CommentReportReason.spam);
    if (fail) throw Exception('offline');
    return wait?.future ??
        const CommentReportReceipt(
          caseId: 'case',
          status: 'open',
          duplicate: false,
        );
  }
}

void main() {
  test(
    'report HTTP uses exact comment target and authenticated account only',
    () async {
      final requests = <http.Request>[];
      final client = ContentEngagementClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => 'account',
        accessToken: () async => 'token',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response(
            jsonEncode({
              'code': 'OK',
              'data': {'caseId': 'case', 'status': 'open', 'duplicate': false},
            }),
            200,
          );
        }),
      );
      final result = await client.reportComment(
        _target,
        CommentReportReason.spam,
      );
      expect(result.caseId, 'case');
      expect(requests.single.url.path, '/v1/public-engagement/comments/report');
      expect(requests.single.headers['Authorization'], 'Bearer token');
      expect(jsonDecode(requests.single.body), {
        'surface': 'agentGame',
        'targetId': 'game',
        'commentId': 'agc_root',
        'reason': 'spam',
      });
      client.onClose();
    },
  );

  test(
    'account changes during report token resolution prevent dispatch',
    () async {
      var account = 'first';
      final token = Completer<String>();
      var requests = 0;
      final client = ContentEngagementClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => account,
        accessToken: () => token.future,
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 200);
        }),
      );
      final pending = client.reportComment(_target, CommentReportReason.spam);
      account = 'next';
      token.complete('next-token');
      await expectLater(pending, throwsA(isA<ContentEngagementException>()));
      expect(requests, 0);
      client.onClose();
    },
  );

  testWidgets(
    'report requires a selected reason and retries without fake success',
    (tester) async {
      final reporter = _Reporter()..fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CommentReportButton(reporter: reporter, target: _target),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('comment-report-agc_root')));
      await tester.pumpAndSettle();
      expect(reporter.calls, 0);
      await tester.tap(find.text('Spam'));
      await tester.pumpAndSettle();
      expect(reporter.calls, 1);
      expect(find.text('Report failed. Retry'), findsOneWidget);
      expect(find.text('Reported'), findsNothing);
      reporter.fail = false;
      await tester.tap(find.byKey(const ValueKey('comment-report-agc_root')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Spam'));
      await tester.pumpAndSettle();
      expect(reporter.calls, 2);
      expect(find.text('Reported'), findsOneWidget);
    },
  );

  testWidgets('late receipt never appears in another account', (tester) async {
    final reporter = _Reporter()..wait = Completer<CommentReportReceipt>();
    Widget page() => MaterialApp(
      home: Scaffold(
        body: CommentReportButton(reporter: reporter, target: _target),
      ),
    );
    await tester.pumpWidget(page());
    await tester.tap(find.byKey(const ValueKey('comment-report-agc_root')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Spam'));
    await tester.pump();
    reporter.contextKey = 'next';
    await tester.pumpWidget(page());
    reporter.wait!.complete(
      const CommentReportReceipt(
        caseId: 'old-case',
        status: 'open',
        duplicate: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Reported'), findsNothing);
    expect(find.text('Report'), findsOneWidget);
  });
}

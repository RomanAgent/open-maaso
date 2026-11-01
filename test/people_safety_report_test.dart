import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/home/presentation/widgets/home_chat_history.dart';
import 'package:maaso/src/features/people_safety/data/people_safety_client.dart';
import 'package:maaso/src/features/people_safety/domain/ai_output_report.dart';
import 'package:maaso/src/features/people_safety/presentation/ai_output_report_dialog.dart';
import 'package:maaso/src/features/people_safety/presentation/home_ai_report.dart';

const _receipt = AIOutputReportReceipt(
  caseId: 'case-1',
  status: 'open',
  duplicate: false,
);
http.Response _response() => http.Response(
  jsonEncode({
    'code': 'OK',
    'data': {'caseId': 'case-1', 'status': 'open', 'duplicate': false},
  }),
  200,
);

class _Gateway implements AIOutputReportGateway {
  @override
  bool active = true;
  @override
  String contextKey = 'account-a';
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  final calls = <Map<String, String>>[];
  Completer<AIOutputReportReceipt>? pending;
  bool fail = false;
  @override
  Future<AIOutputReportReceipt> submitAIReport({
    required String requestId,
    required String text,
    required String reason,
  }) async {
    calls.add({'requestId': requestId, 'text': text, 'reason': reason});
    if (fail) throw StateError('timeout');
    return pending?.future ?? _receipt;
  }

  void retire() {
    active = false;
    events.add(null);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(() async => appServices.reset());

  testWidgets(
    'only explicit confirmation uploads the selected preview and pauses Agent control',
    (tester) async {
      final g = _Gateway();
      addTearDown(g.events.close);
      var human = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AIOutputReportDialog(
              gateway: g,
              text: 'Selected AI reply',
              onUserActivity: () => human++,
            ),
          ),
        ),
      );
      expect(find.text('Selected AI reply'), findsOneWidget);
      expect(g.calls, isEmpty);
      await tester.tap(find.byKey(const ValueKey('ai-report-submit')));
      await tester.pumpAndSettle();
      expect(g.calls.single['text'], 'Selected AI reply');
      expect(g.calls.single['reason'], 'unsafe');
      expect(human, 1);
      expect(find.byKey(const ValueKey('ai-report-receipt')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('ai-report-evidence-preview')),
        findsNothing,
      );
    },
  );

  testWidgets('unconfirmed retry preserves request and reason', (tester) async {
    final g = _Gateway()..fail = true;
    addTearDown(g.events.close);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AIOutputReportDialog(gateway: g, text: 'Selected'),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('ai-report-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('ai-report-error')), findsOneWidget);
    expect(
      tester
          .widget<DropdownButton<String>>(find.byType(DropdownButton<String>))
          .onChanged,
      isNull,
    );
    g.fail = false;
    await tester.tap(find.byKey(const ValueKey('ai-report-submit')));
    await tester.pumpAndSettle();
    expect(g.calls.length, 2);
    expect(g.calls[0], g.calls[1]);
  });

  testWidgets(
    'account retirement hides private preview and ignores late success',
    (tester) async {
      final g = _Gateway()..pending = Completer<AIOutputReportReceipt>();
      addTearDown(g.events.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AIOutputReportDialog(
              gateway: g,
              text: 'Private selected text',
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('ai-report-submit')));
      await tester.pump();
      g.retire();
      await tester.pump();
      expect(find.text('Private selected text'), findsNothing);
      expect(find.byKey(const ValueKey('ai-report-submit')), findsNothing);
      g.pending!.complete(_receipt);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('ai-report-receipt')), findsNothing);
    },
  );

  test('client binds token and response to exact account mount', () async {
    var account = 'a';
    final token = Completer<String>();
    var networkCalls = 0;
    final client = PeopleSafetyClient(
      baseUri: () => Uri.parse('https://example.test/'),
      accountId: () => account,
      accessToken: () => token.future,
      client: MockClient((request) async {
        networkCalls++;
        return _response();
      }),
    );
    addTearDown(client.onClose);
    final future = client.submitAIReport(
      requestId: 'r-1',
      text: 'Selected',
      reason: 'unsafe',
    );
    final check = expectLater(future, throwsStateError);
    account = 'b';
    token.complete('account-a-token');
    await check;
    expect(networkCalls, 0);
  });

  test(
    'client ignores old response and sends no private owner fields',
    () async {
      var account = 'a';
      final response = Completer<http.Response>();
      final arrived = Completer<void>();
      final client = PeopleSafetyClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => account,
        accessToken: () async => 'token-a',
        client: MockClient((request) {
          expect(request.url.path, '/v1/moderation/ai-output-reports');
          expect(jsonDecode(request.body), {
            'requestId': 'r-1',
            'text': 'Selected',
            'reason': 'unsafe',
          });
          arrived.complete();
          return response.future;
        }),
      );
      addTearDown(client.onClose);
      final future = client.submitAIReport(
        requestId: 'r-1',
        text: 'Selected',
        reason: 'unsafe',
      );
      final check = expectLater(future, throwsStateError);
      await arrived.future;
      account = 'b';
      response.complete(_response());
      await check;
    },
  );

  testWidgets(
    'selected bubble only exposes an explicitly bound complete AI report action',
    (tester) async {
      final message = _message();
      var presses = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(message: message, onReport: () => presses++),
          ),
        ),
      );
      expect(find.byKey(const ValueKey('message-report-action')), findsNothing);
      await tester.tap(find.text(message.content));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('message-report-action')));
      expect(presses, 1);
      await tester.pump();
      expect(find.byKey(const ValueKey('message-action-menu')), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: message,
              dim: true,
              onReport: () => presses++,
            ),
          ),
        ),
      );
      await tester.tap(find.text(message.content), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-report-action')), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MessageBubble(message: message)),
        ),
      );
      await tester.tap(find.text(message.content));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-report-action')), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: _message()..isUserMessage = true,
              onReport: () => presses++,
            ),
          ),
        ),
      );
      await tester.tap(find.text(message.content));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-report-action')), findsNothing);
      expect(presses, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MessageBubble(
              message: _message()..id = null,
              onReport: () => presses++,
            ),
          ),
        ),
      );
      await tester.tap(find.text(message.content));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-report-action')), findsNothing);
      expect(isReportableHomeAIReply(_message()..id = null), isFalse);
      expect(
        isReportableHomeAIReply(_message()..isUserMessage = true),
        isFalse,
      );
    },
  );

  testWidgets('Home uses persisted own reply and preview before any request', (
    tester,
  ) async {
    final db = _Db()..messages = [_message()];
    appServices.put<DBService>(db);
    appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
    appServices.put<AgentCoreController>(_QuietCore());
    appServices.put<HomeController>(_QuietHome());
    var calls = 0;
    appServices.put<PeopleSafetyClient>(
      PeopleSafetyClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => 'a',
        accessToken: () async => 'token',
        client: MockClient((_) async {
          calls++;
          return _response();
        }),
      ),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: appProviderContainer,
        child: MaterialApp(
          home: Scaffold(
            body: HomeChatHistory(
              contentPadding: EdgeInsets.zero,
              latestButtonBottom: 0,
              topFadeHeight: 0,
              clock: () => DateTime(2026, 9, 13, 12),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-report-action')), findsNothing);
    await tester.tap(find.text(_message().content));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-report-action')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('message-report-action')));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(
      find.byKey(const ValueKey('ai-report-evidence-preview')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('ai-report-submit')));
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a selected Home reply cannot report after its account changes', (
    tester,
  ) async {
    var account = 'a';
    var calls = 0;
    final db = _Db()..messages = [_message()];
    final client = PeopleSafetyClient(
      baseUri: () => Uri.parse('https://example.test/'),
      accountId: () => account,
      accessToken: () async => 'token',
      client: MockClient((_) async {
        calls++;
        return _response();
      }),
    );
    await _mountHome(tester, db, client, () => DateTime(2026, 9, 13, 12));
    await tester.tap(find.text(_message().content));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('message-report-action')), findsOneWidget);
    account = 'b';
    await tester.tap(find.byKey(const ValueKey('message-report-action')));
    await tester.pumpAndSettle();
    expect(find.byType(AIOutputReportDialog), findsNothing);
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Home report selection expires at the local day boundary', (
    tester,
  ) async {
    var now = DateTime(2026, 9, 13, 12);
    var calls = 0;
    final old = _message()
      ..id = 2
      ..content = 'Yesterday reply'
      ..timestamp = DateTime(2026, 9, 12, 12);
    final db = _Db()..messages = [old, _message()];
    final client = PeopleSafetyClient(
      baseUri: () => Uri.parse('https://example.test/'),
      accountId: () => 'a',
      accessToken: () async => 'token',
      client: MockClient((_) async {
        calls++;
        return _response();
      }),
    );
    await _mountHome(tester, db, client, () => now);
    expect(find.text(old.content), findsNothing);
    await tester.tap(find.text(_message().content));
    await tester.pumpAndSettle();
    now = DateTime(2026, 9, 14);
    await tester.tap(find.byKey(const ValueKey('message-report-action')));
    await tester.pumpAndSettle();
    expect(find.byType(AIOutputReportDialog), findsNothing);
    expect(calls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('stale Home row cannot upload through a new account store', (
    tester,
  ) async {
    final db = _Db();
    appServices.put<DBService>(db);
    appServices.put<PeopleSafetyClient>(
      PeopleSafetyClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => 'new-account',
        accessToken: () async => 'token',
        client: MockClient((_) async => throw StateError('must not send')),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => unawaited(reportHomeAIReply(context, _message())),
            child: const Text('report'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('report'));
    await tester.pumpAndSettle();
    expect(find.byType(AIOutputReportDialog), findsNothing);
  });
}

ChatMessage _message() => ChatMessage(
  id: 1,
  sessionId: 'self',
  senderId: 'self',
  receiverId: 'user',
  content: 'The selected persisted reply',
  timestamp: DateTime.utc(2026, 9, 13),
);

Future<void> _mountHome(
  WidgetTester tester,
  _Db database,
  PeopleSafetyClient client,
  DateTime Function() clock,
) async {
  appServices.put<DBService>(database);
  appServices.put(AgentRuntimeRegistry(hostExecutionEnabled: false));
  appServices.put<AgentCoreController>(_QuietCore());
  appServices.put<HomeController>(_QuietHome());
  appServices.put<PeopleSafetyClient>(client);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: appProviderContainer,
      child: MaterialApp(
        home: Scaffold(
          body: HomeChatHistory(
            contentPadding: EdgeInsets.zero,
            latestButtonBottom: 0,
            topFadeHeight: 0,
            clock: clock,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _Db extends DBService {
  List<ChatMessage> messages = [];
  @override
  Future<List<ChatMessage>> getMessagesInRange(
    String sessionId, {
    required DateTime from,
    required DateTime before,
  }) async => messages
      .where(
        (message) =>
            message.sessionId == sessionId &&
            !message.timestamp.isBefore(from) &&
            message.timestamp.isBefore(before),
      )
      .toList();
  @override
  Future<List<ChatMessage>> getRecentMessages(
    String sessionId, {
    int limit = 8,
  }) async => List.of(messages);
}

class _QuietHome extends HomeController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

class _QuietCore extends AgentCoreController {
  @override
  // ignore: must_call_super
  void onInit() {}
}

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
import 'package:maaso/src/features/people_safety/application/people_safety_controller.dart';
import 'package:maaso/src/features/people_safety/application/people_safety_page_adapter.dart';
import 'package:maaso/src/features/people_safety/data/people_safety_client.dart';
import 'package:maaso/src/features/people_safety/domain/people_block.dart';
import 'package:maaso/src/features/people_safety/presentation/people_block_dialog.dart';
import 'package:maaso/src/features/people_safety/presentation/people_safety_page.dart';
import 'package:maaso/src/features/identity/presentation/identity_badge.dart';
import 'package:maaso/src/features/identity/domain/identity_profile.dart';

const actor = PeopleActor(id: 'pa_other', kind: 'user', name: 'Other');
const blocked = PeopleBlock(actor: actor, blocked: true, version: 3);
Map<String, Object?> row({
  bool blocked = true,
  int version = 3,
  String id = 'pa_other',
}) => {
  'actor': {'id': id, 'kind': 'user', 'displayName': 'Other'},
  'blocked': blocked,
  'version': version,
};
http.Response response(Object data) =>
    http.Response(jsonEncode({'code': 'OK', 'data': data}), 200);

class _Gateway implements PeopleBlockGateway {
  @override
  bool active = true;
  @override
  String contextKey = 'a';
  final events = StreamController<void>.broadcast(sync: true);
  @override
  Stream<void> get changes => events.stream;
  final drafts = <PeopleBlockDraft>[];
  bool fail = false;
  Completer<PeopleBlock>? pending;
  @override
  Future<List<PeopleBlock>> listBlocks() async => [blocked];
  @override
  Future<PeopleBlock> blockState(PeopleActor actor) async => blocked;
  @override
  Future<PeopleBlock> setBlock(PeopleBlockDraft draft) async {
    drafts.add(draft);
    if (fail) throw StateError('timeout');
    return pending?.future ??
        PeopleBlock(actor: actor, blocked: draft.blocked, version: 4);
  }

  void retire() {
    active = false;
    events.add(null);
  }
}

void main() {
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);
  test(
    'public block HTTP derives only actor and CAS; late account results rejected',
    () async {
      var account = 'a';
      final token = Completer<String>();
      var sent = 0;
      final client = PeopleSafetyClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => account,
        accessToken: () => token.future,
        client: MockClient((r) async {
          sent++;
          return response(row());
        }),
      );
      final request = client.blockState(actor);
      account = 'b';
      token.complete('a-token');
      await expectLater(request, throwsStateError);
      expect(sent, 0);
      client.onClose();
      final requests = <http.Request>[];
      final c = PeopleSafetyClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => 'a',
        accessToken: () async => 'token',
        client: MockClient((r) async {
          requests.add(r);
          return response(row(blocked: false, version: 4));
        }),
      );
      final draft = PeopleBlockDraft(before: blocked, blocked: false);
      await c.setBlock(draft);
      final body = jsonDecode(requests.single.body) as Map;
      expect(body.keys.toSet(), {
        'requestId',
        'actorId',
        'actorKind',
        'blocked',
        'expectedVersion',
      });
      expect(body['expectedVersion'], 3);
      c.onClose();
    },
  );
  test(
    'forged response target is rejected and close retires waiting request',
    () async {
      final pending = Completer<http.Response>();
      final c = PeopleSafetyClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => 'a',
        accessToken: () async => 'token',
        client: MockClient((r) => pending.future),
      );
      final work = c.blockState(actor);
      await Future<void>.delayed(Duration.zero);
      c.onClose();
      pending.complete(response(row()));
      await expectLater(work, throwsStateError);
      final c2 = PeopleSafetyClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => 'a',
        accessToken: () async => 'token',
        client: MockClient((r) async => response(row(id: 'pa_forged'))),
      );
      await expectLater(c2.blockState(actor), throwsFormatException);
      c2.onClose();
    },
  );
  test(
    'uncertain unblock retry preserves key; retirement hides projection',
    () async {
      final g = _Gateway()..fail = true;
      final c = PeopleSafetyController(g);
      await c.refresh();
      expect(c.prepareUnblock(actor.id, actor.kind), true);
      await c.confirm();
      await c.confirm();
      expect(g.drafts.length, 2);
      expect(g.drafts.first.requestId, g.drafts.last.requestId);
      g.retire();
      expect(c.items, isEmpty);
      expect(c.draft, isNull);
      c.dispose();
      await g.events.close();
    },
  );
  testWidgets(
    'page registers adapter, prepares visible confirmation, human takeover and unregister',
    (tester) async {
      final g = _Gateway();
      addTearDown(g.events.close);
      final ui = AgentUiControlService();
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: PeopleSafetyPage(
              route: '/people-safety',
              gateway: g,
              uiControl: ui,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Other (Alien)'), findsOneWidget);
      expect(ui.adapters.length, 1);
      final lease = ui.coordinator
          .begin(
            sessionId: 'safety-test',
            purpose: 'Prepare unblock',
            targetRoute: '/people-safety',
          )
          .value!;
      final adapter = ui.adapters
          .resolve<PeopleSafetyPageAdapter>(
            route: '/people-safety',
            lease: lease,
          )
          .value!;
      final host = AppControlActionExecutionContext.host(
        requiresCommit: false,
        authorityIsCurrent: () => true,
        staleCode: 'stale',
      );
      final result = await adapter.executeAppControlAction(
        lease: lease,
        actionId: PeopleSafetyPageAdapter.prepareAction,
        arguments: {'actorId': actor.id, 'actorKind': actor.kind},
        executionContext: host,
      );
      expect(result.isSuccess, true);
      await tester.pump();
      expect(find.text('Confirm unblock'), findsOneWidget);
      expect(g.drafts, isEmpty);
      expect(adapter.actionById('submit'), isNull);
      await tester.tap(find.text('Confirm unblock'));
      await tester.pumpAndSettle();
      expect(g.drafts.length, 1);
      expect(find.text('Other (Alien)'), findsNothing);
      final takeover = await adapter.executeAppControlAction(
        lease: lease,
        actionId: PeopleSafetyPageAdapter.refreshAction,
        arguments: {},
        executionContext: host,
      );
      expect(takeover.isSuccess, false);
      await tester.pumpWidget(const SizedBox.shrink());
      expect(ui.adapters.length, 0);
      expect(
        (await adapter.executeAppControlAction(
          lease: lease,
          actionId: PeopleSafetyPageAdapter.refreshAction,
          arguments: {},
          executionContext: host,
        )).isSuccess,
        false,
      );
      await ui.coordinator.dispose();
    },
  );
  testWidgets(
    'unblock preview cancels without public write and account change clears names',
    (tester) async {
      final g = _Gateway();
      addTearDown(g.events.close);
      await tester.pumpWidget(
        MaterialApp(
          home: PeopleSafetyPage(route: '/people-safety', gateway: g),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Unblock'));
      await tester.pump();
      await tester.tap(find.text('Cancel'));
      await tester.pump();
      expect(g.drafts, isEmpty);
      g.retire();
      await tester.pump();
      expect(find.text('Other (Alien)'), findsNothing);
      expect(find.text('Confirm unblock'), findsNothing);
    },
  );
  testWidgets(
    'block dialog waits for real human confirm and hides late account receipt',
    (tester) async {
      final g = _Gateway()..pending = Completer<PeopleBlock>();
      addTearDown(g.events.close);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PeopleBlockDialog(gateway: g, actor: actor),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(g.drafts, isEmpty);
      await tester.tap(find.text('Confirm unblock'));
      await tester.pump();
      expect(g.drafts.length, 1);
      g.retire();
      g.pending!.complete(
        const PeopleBlock(actor: actor, blocked: false, version: 4),
      );
      await tester.pumpAndSettle();
      expect(find.text('Other'), findsNothing);
      expect(find.text('Updated.'), findsNothing);
      expect(find.text('Confirm unblock'), findsNothing);
    },
  );
  testWidgets(
    'badge remains labelled and adds menu only for public actor IDs',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                IdentityBadge(name: 'Local', kind: IdentityActorKind.agent),
                IdentityBadge(
                  name: 'Other',
                  kind: IdentityActorKind.player,
                  publicActorId: 'pa_other',
                ),
              ],
            ),
          ),
        ),
      );
      expect(find.byType(PopupMenuButton<String>), findsOneWidget);
      expect(find.text('Other (Alien)'), findsOneWidget);
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      expect(find.text('Block settings'), findsOneWidget);
    },
  );
}

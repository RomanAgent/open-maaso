import 'dart:convert';
import 'dart:collection';
import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/skills/applet_discovery_skill.dart';
import 'package:maaso/src/features/applets/application/applet_reuse.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/applets/presentation/applet_chat_card.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
  });
  tearDown(appServices.reset);
  Future<Map<String, dynamic>> call(
    AppletDiscoverySkill skill,
    String name,
    Map<String, Object?> input,
  ) async =>
      jsonDecode(await skill.methods[name]!([input]) as String)
          as Map<String, dynamic>;
  Future<void> search(AppletDiscoverySkill skill) async {
    final result = await call(skill, 'search', {
      'query': '旅行',
      'category': 'travel',
    });
    expect(result['status'], 'found');
    expect(result['navigation_requested'], isFalse);
  }

  test(
    'ranked discovery describes and configures an existing applet in chat without generation',
    () async {
      final gateway = _Gateway();
      final presented = <List<Map<String, Object?>>>[];
      final skill = AppletDiscoverySkill(
        gateway: gateway,
        navigate: (_) => fail('Applet reuse must stay in chat'),
        present: (_, _, actions) async => presented.add(actions),
      );
      await search(skill);
      expect(gateway.category, 'travel');
      final description = await call(skill, 'describeApplet', {'id': 'trip'});
      expect(description['skillInstructions'], contains('configure'));
      expect((description['actions'] as List).single['name'], 'configure');
      expect(description['metadataTrust'], contains('third-party'));
      final used = await call(skill, 'useApplet', {
        'id': 'trip',
        'actions': [
          {
            'name': 'configure',
            'arguments': {'destination': '杭州'},
          },
        ],
      });
      expect(used['status'], 'presented_in_chat');
      expect(used['created'], isFalse);
      expect(used['savedToMine'], isFalse);
      expect(presented.single.single['arguments'], {'destination': '杭州'});
      expect(
        (await call(skill, 'useApplet', {'id': 'trip'}))['error'],
        'search_required',
      );
    },
  );
  test(
    'reuse rejects missing inspection, undeclared actions, invalid arguments and account changes',
    () async {
      final gateway = _Gateway();
      var presented = 0;
      final skill = AppletDiscoverySkill(
        gateway: gateway,
        present: (_, _, _) async => presented++,
      );
      await search(skill);
      expect(
        (await call(skill, 'useApplet', {'id': 'trip'}))['error'],
        'describe_required',
      );
      await call(skill, 'describeApplet', {'id': 'trip'});
      for (final action in [
        {'name': 'publish', 'arguments': <String, Object?>{}},
        {
          'name': 'configure',
          'arguments': {'destination': 3},
        },
      ]) {
        expect(
          (await call(skill, 'useApplet', {
            'id': 'trip',
            'actions': [action],
          }))['error'],
          isNotNull,
        );
      }
      gateway.context = 'other-account';
      expect(
        (await call(skill, 'useApplet', {'id': 'trip'}))['error'],
        'search_required',
      );
      expect(presented, 0);
    },
  );
  test(
    'changed published source cannot reuse a previous inspected contract',
    () async {
      final gateway = _Gateway();
      final skill = AppletDiscoverySkill(
        gateway: gateway,
        present: (_, _, _) async => fail('stale source'),
      );
      await search(skill);
      await call(skill, 'describeApplet', {'id': 'trip'});
      gateway.hash = 'b' * 64;
      expect(
        (await call(skill, 'useApplet', {'id': 'trip'}))['error'],
        'applet_revision_changed',
      );
      gateway.hash = 'a' * 64;
      gateway.revision = 2;
      expect(
        (await call(skill, 'useApplet', {'id': 'trip'}))['error'],
        'applet_revision_changed',
      );
    },
  );
  test(
    'chat reference survives persistence without adding an owned applet',
    () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'reuse.db',
      );
      appServices.put<DBService>(database);
      final gateway = _Gateway();
      await queueAppletChatReference(gateway.item, gateway.document, const [
        {
          'name': 'configure',
          'arguments': {'destination': '杭州'},
        },
      ]);
      final message = (await database.getMessages('self')).single;
      expect(message.appletReference!.id, 'trip');
      expect(message.appletReference!.actions.single['arguments'], {
        'destination': '杭州',
      });
      expect(await database.getAllWidgets(), isEmpty);
      final parsed = ChatMessage.fromJson(message.toJson());
      expect(parsed.appletReference!.sourceSha256, 'a' * 64);
      expect(parsed.modelContextText, message.content);
    },
  );
  test(
    'cached reuse opens offline but a known withdrawal revokes it',
    () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'reuse-offline.db',
      );
      appServices.put<DBService>(database);
      final gateway = _Gateway();
      final original = gateway.document;
      Object? canonical(Object? value) {
        if (value is Map) {
          return SplayTreeMap<String, Object?>.from({
            for (final entry in value.entries)
              entry.key as String: canonical(entry.value),
          });
        }
        if (value is List) return value.map(canonical).toList();
        return value;
      }

      final hash = sha256
          .convert(utf8.encode(jsonEncode(canonical(original.surface))))
          .toString();
      final source = AppletSourceDocument(
        id: original.id,
        clientSurfaceId: original.clientSurfaceId,
        revisionNo: 1,
        sourceSha256: hash,
        experienceType: 'utility',
        category: 'travel',
        skillInstructions: original.skillInstructions,
        surface: original.surface,
      );
      await queueAppletChatReference(gateway.item, source, const []);
      final reference = (await database.getMessages(
        'self',
      )).single.appletReference!;
      final offline = await loadReusedAppletSource(
        reference,
        fetch: () async => throw http.ClientException('offline'),
      );
      expect(offline.sourceSha256, hash);
      await expectLater(
        loadReusedAppletSource(
          reference,
          fetch: () async =>
              throw AppletCatalogRequestException(404, 'NOT_FOUND'),
        ),
        throwsA(isA<AppletCatalogRequestException>()),
      );
      await expectLater(
        loadReusedAppletSource(
          reference,
          fetch: () async => throw http.ClientException('offline'),
        ),
        throwsA(isA<http.ClientException>()),
      );
      expect(await database.getAllWidgets(), isEmpty);
    },
  );
  testWidgets(
    'chat card names applet and hides references from a different account',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppletChatCard(
              reference: AppletChatReference(
                id: 'trip',
                title: '旅行助手',
                scopeKey: 'device-legacy',
                revision: 1,
                sourceSha256: 'a' * 64,
              ),
            ),
          ),
        ),
      );
      expect(find.text('旅行助手'), findsOneWidget);
      expect(find.byKey(const ValueKey('chat-applet-trip')), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AppletChatCard(
              reference: AppletChatReference(
                id: 'trip',
                title: '旅行助手',
                scopeKey: 'another-user',
                revision: 1,
                sourceSha256: 'a' * 64,
              ),
            ),
          ),
        ),
      );
      expect(find.text('旅行助手'), findsNothing);
    },
  );
}

class _Gateway implements AppletCatalogGateway, AppletDiscoveryGateway {
  String context = 'test-context';
  String hash = 'a' * 64;
  int revision = 1;
  String? category;
  @override
  String get requestContextKey => context;
  AppletCatalogItem get item => AppletCatalogItem(
    id: 'trip',
    title: '旅行助手',
    type: AppletCatalogType.applet,
    summary: '规划行程',
    category: 'travel',
    skillInstructions: 'Use configure with destination.',
    likeCount: 12,
    author: const AppletCatalogAuthor(
      agentId: 'agent',
      displayName: 'Guide',
      verified: false,
    ),
    shareUrl: Uri.parse('https://example.test/g/trip'),
    updatedAt: DateTime.utc(2026),
  );
  AppletSourceDocument get document => AppletSourceDocument(
    id: 'trip',
    clientSurfaceId: 'surface-trip',
    revisionNo: revision,
    sourceSha256: hash,
    experienceType: 'utility',
    category: 'travel',
    skillInstructions: 'Use configure with destination.',
    surface: {
      'title': '旅行助手',
      'rendering': 'webApp',
      'html': '<main>Trip</main>',
      'css': '',
      'js': 'Surface.onAgent = function(action,args) {};',
      'manifest': {
        'events': [],
        'actions': [
          {
            'name': 'configure',
            'schema': {'destination': 'string'},
          },
        ],
        'instructions': 'Use configure with destination.',
      },
    },
  );
  @override
  Future<AppletCatalogPage> searchRanked({
    required String query,
    String? category,
    AppletCatalogType? type,
    String? cursor,
    int limit = 12,
  }) async {
    this.category = category;
    return AppletCatalogPage(
      items: [item],
      quota: const AppletQuotaSnapshot(used: 0, limit: 5),
    );
  }

  @override
  Future<AppletSourceDocument> source(
    String id, {
    bool owned = false,
    required String expectedContextKey,
  }) async => document;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

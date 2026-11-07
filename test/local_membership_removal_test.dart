import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/daily_token_usage_service.dart';
import 'package:maaso/src/core/services/llm_direct_cloud_config.dart';
import 'package:maaso/src/core/services/llm_proxy_service.dart';
import 'package:maaso/src/core/services/secure_storage_service.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';
import 'package:maaso/src/features/economy/application/economy_service.dart';
import 'package:maaso/src/features/economy/application/store_purchase_service.dart';
import 'package:maaso/src/features/economy/domain/store_payment_models.dart';
import 'package:maaso/src/features/identity/presentation/profile_page.dart';
import 'package:maaso/src/offline/local_edition_policy.dart';
import 'package:sembast/sembast_memory.dart';

import 'profile_membership_test_support.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  testWidgets(
    'local profile removes the membership card and does not load store data',
    (tester) async {
      final fixture = ProfileFixture();
      addTearDown(fixture.close);
      final gateway = _CountingMembershipGateway();
      final membership = StorePurchaseService(gateway: gateway);
      addTearDown(membership.onClose);
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ProfilePage(
              controller: fixture.controller,
              route: AppRoutes.profile,
              membershipRoute: AppRoutes.membership,
              membership: membership,
              localEdition: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('profile-membership-card')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('profile-membership-tier')),
        findsNothing,
      );
      expect(find.text('Maaso membership'), findsNothing);
      expect(find.text('Maaso 会员'), findsNothing);
      expect(
        find.byKey(const ValueKey('profile-daily-token-card')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('profile-nickname-edit')),
        findsOneWidget,
      );
      expect(gateway.reads, 0);
      expect(membership.loading.value, isFalse);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'navigation exposes membership only for the retained legacy edition',
    () {
      final expected = !kOpenMaasoLocalEdition;
      expect(
        AppRouteCatalog.destinations.any((d) => d.id == 'membership'),
        expected,
      );
      expect(
        AppRouteCatalog.menuDestinations.any((d) => d.id == 'membership'),
        expected,
      );
      expect(
        AppRouteCatalog.resolveCommand('/会员'),
        expected ? AppRouteCatalog.membership : null,
      );
      expect(
        buildNavigationCapabilities(
          navigate: (_) {},
          currentRoute: () => AppRoutes.home,
        ).any((c) => c.id == 'nav.membership'),
        expected,
      );
    },
  );

  testWidgets(
    'local membership links lead to model settings without mounting plans',
    (tester) async {
      var membershipBuilds = 0;
      final router = createAppRouter(
        initialLocation: AppRoutes.membership,
        routesOverride: [
          GoRoute(
            path: AppRoutes.membership,
            builder: (_, _) {
              membershipBuilds++;
              return const Text('legacy membership plans');
            },
          ),
          GoRoute(
            path: AppRoutes.settings,
            builder: (_, _) => const Text('model settings'),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(child: MaterialApp.router(routerConfig: router)),
      );
      await tester.pumpAndSettle();
      expect(
        router.routeInformationProvider.value.uri.path,
        kOpenMaasoLocalEdition ? AppRoutes.settings : AppRoutes.membership,
      );
      expect(membershipBuilds, kOpenMaasoLocalEdition ? 0 : 1);
      expect(
        find.text('model settings'),
        kOpenMaasoLocalEdition ? findsOneWidget : findsNothing,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'configured key dispatches a model request with no membership service or allowance',
    () async {
      final storage = appServices.put<SecureStorageService>(_MemoryStorage());
      final database = await databaseFactoryMemory.openDatabase(
        'local-key-only-model',
      );
      var requests = 0;
      final usage = appServices.put(
        await DailyTokenUsageService(
          database: database,
          accountScopeDigest: 'local-fixture',
          isCurrent: () => true,
          clientFactory: () => MockClient((request) async {
            requests++;
            expect(
              request.url.toString(),
              'https://api.openai.com/v1/chat/completions',
            );
            expect(request.headers['Authorization'], 'Bearer fixture-key');
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {
                      'role': 'assistant',
                      'content': '{"reply":"ok","actions":[]}',
                    },
                    'finish_reason': 'stop',
                  },
                ],
                'usage': {
                  'prompt_tokens': 1,
                  'completion_tokens': 1,
                  'total_tokens': 2,
                },
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        ).init(observeLifecycle: false),
      );
      final proxy = LLMProxyService(localEdition: true);
      addTearDown(() async {
        await proxy.deactivateAccountAndDrain();
        await usage.shutdown();
        await database.close();
      });
      expect(appServices.isRegistered<EconomyService>(), isFalse);
      expect(appServices.isRegistered<StorePurchaseService>(), isFalse);
      expect(usage.today.value.total, 0);
      expect(await proxy.ensureClient(), isNull);
      const config = LLMDirectCloudConfig(
        apiKey: 'fixture-key',
        baseUrl: 'https://api.openai.com/v1',
        model: 'fixture',
        enabled: true,
      );
      await storage.write(LLMDirectCloudConfig.storageKey, config.encode());
      final client = await proxy.ensureClient();
      expect(client, isNotNull);
      expect(
        jsonDecode(await client!.chat([Message.user('Hello')]))['reply'],
        'ok',
      );
      expect(requests, 1);
      await storage.write(
        LLMDirectCloudConfig.storageKey,
        const LLMDirectCloudConfig(
          apiKey: 'fixture-key',
          baseUrl: 'https://api.openai.com/v1',
          model: 'fixture',
          enabled: false,
        ).encode(),
      );
      expect(await proxy.ensureClient(), isNull);
      expect(requests, 1);
    },
  );
}

final class _CountingMembershipGateway extends MembershipGatewayFake {
  int reads = 0;
  @override
  Future<List<StoreReceipt>> receipts(String context) async {
    reads++;
    return super.receipts(context);
  }

  @override
  Future<MembershipUsage> usage(String context) async {
    reads++;
    return super.usage(context);
  }
}

final class _MemoryStorage extends SecureStorageService {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<bool> write(String key, String? value) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  @override
  Future<bool> delete(String key) async {
    values.remove(key);
    return true;
  }
}

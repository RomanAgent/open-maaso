import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/app/routing/app_route_catalog.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/localization/en_us.dart';
import 'package:maaso/src/core/localization/zh_cn.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/capability/navigation_capabilities.dart';

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.macOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  test(
    'Memory Ledger is a stable routed destination with unambiguous aliases',
    () {
      expect(AppRouteCatalog.memoryLedger, '/memory-ledger');
      expect(AppRoutes.memoryLedger, AppRouteCatalog.memoryLedger);
      expect(appRoutePaths, contains(AppRouteCatalog.memoryLedger));

      final destination = AppRouteCatalog.destinations.singleWhere(
        (candidate) => candidate.id == 'memory_ledger',
      );
      expect(destination.route, AppRouteCatalog.memoryLedger);
      expect(destination.title, 'Memory Ledger');
      expect(destination.keywords, containsAll(<String>['ledger', '记忆账本']));
      expect(
        AppRouteCatalog.resolveCommand('/memory-ledger'),
        AppRouteCatalog.memoryLedger,
      );
      expect(
        AppRouteCatalog.resolveCommand('/记忆审核'),
        AppRouteCatalog.memoryLedger,
      );
      expect(
        AppRouteCatalog.resolveCommand('/memory'),
        AppRouteCatalog.memoryWall,
      );
    },
  );

  test('Memory Ledger navigation is available on mobile, web, and desktop', () {
    for (final platform in AppHostPlatform.values) {
      final capabilities = AppPlatformCapabilities.forPlatform(platform);
      final nav = buildNavigationCapabilities(
        navigate: (_) {},
        currentRoute: () => AppRouteCatalog.home,
        platformCapabilities: capabilities,
      );
      final manifests = navigationManifests(platformCapabilities: capabilities);

      expect(
        nav.any((capability) => capability.id == 'nav.memory_ledger'),
        isTrue,
        reason: platform.name,
      );
      expect(
        manifests.any((manifest) => manifest.id == 'nav.memory_ledger'),
        isTrue,
        reason: platform.name,
      );
    }
  });

  test('go_router registers the concrete Memory Ledger screen', () {
    final source = File(
      'lib/src/app/routing/router_config.dart',
    ).readAsStringSync();

    expect(source, contains('AppRoutes.memoryLedger'));
    expect(source, contains('const MemoryLedgerScreen()'));
  });

  test('Memory Ledger navigation title follows the requested locale', () {
    expect(
      navigationDestinationTitle('memory_ledger', locale: AppLocale.en),
      'Memory Ledger',
    );
    expect(
      navigationDestinationTitle('memory_ledger', locale: AppLocale.zh),
      '记忆账本',
    );
  });

  test('relationship hub exposes the Memory Ledger', () {
    final source = File(
      'lib/src/features/relationship/presentation/relationship_hub_page.dart',
    ).readAsStringSync();
    final ledgerRoute = source.indexOf('AppRouteCatalog.memoryLedger');
    expect(ledgerRoute, greaterThanOrEqualTo(0));
    expect(source, contains("'memory_ledger.settings_title'.tr"));
    final settings = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();
    expect(settings, isNot(contains('AppRouteCatalog.memoryLedger')));
  });

  test('Memory Ledger user-facing copy has English and Chinese parity', () {
    const requiredKeys = <String>[
      'memory_ledger.title',
      'memory_ledger.settings_title',
      'memory_ledger.settings_subtitle',
      'memory_ledger.loading',
      'memory_ledger.empty_title',
      'memory_ledger.empty_message',
      'memory_ledger.load_failed_title',
      'memory_ledger.load_failed_message',
      'memory_ledger.accept',
      'memory_ledger.edit',
      'memory_ledger.reject',
      'memory_ledger.delete',
      'memory_ledger.restore',
      'memory_ledger.confirm_title',
      'memory_ledger.confirm_message',
    ];

    for (final key in requiredKeys) {
      expect(enUS[key], isNotNull, reason: 'missing EN $key');
      expect(zhCH[key], isNotNull, reason: 'missing ZH $key');
    }
  });
}

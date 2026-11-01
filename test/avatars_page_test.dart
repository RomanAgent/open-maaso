import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'helpers/avatar_upload_cover_fixture.dart';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot.dart';
import 'package:maaso/src/core/capability/app_capability_snapshot_service.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/platform/app_platform_capabilities.dart';
import 'package:maaso/src/features/avatars/presentation/avatars_page.dart';
import 'package:maaso/src/features/avatars/application/avatar_model_store_controller.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/persistence/account_storage_scope_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_model_upload_cover.dart';
import 'package:maaso/src/core/services/bundled_avatar_contract.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_capability_profile.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
    AppLocalization.updateLocale(const Locale('en', 'US'));
  });

  tearDown(() {
    AppLocalization.updateLocale(const Locale('en', 'US'));
    appServices.reset();
  });

  for (final locale in [const Locale('en', 'US'), const Locale('zh', 'CN')]) {
    for (final accept in [false, true]) {
      testWidgets(
        'paired upload preview stays whole and actionable at 320px, 2x $locale, accept=$accept',
        (tester) async {
          AppLocalization.updateLocale(locale);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.binding.setSurfaceSize(const Size(320, 650));
          final cover = (await tester.runAsync(avatarUploadCoverFixture))!;
          final controller = _PreviewUploadController(cover);
          await tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: AvatarsPage(controller: controller, ownedOnly: true),
            ),
          );
          await tester.pumpAndSettle();
          final upload = find.byKey(const ValueKey('model-workshop-upload'));
          await tester.scrollUntilVisible(
            upload,
            240,
            scrollable: _storeScrollable('model-store-scroll'),
          );
          await tester.ensureVisible(upload);
          await tester.tap(upload);
          await tester.pumpAndSettle();
          final preview = find.byKey(
            const ValueKey('model-upload-cover-preview'),
          );
          expect(tester.widget<Image>(preview).fit, BoxFit.contain);
          expect(
            ((tester.widget<Image>(preview).image as ResizeImage).imageProvider
                    as MemoryImage)
                .bytes,
            cover.bytes,
          );
          expect(controller.confirmed, isFalse);
          expect(find.text('avatar_store.cover.guidance'.tr), findsWidgets);
          final action = find.byKey(
            ValueKey(accept ? 'model-upload-confirm' : 'model-upload-cancel'),
          );
          await tester.ensureVisible(action);
          expect(action.hitTestable(), findsOneWidget);
          expect(tester.getRect(action).bottom, lessThanOrEqualTo(650));
          await tester.tap(action);
          await tester.pumpAndSettle();
          expect(controller.confirmed, accept);
          expect(
            find.byKey(const ValueKey('model-upload-confirmation')),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'uploaded model card displays the canonical full-body cover uncropped',
    (tester) async {
      final controller = AvatarModelStoreController(
        catalog: _CoverUploadGateway(),
        avatars: AvatarConfigService(),
      );
      await tester.pumpWidget(
        MaterialApp(home: AvatarsPage(controller: controller, ownedOnly: true)),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(const ValueKey('model-upload-99'));
      await tester.scrollUntilVisible(
        card,
        240,
        scrollable: _storeScrollable('model-store-scroll'),
      );
      final image = tester.widget<Image>(
        find.byKey(const ValueKey('model-upload-cover-99')),
      );
      expect(image.fit, BoxFit.contain);
      expect(
        ((image.image as ResizeImage).imageProvider as NetworkImage).url,
        'https://cdn.example.com/full-body.png',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'retired Matt stays absent even if an old gateway still returns its descriptor',
    (tester) async {
      final snapshots = appServices.put(
        AppCapabilitySnapshotService(
          resolver: AppPlatformCapabilitySnapshotResolver(routeIds: const []),
          initialContext: AppCapabilitySnapshotContext(
            hostPlatform: AppHostPlatform.windows,
            rolloutGeneration: 0,
          ),
        ),
      );
      final avatars = _AuthoritativeUiAvatarConfig()
        ..beginAuthoritativeSelectionStartup();
      final controller = AvatarModelStoreController(
        catalog: _MattModelGateway(),
        avatars: avatars,
      );
      await tester.pumpWidget(
        MaterialApp(home: AvatarsPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      avatars.markAuthoritativeSelectionReady();
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('model-card-reviewed-model-44')),
        findsNothing,
      );
      expect(
        avatars.catalog.any((option) => option.isRetiredOfficial),
        isFalse,
      );
      expect(avatars.remoteModelSelectionAvailable, isFalse);
      expect(snapshots.isClosed, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  for (final viewport in <Size>[const Size(375, 812), const Size(1100, 850)]) {
    testWidgets(
      'keeps the whole Agent preview visible in summary and management row at $viewport',
      (tester) async {
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.binding.setSurfaceSize(viewport);
        final controller = AvatarModelStoreController(
          catalog: _PageAvatarModelStoreGateway(),
          avatars: AvatarConfigService(),
        );
        await tester.pumpWidget(
          MaterialApp(
            home: AvatarsPage(controller: controller, ownedOnly: true),
          ),
        );
        await tester.pumpAndSettle();
        final previews = find.byKey(
          const ValueKey<String>('model-preview-agent'),
        );
        await tester.runAsync(
          () => precacheImage(
            const AssetImage('assets/model_store/agent.png'),
            tester.element(previews.first),
          ),
        );
        await tester.pump();
        _expectAgentHeadVisible(tester, previews.first);

        final modelCard = find.byKey(
          const ValueKey<String>('model-card-agent'),
        );
        await tester.scrollUntilVisible(
          modelCard,
          240,
          scrollable: _storeScrollable('model-store-scroll'),
        );
        _expectAgentHeadVisible(
          tester,
          find.descendant(of: modelCard, matching: previews),
        );
        expect(find.text('Maaso original'), findsNothing);
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics &&
                widget.properties.label == 'Joy, Built-in model, free',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final ownedOnly in [false, true]) {
    testWidgets('remote model covers remain whole in workshop=$ownedOnly', (
      tester,
    ) async {
      final avatars = AvatarConfigService();
      final selected = avatars.selectedId.value;
      final controller = AvatarModelStoreController(
        catalog: _FullBodyPreviewModelGateway(),
        avatars: avatars,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AvatarsPage(controller: controller, ownedOnly: ownedOnly),
        ),
      );
      await tester.pumpAndSettle();
      final card = find.byKey(
        const ValueKey<String>('model-card-reviewed-model-25'),
      );
      await tester.scrollUntilVisible(
        card,
        240,
        scrollable: _storeScrollable('model-store-scroll'),
      );
      final cover = find.descendant(of: card, matching: find.byType(Image));
      expect(cover, findsOneWidget);
      expect(tester.widget<Image>(cover).fit, BoxFit.contain);
      expect(tester.widget<Image>(cover).image, isA<NetworkImage>());
      await tester.ensureVisible(cover);
      await tester.pumpAndSettle();
      expect(cover.hitTestable(), findsOneWidget);
      await tester.tap(cover);
      await tester.pumpAndSettle();
      final detailCover = find.descendant(
        of: find.byKey(const ValueKey<String>('model-detail-sheet')),
        matching: find.byType(Image),
      );
      expect(detailCover, findsOneWidget);
      expect(tester.widget<Image>(detailCover).fit, BoxFit.contain);
      expect(avatars.selectedId.value, selected);
      expect(tester.takeException(), isNull);
    });
  }

  for (final locale in [const Locale('en', 'US'), const Locale('zh', 'CN')]) {
    testWidgets(
      'Joy display name keeps the persisted agent identity at $locale',
      (tester) async {
        AppLocalization.updateLocale(locale);
        final avatars = _DisplayNameAvatarConfig()
          ..selectedId.value = 'custom-agent';
        final controller = AvatarModelStoreController(
          catalog: _PageAvatarModelStoreGateway(),
          avatars: avatars,
        );
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: rootNavigatorKey,
            home: AvatarsPage(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        final joyCard = find.byKey(const ValueKey<String>('model-card-agent'));
        final customCard = find.byKey(
          const ValueKey<String>('model-card-custom-agent'),
        );
        expect(
          find.descendant(of: joyCard, matching: find.text('Joy')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: customCard, matching: find.text('Agent')),
          findsOneWidget,
        );
        final joyLabel = 'avatar_store.model.semantics'.trParams({
          'name': 'Joy',
          'source': 'avatar_store.source.maaso_original'.tr,
        });
        expect(
          find.byWidgetPredicate(
            (widget) =>
                widget is Semantics && widget.properties.label == joyLabel,
          ),
          findsOneWidget,
        );
        expect(
          avatars.catalog.singleWhere((option) => option.id == 'agent').name,
          'Agent',
        );
        final selectJoy = find.byKey(
          const ValueKey<String>('model-select-agent'),
        );
        await tester.ensureVisible(selectJoy);
        await tester.pumpAndSettle();
        await tester.tap(selectJoy);
        await tester.pumpAndSettle();
        expect(avatars.selectedIds, isEmpty);
        final detailSelect = find.byKey(
          const ValueKey<String>('model-detail-select'),
        );
        await tester.ensureVisible(detailSelect);
        await tester.tap(detailSelect);
        await tester.pumpAndSettle();
        expect(find.text('asset_store.confirm_select'.tr), findsOneWidget);
        expect(avatars.selectedIds, isEmpty);
        await tester.tap(
          find.byKey(const ValueKey<String>('model-confirm-select')),
        );
        await tester.pumpAndSettle();
        expect(avatars.selectedIds, ['agent']);
        expect(avatars.selectedId.value, 'agent');
        expect(
          avatars.catalog.singleWhere((option) => option.id == 'agent').name,
          'Agent',
        );
        expect(
          find.text(
            'avatar_store.notice.model_selected.local'.trParams({
              'name': 'Joy',
            }),
          ),
          findsOneWidget,
        );
        await tester.pump(const Duration(seconds: 4));
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'fallback model search filters loaded names and sources without API calls',
    (tester) async {
      final gateway = _PageAvatarModelStoreGateway();
      final controller = AvatarModelStoreController(
        catalog: gateway,
        avatars: AvatarConfigService(),
      );
      await tester.pumpWidget(
        MaterialApp(home: AvatarsPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      final requests = gateway.catalogListRequests;
      final search = find.descendant(
        of: find.byKey(const ValueKey<String>('model-store-search')),
        matching: find.byType(TextField),
      );
      await tester.enterText(search, 'joy');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('model-card-agent')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('model-card-reviewed-model-25')),
        findsNothing,
      );
      await tester.enterText(search, 'official');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('model-card-agent')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('model-card-reviewed-model-25')),
        findsOneWidget,
      );
      await tester.enterText(search, 'unmatched-idea');
      await tester.pumpAndSettle();
      expect(find.text('asset_store.empty'.tr), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('model-search-clear')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('model-card-agent')),
        findsOneWidget,
      );
      expect(gateway.catalogListRequests, requests);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'model confirmation cancellation does not change the selected identity',
    (tester) async {
      final avatars = _DisplayNameAvatarConfig()
        ..selectedId.value = 'custom-agent';
      final controller = AvatarModelStoreController(
        catalog: _PageAvatarModelStoreGateway(),
        avatars: avatars,
      );
      await tester.pumpWidget(
        MaterialApp(home: AvatarsPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      final joy = find.byKey(const ValueKey<String>('model-card-agent'));
      await tester.tap(joy);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('model-detail-sheet')),
        findsOneWidget,
      );
      final select = find.byKey(const ValueKey<String>('model-detail-select'));
      await tester.ensureVisible(select);
      await tester.tap(select);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('model-confirm-cancel')),
      );
      await tester.pumpAndSettle();
      expect(avatars.selectedIds, isEmpty);
      expect(avatars.selectedId.value, 'custom-agent');
      expect(
        find.byKey(const ValueKey<String>('model-detail-sheet')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('account invalidation revokes an already open confirmation', (
    tester,
  ) async {
    final scopes = appServices.put(AccountStorageScopeService());
    final mount = scopes.mount(
      AccountStorageScope(environmentKey: 'test', accountUuid: 'a'),
    );
    final avatars = _DisplayNameAvatarConfig()
      ..selectedId.value = 'custom-agent';
    final controller = AvatarModelStoreController(
      catalog: _PageAvatarModelStoreGateway(),
      avatars: avatars,
    );
    await tester.pumpWidget(
      MaterialApp(home: AvatarsPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('model-card-agent')));
    await tester.pumpAndSettle();
    final select = find.byKey(const ValueKey<String>('model-detail-select'));
    await tester.ensureVisible(select);
    await tester.tap(select);
    await tester.pumpAndSettle();
    scopes.unmount(mount);
    scopes.mount(AccountStorageScope(environmentKey: 'test', accountUuid: 'b'));
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('model-confirm-select')),
    );
    await tester.pumpAndSettle();
    expect(avatars.selectedIds, isEmpty);
    expect(avatars.selectedId.value, 'custom-agent');
    expect(
      find.byKey(const ValueKey<String>('model-detail-unavailable')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'catalog replacement revokes the exact model shown in old details',
    (tester) async {
      final avatars = _DisplayNameAvatarConfig()
        ..selectedId.value = 'custom-agent';
      final controller = AvatarModelStoreController(
        catalog: _PageAvatarModelStoreGateway(),
        avatars: avatars,
      );
      await tester.pumpWidget(
        MaterialApp(home: AvatarsPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('model-card-agent')));
      await tester.pumpAndSettle();
      final select = find.byKey(const ValueKey<String>('model-detail-select'));
      await tester.ensureVisible(select);
      await tester.tap(select);
      await tester.pumpAndSettle();
      avatars.catalog.assignAll([
        const AvatarOption(
          id: 'agent',
          name: 'Changed model',
          backend: AvatarBackendKind.unity,
          modelUrl: 'unity://changed',
        ),
        avatars.catalog.singleWhere((option) => option.id == 'custom-agent'),
      ]);
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('model-confirm-select')),
      );
      await tester.pumpAndSettle();
      expect(avatars.selectedIds, isEmpty);
      expect(avatars.selectedId.value, 'custom-agent');
      expect(
        find.byKey(const ValueKey<String>('model-detail-unavailable')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reviewed model details keep reviewed source and original identity',
    (tester) async {
      final avatars = _DisplayNameAvatarConfig();
      final controller = AvatarModelStoreController(
        catalog: _PageAvatarModelStoreGateway(),
        avatars: avatars,
      );
      await tester.pumpWidget(
        MaterialApp(home: AvatarsPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      final openDetails = find.byKey(
        const ValueKey<String>('model-select-reviewed-model-25'),
      );
      await tester.scrollUntilVisible(
        openDetails,
        240,
        scrollable: _storeScrollable('model-store-scroll'),
      );
      await tester.ensureVisible(openDetails);
      await tester.pumpAndSettle();
      expect(openDetails.hitTestable(), findsOneWidget);
      await tester.tap(openDetails);
      await tester.pumpAndSettle();
      final detail = find.byKey(const ValueKey<String>('model-detail-sheet'));
      expect(
        find.descendant(of: detail, matching: find.text('Official · reviewed')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: detail, matching: find.text('Built-in model')),
        findsNothing,
      );
      final select = find.byKey(const ValueKey<String>('model-detail-select'));
      await tester.ensureVisible(select);
      await tester.tap(select);
      await tester.pumpAndSettle();
      expect(avatars.selectedIds, isEmpty);
      await tester.tap(
        find.byKey(const ValueKey<String>('model-confirm-select')),
      );
      await tester.pumpAndSettle();
      expect(avatars.selectedIds, ['reviewed-model-25']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'public gallery has large model previews and no upload or action UI',
    (tester) async {
      final controller = AvatarModelStoreController(
        catalog: _PageAvatarModelStoreGateway(),
        avatars: AvatarConfigService(),
      );
      await tester.pumpWidget(
        MaterialApp(home: AvatarsPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('avatar_store.title'.tr), findsOneWidget);
      expect(find.text('Actions'), findsNothing);
      expect(find.byType(TabBar), findsNothing);
      expect(find.byType(TabBarView), findsNothing);
      expect(find.text('Upload'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('model-current-summary')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey<String>('model-store-gallery')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('model-preview-agent')),
        findsOneWidget,
      );
      final remoteCard = find.byKey(
        const ValueKey<String>('model-card-reviewed-model-25'),
      );
      await tester.scrollUntilVisible(
        remoteCard,
        240,
        scrollable: _storeScrollable('model-store-scroll'),
      );
      expect(
        find.descendant(of: remoteCard, matching: find.byType(Image)),
        findsNothing,
      );
      expect(
        find.descendant(
          of: remoteCard,
          matching: find.byIcon(Icons.accessibility_new_rounded),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(of: remoteCard, matching: find.text('Modular Female')),
        findsNWidgets(2),
      );
      expect(
        find.descendant(
          of: remoteCard,
          matching: find.byKey(
            const ValueKey<String>('model-select-reviewed-model-25'),
          ),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'workshop keeps current model, available models and real upload status',
    (tester) async {
      final controller = AvatarModelStoreController(
        catalog: _PageAvatarModelStoreGateway(),
        avatars: AvatarConfigService(),
      );
      await tester.pumpWidget(
        MaterialApp(home: AvatarsPage(controller: controller, ownedOnly: true)),
      );
      await tester.pumpAndSettle();
      expect(find.text('store_hub.workshop'.tr), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('model-current-summary')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('model-workshop-list')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('model-card-reviewed-model-25')),
        findsNothing,
      );
      expect(find.text('Actions'), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('model-upload-42')),
        240,
        scrollable: _storeScrollable('model-store-scroll'),
      );
      expect(find.text('Lumen Explorer'), findsOneWidget);
      expect(find.text('Awaiting review'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey<String>('model-workshop-upload')),
        240,
        scrollable: _storeScrollable('model-store-scroll'),
      );
      expect(find.text('Upload'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'workshop lists approved owned models and excludes unrelated public models',
    (tester) async {
      final controller = AvatarModelStoreController(
        catalog: _OwnedApprovedModelGateway(),
        avatars: AvatarConfigService(),
      );
      await tester.pumpWidget(
        MaterialApp(home: AvatarsPage(controller: controller, ownedOnly: true)),
      );
      await tester.pumpAndSettle();
      final owned = find.byKey(
        const ValueKey<String>('model-card-reviewed-model-25'),
      );
      await tester.scrollUntilVisible(
        owned,
        240,
        scrollable: _storeScrollable('model-store-scroll'),
      );
      expect(owned, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('model-card-reviewed-model-26')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'gallery shows two columns on phone and one at large text scale',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(390, 844));
      final controller = AvatarModelStoreController(
        catalog: _PageAvatarModelStoreGateway(),
        avatars: AvatarConfigService(),
      );
      Widget page(double scale) => MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: AvatarsPage(controller: controller),
      );
      await tester.pumpWidget(page(1));
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey<String>('model-card-agent'));
      final second = find.byKey(
        const ValueKey<String>('model-card-reviewed-model-25'),
      );
      expect(tester.getRect(first).top, tester.getRect(second).top);
      expect(
        tester.getRect(first).right,
        lessThan(tester.getRect(second).left),
      );
      final preview = find.byKey(const ValueKey<String>('model-preview-agent'));
      expect(tester.getSize(preview).width, greaterThan(120));
      await tester.pumpWidget(page(2));
      await tester.pumpAndSettle();
      expect(tester.getSize(first).width, greaterThan(300));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('offers an upload retry without hiding free models', (
    tester,
  ) async {
    final controller = AvatarModelStoreController(
      catalog: _PageAvatarModelStoreGateway(failMine: true),
      avatars: AvatarConfigService(),
    );

    await tester.pumpWidget(
      MaterialApp(home: AvatarsPage(controller: controller, ownedOnly: true)),
    );
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
      find.text('avatar_store.section.choose_model'.tr),
      240,
      scrollable: _storeScrollable('model-store-scroll'),
    );
    expect(find.text('avatar_store.section.choose_model'.tr), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Retry'),
      300,
      scrollable: _storeScrollable('model-store-scroll'),
    );
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('shows bounded capability diagnostics and blocks unsafe models', (
    tester,
  ) async {
    final controller = AvatarModelStoreController(
      catalog: _PageAvatarModelStoreGateway(),
      avatars: AvatarConfigService(),
    );

    await tester.pumpWidget(
      MaterialApp(home: AvatarsPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    final blockedCard = find.byKey(
      const ValueKey<String>('model-card-reviewed-model-27'),
    );
    await tester.scrollUntilVisible(
      blockedCard,
      240,
      scrollable: _storeScrollable('model-store-scroll'),
    );

    expect(find.text('BLOCKED'), findsOneWidget);
    expect(
      find.textContaining('Unavailable until the model is fixed'),
      findsOneWidget,
    );
    final card = tester.widget<AppSecondaryCard>(blockedCard);
    expect(card.onTap, isNull);
    final cardSemantics = tester.widget<Semantics>(
      find.ancestor(
        of: blockedCard,
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Semantics &&
              (widget.properties.label?.contains('Needs Rig Fix') ?? false),
        ),
      ),
    );
    expect(cardSemantics.properties.button, isTrue);
    expect(cardSemantics.properties.enabled, isFalse);
    expect(cardSemantics.properties.hint, contains('Humanoid rig'));
    final selectedBefore = controller.avatars.selectedId.value;
    await tester.tap(blockedCard, warnIfMissed: false);
    await tester.pump();
    expect(controller.avatars.selectedId.value, selectedBefore);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'remote model cards disable and recover with the live capability snapshot',
    (tester) async {
      final snapshots = appServices.put(
        AppCapabilitySnapshotService(
          resolver: AppPlatformCapabilitySnapshotResolver(routeIds: const []),
          initialContext: AppCapabilitySnapshotContext(
            hostPlatform: AppHostPlatform.web,
            rolloutGeneration: 0,
          ),
        ),
      );
      final controller = AvatarModelStoreController(
        catalog: _PageAvatarModelStoreGateway(),
        avatars: AvatarConfigService(),
      );

      await tester.pumpWidget(
        MaterialApp(home: AvatarsPage(controller: controller)),
      );
      await tester.pumpAndSettle();
      final remoteCard = find.byKey(
        const ValueKey<String>('model-card-reviewed-model-25'),
      );
      await tester.scrollUntilVisible(
        remoteCard,
        240,
        scrollable: _storeScrollable('model-store-scroll'),
      );

      expect(tester.widget<AppSecondaryCard>(remoteCard).onTap, isNull);
      expect(
        find.byKey(
          const ValueKey<String>(
            'model-capability-unavailable-reviewed-model-25',
          ),
        ),
        findsOneWidget,
      );

      snapshots.refresh(
        AppCapabilitySnapshotContext(
          hostPlatform: AppHostPlatform.macos,
          rolloutGeneration: 1,
        ),
      );
      await tester.pump();

      expect(tester.widget<AppSecondaryCard>(remoteCard).onTap, isNotNull);
      expect(
        find.byKey(
          const ValueKey<String>(
            'model-capability-unavailable-reviewed-model-25',
          ),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('authoritative selection state keeps remote cards fail-closed', (
    tester,
  ) async {
    final avatars = _AuthoritativeUiAvatarConfig()
      ..beginAuthoritativeSelectionStartup();
    final controller = AvatarModelStoreController(
      catalog: _PageAvatarModelStoreGateway(),
      avatars: avatars,
    );

    await tester.pumpWidget(
      MaterialApp(home: AvatarsPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    final remoteCard = find.byKey(
      const ValueKey<String>('model-card-reviewed-model-25'),
    );
    await tester.scrollUntilVisible(
      remoteCard,
      240,
      scrollable: _storeScrollable('model-store-scroll'),
    );

    expect(tester.widget<AppSecondaryCard>(remoteCard).onTap, isNull);

    avatars.markAuthoritativeSelectionReady();
    await tester.pump();
    expect(tester.widget<AppSecondaryCard>(remoteCard).onTap, isNotNull);

    avatars.markAuthoritativeSelectionReadOnly();
    await tester.pump();
    expect(tester.widget<AppSecondaryCard>(remoteCard).onTap, isNull);
  });

  testWidgets('capability cards reflow at 320px with maximum text scaling', (
    tester,
  ) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(320, 700));
    final controller = AvatarModelStoreController(
      catalog: _PageAvatarModelStoreGateway(),
      avatars: AvatarConfigService(),
    );

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) {
          final media = MediaQuery.of(context);
          return MediaQuery(
            data: media.copyWith(
              textScaler: const TextScaler.linear(3),
              disableAnimations: true,
            ),
            child: child!,
          );
        },
        home: AvatarsPage(controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    final blockedCard = find.byKey(
      const ValueKey<String>('model-card-reviewed-model-27'),
    );
    await tester.scrollUntilVisible(
      blockedCard,
      260,
      scrollable: _storeScrollable('model-store-scroll'),
    );

    expect(blockedCard, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('public model selection does not request workshop uploads', (
    tester,
  ) async {
    final gateway = _PageAvatarModelStoreGateway(failMine: true);
    final controller = AvatarModelStoreController(
      catalog: gateway,
      avatars: AvatarConfigService(),
    );
    await tester.pumpWidget(
      MaterialApp(home: AvatarsPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(gateway.uploadListRequests, 0);
    expect(controller.uploadsError.value, isNull);
    expect(find.byType(TabBar), findsNothing);
    expect(find.text('Actions'), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('model-store-gallery')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'keeps the skin gallery usable on a 375px phone and in landscape',
    (tester) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(375, 812));
      final controller = AvatarModelStoreController(
        catalog: _PageAvatarModelStoreGateway(),
        avatars: AvatarConfigService(),
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) {
            final media = MediaQuery.of(context);
            return MediaQuery(
              data: media.copyWith(
                textScaler: const TextScaler.linear(1.3),
                disableAnimations: true,
              ),
              child: child!,
            );
          },
          home: AvatarsPage(controller: controller),
        ),
      );
      await tester.pump();

      expect(find.text('avatar_store.title'.tr), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.binding.setSurfaceSize(const Size(812, 375));
      await tester.pump();

      expect(find.text('avatar_store.title'.tr), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('model gallery and workshop translate without retired actions', (
    tester,
  ) async {
    AppLocalization.updateLocale(const Locale('zh', 'CN'));
    final controller = AvatarModelStoreController(
      catalog: _PageAvatarModelStoreGateway(),
      avatars: AvatarConfigService(),
    );
    await tester.pumpWidget(
      MaterialApp(home: AvatarsPage(controller: controller)),
    );
    await tester.pumpAndSettle();
    expect(find.text('avatar_store.title'.tr), findsOneWidget);
    expect(find.text('动作'), findsNothing);
    expect(find.text('Avatar Store'), findsNothing);
    expect(find.byType(TabBar), findsNothing);
    expect(
      find.byKey(const ValueKey<String>('model-card-agent')),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is Semantics && widget.properties.label == 'Joy，内置模型，免费',
      ),
      findsOneWidget,
    );
    expect(find.text('Maaso 原创'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

void _expectAgentHeadVisible(WidgetTester tester, Finder preview) {
  final renderImage = tester.renderObject<RenderImage>(
    find.descendant(of: preview, matching: find.byType(RawImage)),
  );
  final image = renderImage.image;
  expect(image, isNotNull);
  final sourceSize = Size(image!.width.toDouble(), image.height.toDouble());
  expect(renderImage.fit, BoxFit.contain);
  final fitted = applyBoxFit(
    renderImage.fit ?? BoxFit.scaleDown,
    sourceSize,
    renderImage.size,
  );
  final alignment = renderImage.alignment.resolve(TextDirection.ltr);
  final source = alignment.inscribe(fitted.source, Offset.zero & sourceSize);
  expect(source, Offset.zero & sourceSize);
  final destination = alignment.inscribe(
    fitted.destination,
    Offset.zero & renderImage.size,
  );
  RenderObject? ancestor = renderImage.parent;
  while (ancestor != null && ancestor is! RenderClipRect) {
    ancestor = ancestor.parent;
  }
  expect(ancestor, isA<RenderClipRect>());
  final clip = ancestor! as RenderClipRect;
  // Preserve the whole source image, including both head and feet, in the clip.
  final visibleHead = MatrixUtils.transformRect(
    renderImage.getTransformTo(clip),
    destination,
  );
  expect(visibleHead.left, greaterThanOrEqualTo(-0.1));
  expect(visibleHead.top, greaterThanOrEqualTo(-0.1));
  expect(visibleHead.right, lessThanOrEqualTo(clip.size.width + 0.1));
  expect(visibleHead.bottom, lessThanOrEqualTo(clip.size.height + 0.1));
}

Finder _storeScrollable(String key) {
  return find
      .descendant(
        of: find.byKey(ValueKey<String>(key)),
        matching: find.byType(Scrollable),
      )
      .first;
}

final class _AuthoritativeUiAvatarConfig extends AvatarConfigService {
  @override
  bool get usesAuthoritativeSelection => true;
}

class _MattModelGateway extends _PageAvatarModelStoreGateway {
  @override
  Future<List<ApprovedAvatarModel>> listApprovedModels() async => [
    ApprovedAvatarModel.fromJson({
      'id': 44,
      'modelKey': BundledAvatarContract.mattModelKey,
      'displayName': 'Matt',
      'modelSource': 'official',
      'assetUrl': BundledAvatarContract.mattAssetUrl,
      'assetSha256': BundledAvatarContract.mattAssetSha256,
      'runtimeConfig': BundledAvatarContract.mattRuntimeConfig,
      'compatibility': {
        'backends': ['unity'],
      },
    }),
  ];
}

class _PageAvatarModelStoreGateway implements AvatarModelStoreGateway {
  _PageAvatarModelStoreGateway({this.failMine = false});

  final bool failMine;
  int uploadListRequests = 0;
  int catalogListRequests = 0;

  @override
  Future<List<ApprovedAvatarModel>> listApprovedModels() async {
    catalogListRequests += 1;
    return [
      const ApprovedAvatarModel(
        id: 25,
        modelKey: 'masso.official.modular-female',
        displayName: 'Modular Female',
        modelSource: 'official',
        assetUrl: 'https://cdn.example.com/modular-female.bundle',
        assetSha256: 'female-preview-test',
        runtimeConfig: {'assetName': 'Female'},
        compatibility: {
          'backends': ['unity'],
        },
      ),
      const ApprovedAvatarModel(
        id: 26,
        // A user's similarly named male upload is not a retired official SKU.
        modelKey: 'user-upload-male-26',
        displayName: 'Modular Male',
        modelSource: 'uploaded',
        assetUrl: 'https://cdn.example.com/modular-male.bundle',
        assetSha256: 'male-preview-test',
        runtimeConfig: {'assetName': 'Male'},
        compatibility: {
          'backends': ['unity'],
        },
      ),
      ApprovedAvatarModel(
        id: 27,
        modelKey: 'masso.community.needs-rig-fix',
        displayName: 'Needs Rig Fix',
        modelSource: 'community',
        assetUrl: 'https://cdn.example.com/needs-rig-fix.bundle',
        assetSha256: 'needs-rig-fix-preview-test',
        runtimeConfig: const {'assetName': 'NeedsRigFix'},
        compatibility: const {
          'backends': ['unity'],
        },
        capabilityProfile: AvatarCapabilityProfile.fromJson(const {
          'schemaVersion': 1,
          'source': 'catalog',
          'state': 'incompatible',
          'rig': {
            'humanoid': false,
            'head': true,
            'leftEye': true,
            'rightEye': true,
          },
          'behavior': {
            'lookAt': true,
            'lipSync': true,
            'blink': true,
            'expressions': true,
          },
          'render': {'renderable': true},
          'issues': [
            {'code': 'missing_humanoid', 'severity': 'blocker'},
          ],
        }),
      ),
    ];
  }

  @override
  Future<List<OwnAvatarUpload>> listMyUploads() async {
    uploadListRequests += 1;
    if (failMine) throw StateError('Owner uploads unavailable');
    return <OwnAvatarUpload>[
      OwnAvatarUpload(
        id: 42,
        displayName: 'Lumen Explorer',
        fileName: 'lumen.bundle',
        status: AvatarUploadStatus.pendingReview,
        statusMessage: null,
        modelId: null,
        createdAt: DateTime.utc(2026, 7, 14, 10),
        updatedAt: DateTime.utc(2026, 7, 14, 10, 1),
      ),
    ];
  }

  @override
  Future<OwnAvatarUpload> uploadBundle({
    required File file,
    required String displayName,
    required AvatarModelUploadCover cover,
  }) => throw UnimplementedError();
}

class _OwnedApprovedModelGateway extends _PageAvatarModelStoreGateway {
  @override
  Future<List<OwnAvatarUpload>> listMyUploads() async => [
    OwnAvatarUpload(
      id: 99,
      displayName: 'My approved character',
      fileName: 'my-character.vrm',
      status: AvatarUploadStatus.approved,
      statusMessage: null,
      modelId: 25,
      createdAt: DateTime.utc(2026, 10, 14),
      updatedAt: DateTime.utc(2026, 10, 14),
    ),
  ];
}

class _FullBodyPreviewModelGateway extends _OwnedApprovedModelGateway {
  @override
  Future<List<ApprovedAvatarModel>> listApprovedModels() async => [
    const ApprovedAvatarModel(
      id: 25,
      modelKey: 'masso.community.full-body-preview',
      displayName: 'Full body model',
      modelSource: 'community',
      assetUrl: 'https://cdn.example.com/full-body.bundle',
      assetSha256: 'full-body-preview-test',
      runtimeConfig: {'assetName': 'FullBody'},
      compatibility: {
        'backends': ['unity'],
      },
      previewImageUrl: 'https://cdn.example.com/full-body.png',
    ),
  ];
}

class _DisplayNameAvatarConfig extends AvatarConfigService {
  _DisplayNameAvatarConfig()
    : super(
        initialCatalog: [
          ...AvatarConfigService.builtInCatalog,
          const AvatarOption(
            id: 'custom-agent',
            name: 'Agent',
            backend: AvatarBackendKind.unity,
            modelUrl: 'unity://masso/custom-agent',
            previewAssetPath: 'assets/model_store/agent.png',
          ),
        ],
      );
  final selectedIds = <String>[];

  @override
  Future<void> select(String id, {String? expectedAssetVersionDigest}) async {
    selectedIds.add(id);
    selectedId.value = id;
  }
}

class _PreviewUploadController extends AvatarModelStoreController {
  _PreviewUploadController(this.cover)
    : super(
        catalog: _PageAvatarModelStoreGateway(),
        avatars: AvatarConfigService(),
      );
  final AvatarModelUploadCover cover;
  bool confirmed = false;

  @override
  Future<OwnAvatarUpload?> pickAndUpload(
    Future<PlatformFile?> Function() pickFile, {
    required Future<PlatformFile?> Function() pickCover,
    required Future<bool> Function(String, AvatarModelUploadCover) confirm,
  }) async {
    confirmed = await confirm('My full-body model', cover);
    return null;
  }
}

class _CoverUploadGateway extends _FullBodyPreviewModelGateway {
  @override
  Future<List<OwnAvatarUpload>> listMyUploads() async => [
    OwnAvatarUpload(
      id: 99,
      displayName: 'My uploaded model',
      fileName: 'mine.vrm',
      status: AvatarUploadStatus.approved,
      statusMessage: null,
      modelId: 25,
      createdAt: DateTime.utc(2026, 10, 17),
      updatedAt: DateTime.utc(2026, 10, 17),
      previewImageUrl: 'https://cdn.example.com/full-body.png',
    ),
  ];
}

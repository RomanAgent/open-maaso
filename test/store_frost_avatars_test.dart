import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/avatar_config_service.dart';
import 'package:maaso/src/core/services/avatar_model_catalog_service.dart';
import 'package:maaso/src/core/services/avatar_model_upload_cover.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';
import 'package:maaso/src/features/avatars/application/avatar_model_store_controller.dart';
import 'package:maaso/src/features/avatars/presentation/avatars_page.dart';

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
    AppLocalization.updateLocale(const Locale('en', 'US'));
  });

  tearDown(() {
    appServices.reset();
    AppLocalization.updateLocale(const Locale('en', 'US'));
  });

  for (final brightness in Brightness.values) {
    testWidgets('public model cards use neutral frost in $brightness', (
      tester,
    ) async {
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(393, 852));
      final avatars = _FrostAvatarConfig();
      final controller = AvatarModelStoreController(
        catalog: _FrostCatalog(),
        avatars: avatars,
      );
      await tester.pumpWidget(_page(controller, brightness: brightness));
      await tester.pumpAndSettle();

      final current = find.byKey(const ValueKey('model-card-agent'));
      final other = find.byKey(const ValueKey('model-card-test-model'));
      expect(tester.getRect(current).top, tester.getRect(other).top);
      expect(tester.getRect(current).left, 20);
      for (final id in ['agent', 'test-model']) {
        final card = find.byKey(ValueKey('model-card-$id'));
        final component = tester.widget<AppSecondaryCard>(card);
        final glass = MaasoGlassTheme.of(tester.element(card));
        expect(component.cornerRadius, MaasoGlassTheme.surfaceRadius);
        expect(component.tone, AppSecondaryCardTone.normal);
        expect(
          (tester
                      .widget<Ink>(find.byKey(ValueKey('model-frost-fill-$id')))
                      .decoration!
                  as BoxDecoration)
              .color,
          glass.muted,
        );
        expect(
          tester.widget<Image>(find.byKey(ValueKey('model-preview-$id'))).fit,
          BoxFit.contain,
        );
        final action = tester.widget<AppGlassButton>(
          find.byKey(ValueKey('model-select-$id')),
        );
        expect(action.label, 'skill_store.view_details'.tr);
        expect(action.primary, id != 'agent');
        expect(action.fullWidth, isTrue);
      }
      expect(find.byKey(const ValueKey('model-current-agent')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('model-current-test-model')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('model-workshop-upload')), findsNothing);
      expect(find.byType(BackdropFilter), findsNothing);
      expect(avatars.selections, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  for (final locale in [const Locale('en', 'US'), const Locale('zh', 'CN')]) {
    testWidgets('model detail remains confirmable at 320px and 2x in $locale', (
      tester,
    ) async {
      AppLocalization.updateLocale(locale);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.binding.setSurfaceSize(const Size(320, 700));
      final avatars = _FrostAvatarConfig();
      final controller = AvatarModelStoreController(
        catalog: _FrostCatalog(),
        avatars: avatars,
      );
      await tester.pumpWidget(_page(controller, textScale: 2));
      await tester.pumpAndSettle();
      final current = find.byKey(const ValueKey('model-card-agent'));
      expect(tester.getSize(current).width, 288);
      final badge = find.byKey(const ValueKey('model-current-agent'));
      final preview = find.byKey(const ValueKey('model-preview-agent'));
      expect(
        tester.getRect(badge).bottom,
        lessThan(tester.getRect(preview).top),
      );

      final details = find.byKey(const ValueKey('model-select-test-model'));
      await tester.scrollUntilVisible(
        details,
        240,
        scrollable: find
            .descendant(
              of: find.byKey(const ValueKey('model-store-scroll')),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      expect(details.hitTestable(), findsOneWidget);
      expect(tester.getRect(details).bottom, lessThanOrEqualTo(700));
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(avatars.selections, isEmpty);
      final detail = find.byKey(const ValueKey('model-detail-sheet'));
      expect(detail, findsOneWidget);
      expect(
        tester
            .widget<Image>(
              find.descendant(of: detail, matching: find.byType(Image)),
            )
            .fit,
        BoxFit.contain,
      );
      final select = find.byKey(const ValueKey('model-detail-select'));
      await tester.ensureVisible(select);
      await tester.pumpAndSettle();
      expect(select.hitTestable(), findsOneWidget);
      await tester.tap(select);
      await tester.pumpAndSettle();
      expect(find.text('asset_store.confirm_select'.tr), findsOneWidget);
      expect(avatars.selections, isEmpty);
      final cancel = find.byKey(const ValueKey('model-confirm-cancel'));
      await tester.ensureVisible(cancel);
      await tester.pumpAndSettle();
      expect(cancel.hitTestable(), findsOneWidget);
      await tester.tap(cancel);
      await tester.pumpAndSettle();
      expect(avatars.selections, isEmpty);
      expect(detail, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty search resets without refreshing the catalog', (
    tester,
  ) async {
    final gateway = _FrostCatalog();
    final controller = AvatarModelStoreController(
      catalog: gateway,
      avatars: _FrostAvatarConfig(),
    );
    await tester.pumpWidget(_page(controller));
    await tester.pumpAndSettle();
    final requests = gateway.requests;
    final search = find.descendant(
      of: find.byKey(const ValueKey('model-store-search')),
      matching: find.byType(TextField),
    );
    await tester.enterText(search, 'nothing-matches');
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('model-store-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('model-card-agent')), findsNothing);
    final clear = find.byKey(const ValueKey('model-empty-clear'));
    await tester.ensureVisible(clear);
    await tester.tap(clear);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('model-store-empty')), findsNothing);
    expect(find.byKey(const ValueKey('model-card-agent')), findsOneWidget);
    expect(gateway.requests, requests);
    expect(tester.takeException(), isNull);
  });
}

Widget _page(
  AvatarModelStoreController controller, {
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) => MaterialApp(
  theme: ThemeData(
    brightness: brightness,
    splashFactory: NoSplash.splashFactory,
  ),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: AvatarsPage(controller: controller, header: const SizedBox.shrink()),
);

class _FrostAvatarConfig extends AvatarConfigService {
  _FrostAvatarConfig()
    : super(
        initialCatalog: [
          ...AvatarConfigService.builtInCatalog,
          const AvatarOption(
            id: 'test-model',
            name: 'Test model',
            backend: AvatarBackendKind.unity,
            modelUrl: 'unity://masso/test-model',
            previewAssetPath: 'assets/model_store/agent.png',
          ),
        ],
      );

  final selections = <String>[];

  @override
  Future<void> select(String id, {String? expectedAssetVersionDigest}) async {
    selections.add(id);
    selectedId.value = id;
  }
}

class _FrostCatalog implements AvatarModelStoreGateway {
  int requests = 0;

  @override
  Future<List<ApprovedAvatarModel>> listApprovedModels() async {
    requests++;
    return [];
  }

  @override
  Future<List<OwnAvatarUpload>> listMyUploads() async => [];

  @override
  Future<OwnAvatarUpload> uploadBundle({
    required File file,
    required String displayName,
    required AvatarModelUploadCover cover,
  }) => throw UnimplementedError();
}

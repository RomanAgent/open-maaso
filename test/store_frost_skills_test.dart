import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';
import 'package:maaso/src/features/skills/application/skill_store_controller.dart';
import 'package:maaso/src/features/skills/data/skill_marketplace_models.dart';
import 'package:maaso/src/features/skills/presentation/skill_store_page.dart';

void main() {
  late _StoreController store;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    AppLocalization.updateLocale(const Locale('en'));
    store = _StoreController();
    appServices.put<SkillStoreController>(store);
  });

  tearDown(() async {
    await appServices.reset();
  });

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'public Skill group fits 320px at $scale in ${brightness.name}',
        (tester) async {
          store.skills.assignAll([
            _skill(1, 'A helper with a longer title'),
            _skill(2, 'Another useful helper'),
          ]);
          await _mount(tester, brightness: brightness, scale: scale);

          final group = find.byKey(
            const ValueKey('fallback-skill-frost-group'),
          );
          final glass = MaasoGlassTheme.of(tester.element(group));
          final decoration =
              tester.widget<DecoratedSliver>(group).decoration as BoxDecoration;
          expect(decoration.color, glass.muted);
          expect(decoration.border, isNull);
          expect(find.byType(BackdropFilter), findsNothing);
          expect(find.byType(AppSecondaryCard), findsNothing);
          expect(find.text('A helper with a longer title'), findsOneWidget);
          expect(
            find.textContaining('skills.community'.tr),
            findsAtLeastNWidgets(1),
          );
          expect(store.installedVersions, isEmpty);
          expect(tester.takeException(), isNull);

          await tester.enterText(find.byType(TextField), 'Another');
          await tester.pumpAndSettle();
          expect(find.text('Another useful helper'), findsOneWidget);
          expect(find.text('A helper with a longer title'), findsNothing);
          expect(tester.takeException(), isNull);

          store.installations[2] = const MarketplaceInstallation(
            installationId: 2,
            status: SkillInstallationStatus.disabled,
            skillVersionId: 2,
            agentId: 'self',
          );
          await tester.pumpAndSettle();
          expect(find.text('skill_store.disabled_badge'.tr), findsOneWidget);
          expect(store.installedVersions, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets(
    'group row keeps selected version and explicit permission consent',
    (tester) async {
      final original = _skill(
        17,
        'Permission helper',
        permissions: {'conversation.read', 'memory.read'},
      );
      store.skills.add(original);
      await _mount(tester);

      // The whole grouped row remains an entry to details, never an install.
      await tester.tap(find.text(original.title));
      await tester.pumpAndSettle();
      expect(store.installedVersions, isEmpty);
      expect(find.byType(CheckboxListTile), findsNothing);
      store.skills.assignAll([
        _skill(18, original.title, permissions: {'memory.read'}),
      ]);
      await tester.pumpAndSettle();

      final install = find.text('skill_store.confirm_permissions_install'.tr);
      await tester.ensureVisible(install);
      await tester.tap(install);
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNWidgets(2));
      final confirmation = find.byWidgetPredicate(
        (widget) =>
            widget is AppGlassButton &&
            widget.icon == Icons.verified_user_rounded,
      );
      expect(tester.widget<AppGlassButton>(confirmation).onPressed, isNull);
      await tester.tap(find.byType(CheckboxListTile).first);
      await tester.pumpAndSettle();
      expect(tester.widget<AppGlassButton>(confirmation).onPressed, isNull);
      expect(store.installedVersions, isEmpty);
      await tester.tap(find.byType(CheckboxListTile).last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(confirmation);
      await tester.tap(confirmation);
      await tester.pumpAndSettle();

      expect(store.consents.single, original.permissions);
      expect(store.installedVersions, [17]);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _mount(
  WidgetTester tester, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) async {
  tester.view.physicalSize = const Size(320, 812);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: appProviderContainer,
      child: MaterialApp(
        theme: ThemeData(
          brightness: brightness,
          splashFactory: NoSplash.splashFactory,
        ),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const SkillStorePage(header: SizedBox(height: 40)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

MarketplaceSkill _skill(
  int version,
  String title, {
  Set<String> permissions = const {},
}) => MarketplaceSkill(
  skillVersionId: version,
  submissionId: version,
  skillKey: 'helper-$version',
  title: title,
  summary: 'Helps organize a task and explain each step clearly.',
  coverAssetUrl: '',
  publisherId: 'author',
  versionName: '1.0.0',
  permissions: permissions,
  category: SkillCategory.reasoning,
  instruction: 'Use only the requested abilities.',
  examples: const [],
  manifestDigest: 'digest',
  isFree: true,
  safetyStatus: SkillSafetyStatus.passed,
  visibility: SkillVisibility.public,
);

class _StoreController extends AppController implements SkillStoreController {
  @override
  final skills = <MarketplaceSkill>[].obs;
  @override
  final rankedSkills = <MarketplaceSkill>[].obs;
  @override
  final isLoading = false.obs;
  @override
  final error = RxnString();
  final installations = <int, MarketplaceInstallation>{}.obs;
  final consents = <Set<String>>[];
  final installedVersions = <int>[];

  @override
  MarketplaceInstallation? installationFor(MarketplaceSkill skill) =>
      installations[skill.skillVersionId];
  @override
  bool isInstalling(MarketplaceSkill skill) => false;
  @override
  bool isChangingInstallation(MarketplaceSkill skill) => false;
  @override
  bool isLiking(MarketplaceSkill skill) => false;
  @override
  Future<void> reload({String? query}) async {}

  @override
  Future<void> install(MarketplaceSkill skill, Set<String> accepted) async {
    consents.add(Set.of(accepted));
    installedVersions.add(skill.skillVersionId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

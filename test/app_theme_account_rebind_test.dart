import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/app.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/theme_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late GoRouter router;
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    router = GoRouter(
      navigatorKey: rootNavigatorKey,
      routes: [GoRoute(path: '/', builder: (_, _) => const _ThemeProbe())],
    );
    appNavigation.configure(router);
  });
  tearDown(() async {
    router.dispose();
    await appServices.reset();
  });

  testWidgets('app binds the account theme mounted after signed-out startup', (
    tester,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: appProviderContainer,
        child: const MaasoApp(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('light'), findsOneWidget);

    final theme = ThemeService()..setMode(ThemeModePreference.dark);
    appServices.put(theme);
    await tester.pumpAndSettle();
    expect(find.text('dark'), findsOneWidget);
    theme.setMode(ThemeModePreference.light);
    await tester.pumpAndSettle();
    expect(find.text('light'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'light choice follows replacement account theme instead of retired dark service',
    (tester) async {
      final previous = appServices.put(
        ThemeService()..setMode(ThemeModePreference.dark),
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaasoApp(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('dark'), findsOneWidget);

      await appServices.delete<ThemeService>(force: true);
      final current = appServices.put(
        ThemeService()..setMode(ThemeModePreference.dark),
      );
      await tester.pumpAndSettle();
      current.setMode(ThemeModePreference.light);
      await tester.pumpAndSettle();
      expect(current.brightness.value, Brightness.light);
      expect(find.text('light'), findsOneWidget);

      previous.setMode(ThemeModePreference.dark);
      await tester.pumpAndSettle();
      expect(find.text('light'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

class _ThemeProbe extends StatelessWidget {
  const _ThemeProbe();
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Text(Theme.of(context).brightness.name));
}

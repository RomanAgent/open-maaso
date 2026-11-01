import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:maaso/src/app/routing/router_config.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Login and Home both use zero-duration route pages', (
    tester,
  ) async {
    await appServices.reset();
    appServices.testMode = true;
    addTearDown(appServices.reset);
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final router = createAppRouter(initialLocation: AppRoutes.login);
    addTearDown(router.dispose);
    for (final path in [AppRoutes.login, AppRoutes.home]) {
      final route = router.configuration.routes
          .whereType<GoRoute>()
          .singleWhere((candidate) => candidate.path == path);
      final page = route.pageBuilder!(
        context,
        GoRouterState(
          router.configuration,
          uri: Uri.parse(path),
          matchedLocation: path,
          fullPath: path,
          pathParameters: const {},
          pageKey: ValueKey<String>(path),
        ),
      );
      expect(page, isA<NoTransitionPage<void>>(), reason: path);
      expect(
        (page as NoTransitionPage<void>).transitionDuration,
        Duration.zero,
        reason: path,
      );
    }
  });
}

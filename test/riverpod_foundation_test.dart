import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

class _LifecycleService extends AppService {
  int initCount = 0;
  int readyCount = 0;
  int closeCount = 0;

  @override
  void onInit() {
    super.onInit();
    initCount++;
  }

  @override
  void onReady() {
    super.onReady();
    readyCount++;
  }

  @override
  void onClose() {
    closeCount++;
    super.onClose();
  }
}

class _RouteScopedController extends AppController {}

class _RouteScopedDependencies extends RouteDependencies {
  @override
  void dependencies() {
    appServices.lazyPut<_RouteScopedController>(_RouteScopedController.new);
  }
}

class _ServiceGraphWatcher extends ConsumerWidget {
  const _ServiceGraphWatcher({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appServicesProvider);
    return child;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
  });

  tearDown(() async {
    await appServices.reset();
  });

  testWidgets('Rx values rebuild through the Riverpod container', (
    tester,
  ) async {
    final count = 0.obs;

    await tester.pumpWidget(
      MaterialApp(home: AppReactiveBuilder(() => Text('count=${count.value}'))),
    );
    expect(find.text('count=0'), findsOneWidget);

    count.value = 7;
    await tester.pump();

    expect(find.text('count=7'), findsOneWidget);
  });

  testWidgets('service registry preserves lifecycle semantics', (tester) async {
    final service = appServices.put(_LifecycleService());

    expect(appServices.find<_LifecycleService>(), same(service));
    expect(service.initCount, 1);

    await tester.pumpWidget(const SizedBox());
    expect(service.readyCount, 1);

    expect(await appServices.delete<_LifecycleService>(), isTrue);
    expect(service.closeCount, 1);
    expect(appServices.isRegistered<_LifecycleService>(), isFalse);
  });

  test('overlapping route scopes retain shared registrations', () async {
    final firstScope = appServices.capture(
      () => appServices.lazyPut<_LifecycleService>(_LifecycleService.new),
    );
    final secondScope = appServices.capture(
      () => appServices.lazyPut<_LifecycleService>(_LifecycleService.new),
    );

    final service = appServices.find<_LifecycleService>();
    expect(firstScope, contains(_LifecycleService));
    expect(secondScope, contains(_LifecycleService));

    await appServices.releaseCaptured(_LifecycleService);
    expect(appServices.find<_LifecycleService>(), same(service));

    await appServices.releaseCaptured(_LifecycleService);
    expect(appServices.isRegistered<_LifecycleService>(), isFalse);
    expect(service.closeCount, 1);
  });

  testWidgets(
    'route dependencies defer graph notification until widget build completes',
    (tester) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: MaterialApp(
            home: _ServiceGraphWatcher(
              child: RouteDependenciesScope(
                dependencies: _RouteScopedDependencies(),
                child: const SizedBox(),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      expect(appServices.isRegistered<_RouteScopedController>(), isTrue);

      await tester.pumpWidget(const SizedBox());
      await tester.pump();

      expect(appServices.isRegistered<_RouteScopedController>(), isFalse);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });

  tearDown(() async {
    await appServices.reset();
  });

  test('reactive writes outside widget lifecycle stay synchronous', () {
    final value = 'initial'.obs;

    value.value = 'updated';

    expect(value.value, 'updated');
  });

  testWidgets(
    'lazy controller may initialize reactive state during a route build',
    (tester) async {
      appServices.lazyPut<_BuildMutationController>(
        _BuildMutationController.new,
      );

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: const MaterialApp(home: _LazyControllerRoute()),
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('ready:1,2'), findsOneWidget);
    },
  );

  testWidgets('initState and dispose writes are deferred safely', (
    tester,
  ) async {
    final phase = 'created'.obs;
    final steps = <int>[].obs;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: appProviderContainer,
        child: MaterialApp(
          home: _LifecycleMutationRoute(phase: phase, steps: steps),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(phase.value, 'mounted');
    expect(steps, <int>[1, 2]);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(phase.value, 'disposed');
  });

  testWidgets(
    'out-of-frame buildScope defers publication but exposes new value',
    (tester) async {
      final key = GlobalKey<_IdleBuildMutationState>();
      final signal = 0.obs;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: appProviderContainer,
          child: MaterialApp(
            home: _IdleBuildMutation(key: key, signal: signal),
          ),
        ),
      );
      await tester.pump();
      key.currentState!.mutate = true;
      final element = key.currentContext! as Element;
      element.markNeedsBuild();
      tester.binding.buildOwner!.buildScope(element);
      expect(tester.takeException(), isNull);
      expect(signal.value, 1);
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('1'), findsOneWidget);
    },
  );
}

class _IdleBuildMutation extends StatefulWidget {
  const _IdleBuildMutation({super.key, required this.signal});
  final RxInt signal;
  @override
  State<_IdleBuildMutation> createState() => _IdleBuildMutationState();
}

class _IdleBuildMutationState extends State<_IdleBuildMutation> {
  bool mutate = false;
  @override
  Widget build(BuildContext context) {
    if (mutate) {
      mutate = false;
      widget.signal.value = 1;
    }
    return AppReactiveBuilder(() => Text('${widget.signal.value}'));
  }
}

class _BuildMutationController extends AppController {
  final phase = 'created'.obs;
  final steps = <int>[].obs;

  @override
  void onInit() {
    super.onInit();
    phase.value = 'ready';
    steps
      ..add(1)
      ..add(2);
  }
}

class _LazyControllerRoute extends ConsumerWidget {
  const _LazyControllerRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(appServicesProvider);
    final controller = appServices.find<_BuildMutationController>();
    return AppReactiveBuilder(
      () => Text('${controller.phase.value}:${controller.steps.join(',')}'),
    );
  }
}

class _LifecycleMutationRoute extends StatefulWidget {
  const _LifecycleMutationRoute({required this.phase, required this.steps});

  final RxString phase;
  final RxList<int> steps;

  @override
  State<_LifecycleMutationRoute> createState() =>
      _LifecycleMutationRouteState();
}

class _LifecycleMutationRouteState extends State<_LifecycleMutationRoute> {
  @override
  void initState() {
    super.initState();
    widget.phase.value = 'mounted';
    widget.steps
      ..add(1)
      ..add(2);
  }

  @override
  void dispose() {
    widget.phase.value = 'disposed';
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppReactiveBuilder(
      () => Text('${widget.phase.value}:${widget.steps.join(',')}'),
    );
  }
}

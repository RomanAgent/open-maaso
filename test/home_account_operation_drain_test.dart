import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/agent_runtime_registry.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
  });

  tearDown(() async {
    await appServices.reset();
  });

  test(
    'gated Home DB work blocks shutdown and post-retire work is fenced',
    () async {
      final database = _GatedWidgetDatabase();
      final registry = appServices.put(AgentRuntimeRegistry());
      appServices.put<DBService>(database);
      final controller = HomeController();
      addTearDown(controller.onClose);

      final admitted = controller.loadDock();
      await database.started.future;

      var shutdownCompleted = false;
      final shutdown = registry.shutdown().then(
        (_) => shutdownCompleted = true,
      );
      await Future<void>.delayed(Duration.zero);
      expect(shutdownCompleted, isFalse);

      await controller.loadDock();
      expect(
        database.calls,
        1,
        reason: 'retired Home work must not reach the DB',
      );

      database.release.complete();
      await admitted;
      await shutdown;
      expect(shutdownCompleted, isTrue);
    },
  );
}

final class _GatedWidgetDatabase extends DBService {
  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int calls = 0;

  @override
  Future<List<AgentWidget>> getAllWidgets() async {
    calls += 1;
    if (!started.isCompleted) started.complete();
    await release.future;
    return const <AgentWidget>[];
  }
}

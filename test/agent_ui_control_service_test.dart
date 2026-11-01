import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_services.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_service.dart';
import 'package:maaso/src/features/agent/application/ui_control/agent_ui_control_state.dart';
import 'package:maaso/src/features/agent/application/ui_control/page_agent_adapter_registry.dart';

void main() {
  group('AgentUiControlService', () {
    late AgentUiControlService service;

    setUp(() async {
      await appServices.reset();
      service = appServices.put(AgentUiControlService(), permanent: true);
    });

    tearDown(() async {
      await appServices.reset();
    });

    test('owns a registry that validates with its coordinator lease', () {
      const adapter = _TestPageAdapter('/test-page');
      service.adapters.register(adapter);
      final lease = service.coordinator
          .begin(sessionId: 'owned', purpose: 'operate test page')
          .value!;

      final resolved = service.adapters.resolve<_TestPageAdapter>(
        route: adapter.route,
        lease: lease,
      );

      expect(resolved.isSuccess, isTrue);
      expect(resolved.value, same(adapter));
    });

    test(
      'app service reset clears adapters and closes the coordinator',
      () async {
        service.adapters.register(const _TestPageAdapter('/test-page'));
        expect(service.adapters.length, 1);

        await appServices.reset();

        expect(service.adapters.length, 0);
        final result = service.coordinator.begin(
          sessionId: 'after-close',
          purpose: 'must not start',
        );
        expect(result.status, AgentUiControlResultStatus.invalidState);
      },
    );
  });
}

class _TestPageAdapter implements PageAgentAdapter {
  const _TestPageAdapter(this.route);

  @override
  final String route;
}

import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/widgets/widget_stage_controller.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'conversation_entry_controllers_test.dart' show ConversationEntryHarness;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late ConversationEntryHarness harness;
  late AgentWidget item;
  late SurfaceRuntime surface;
  setUp(() async {
    appServices.testMode = true;
    harness = await ConversationEntryHarness.create();
    surface = appServices.put(SurfaceRuntime());
    appServices.put(WidgetStageController());
    item = AgentWidget(
      agentId: 'self',
      title: '旅行助手',
      kind: 'surface',
      createdAt: DateTime.now(),
      seen: true,
      spec: {
        'surfaceId': 'my-trip',
        'surfaceKind': 'card',
        'rendering': 'dom',
        'experienceType': 'utility',
        'html': '<main>Travel plan</main>',
        'css': '',
        'js': '',
        'manifest': {'events': [], 'actions': []},
      },
    );
    AppletLocalOwnership.stamp(item);
    item.id = await harness.database.saveAgentWidget(item);
    appletEditReference.value = AppletEditReference(
      item: item,
      scopeKey: AppletLocalOwnership.currentScopeKey(),
    );
  });
  tearDown(() async {
    clearAppletEditReference();
    await harness.close();
  });
  test(
    'edit selection opens exact existing project and reaches conversation extra context',
    () async {
      var called = false;
      harness.runtime.runChat = (context, history) async {
        called = true;
        final quoted = history
            .map((message) => message.content)
            .whereType<String>()
            .firstWhere(
              (text) => text.contains('user_selected_applet_for_editing'),
            );
        final selected = jsonDecode(quoted) as Map;
        expect(selected['surfaceId'], 'my-trip');
        expect(context.text, '增加一个预算功能');
        expect(surface.activeSurfaceId, 'my-trip');
        return ExecutionResult.success('ready');
      };
      harness.home.inputController.text = '增加一个预算功能';
      await harness.home.send();
      expect(called, isTrue);
      expect(await harness.database.getAllWidgets(), hasLength(1));
      expect(appletEditReference.value!.item.id, item.id);
    },
  );
  test(
    'deleted and foreign-account edit references cannot prepare context',
    () async {
      await harness.database.deleteWidget(item.id!);
      await expectLater(prepareAppletEditContext(), throwsStateError);
      appletEditReference.value = AppletEditReference(
        item: item,
        scopeKey: 'other-account',
      );
      await expectLater(prepareAppletEditContext(), throwsStateError);
      expect(appletEditReference.value, isNull);
    },
  );
  test(
    'selected edit baseline is frozen and refuses a newer saved source',
    () async {
      final selected = appletEditReference.value!;
      item.spec['html'] = '<main>newer source</main>';
      expect(selected.item.spec['html'], '<main>Travel plan</main>');
      await harness.database.updateWidget(item.id!, spec: item.spec);
      await expectLater(prepareAppletEditContext(), throwsA(isA<StateError>()));
      expect(appletEditReference.value, same(selected));
    },
  );

  test(
    'user takeover prevents edit handoff and clearing reference closes its own session',
    () async {
      expect(await beginAppletEditing(item, canContinue: () => false), isFalse);
      await prepareAppletEditContext();
      expect(surface.activeSurfaceId, 'my-trip');
      clearAppletEditReference();
      await Future<void>.delayed(Duration.zero);
      expect(appletEditReference.value, isNull);
      expect(surface.isVisible.value, isFalse);
    },
  );
}

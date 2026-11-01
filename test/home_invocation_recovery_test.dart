import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_catalog.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_recovery_service.dart';

import 'conversation_entry_controllers_test.dart' show ConversationEntryHarness;
import 'support/app_invocation_recovery_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ConversationEntryHarness? ownedHarness;
  InvocationRecoveryFixture? ownedFixture;
  late ConversationEntryHarness harness;
  late InvocationRecoveryFixture fixture;
  setUp(() async {
    ownedHarness = null;
    ownedFixture = null;
    await appServices.reset();
    appServices.testMode = true;
    harness = await ConversationEntryHarness.create();
    ownedHarness = harness;
    // Home ownership comes from the existing entry harness. Its injected
    // recovery provider uses a real journal/media/catalog; no mock restore data.
    fixture = await InvocationRecoveryFixture.create(withImage: true);
    ownedFixture = fixture;
    appServices.put<AppInvocationRecoveryService>(fixture.recovery);
  });
  tearDown(() async {
    await ownedFixture?.close();
    await ownedHarness?.close();
  });

  Future<AppInvocationSelection> originalSelection() async =>
      (await fixture.catalog.revalidateStoredSelection(
        fixture.snapshot,
      )).selection!;

  test(
    'restoring the same selected work restores exact text and images without sending',
    () async {
      harness.home.selectedAppInvocation.value = await originalSelection();
      await harness.home.restoreInvocationDraft(fixture.reference);
      expect(harness.home.inputController.text, fixture.snapshot.text);
      expect(harness.home.pendingMedia.single.bytes, fixture.inputImage!.bytes);
      expect(
        harness.home.pendingMedia.single.attachment.thumbnailJpeg,
        isNotEmpty,
      );
      expect(
        harness.home.selectedAppInvocation.value!.identity.sourceDigest,
        fixture.descriptor.identity.sourceDigest,
      );
      expect(harness.runtime.submissions, 0);
      expect(await harness.database.getMessages('self'), isEmpty);
    },
  );

  test('an existing editing draft is never replaced', () async {
    harness.home.inputController.text = 'User draft still being edited';
    final picture = fixture.inputImage!;
    harness.home.pendingMedia.add(picture);
    await harness.home.restoreInvocationDraft(fixture.reference);
    expect(harness.home.inputController.text, 'User draft still being edited');
    expect(harness.home.pendingMedia.single, same(picture));
    expect(harness.runtime.submissions, 0);
  });

  test(
    'a new asynchronous draft including an ABA edit wins over restore',
    () async {
      final entered = Completer<void>(),
          source = Completer<List<AgentWidget>>();
      fixture.onLoadLocal = () {
        entered.complete();
        return source.future;
      };
      final restoring = harness.home.restoreInvocationDraft(fixture.reference);
      await entered.future;
      harness.home.inputController.text = 'new edit';
      harness.home.inputController.clear();
      source.complete(fixture.locals);
      await restoring;
      expect(harness.home.inputController.text, isEmpty);
      expect(harness.home.pendingMedia, isEmpty);
      expect(harness.runtime.submissions, 0);
    },
  );

  test(
    'a newly selected different source is not erased by an older restore',
    () async {
      final other = AgentWidget(
        id: 2,
        agentId: 'self',
        title: 'A different work',
        kind: 'surface',
        createdAt: DateTime.utc(2026),
        spec: {...fixture.widget.spec, 'surfaceId': 'other-work'},
      );
      fixture.locals.add(other);
      final entry = (await fixture.catalog.listPersonal()).entries.singleWhere(
        (e) => e.locator.id == 'other-work',
      );
      final otherSelection = (await fixture.catalog.resolveSelection(
        entry,
      )).selection!;
      final entered = Completer<void>(),
          source = Completer<List<AgentWidget>>();
      fixture.onLoadLocal = () {
        entered.complete();
        return source.future;
      };
      final restoring = harness.home.restoreInvocationDraft(fixture.reference);
      await entered.future;
      harness.home.selectedAppInvocation.value = otherSelection;
      source.complete(fixture.locals);
      await restoring;
      expect(harness.home.selectedAppInvocation.value, same(otherSelection));
      expect(harness.home.inputController.text, isEmpty);
      expect(harness.home.pendingMedia, isEmpty);
    },
  );

  test(
    'withdrawn source restores text and pictures while removing the old tag',
    () async {
      harness.home.selectedAppInvocation.value = await originalSelection();
      fixture.locals.clear();
      await harness.home.restoreInvocationDraft(fixture.reference);
      expect(harness.home.inputController.text, fixture.snapshot.text);
      expect(harness.home.pendingMedia.single.bytes, fixture.inputImage!.bytes);
      expect(harness.home.selectedAppInvocation.value, isNull);
      expect(harness.runtime.submissions, 0);
    },
  );

  test(
    'a foreign reference and retired provider cannot publish a draft into Home',
    () async {
      await harness.home.restoreInvocationDraft(
        fixture.altered({'scopeKey': 'another-account'}),
      );
      expect(harness.home.inputController.text, isEmpty);
      expect(harness.home.pendingMedia, isEmpty);
      final entered = Completer<void>(),
          source = Completer<List<AgentWidget>>();
      fixture.onLoadLocal = () {
        entered.complete();
        return source.future;
      };
      final restoring = harness.home.restoreInvocationDraft(fixture.reference);
      await entered.future;
      fixture.current = false;
      harness.home.inputController.text = 'New owner draft';
      source.complete(fixture.locals);
      await restoring;
      expect(harness.home.inputController.text, 'New owner draft');
      expect(harness.home.pendingMedia, isEmpty);
      expect(harness.home.selectedAppInvocation.value, isNull);
    },
  );
}

import 'dart:convert';
import 'dart:typed_data';

import 'package:image/image.dart' as image;
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_catalog.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_descriptor.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_draft_snapshot.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_execution_contract.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_recovery_service.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_result_store.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_sidecar_store.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_store.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:sembast/sembast_memory.dart';

class InvocationRecoveryFixture {
  static var _serial = 0;
  static const scope = 'https://example.test|owner';
  late DBService database;
  late ChatMediaService media;
  late AppInvocationStore journal;
  late AppInvocationResultStore results;
  late AppInvocationRecoveryService recovery;
  late AppInvocationCatalog catalog;
  late AppInvocationSidecarStore sidecars;
  late AppInvocationDescriptor descriptor;
  late AppInvocationDraftSnapshot snapshot;
  late AppInvocationRunRecord run;
  late AppInvocationChatReference reference;
  late AgentWidget widget;
  PreparedChatMedia? inputImage;
  List<AgentWidget> locals = [];
  Future<List<AgentWidget>> Function()? onLoadLocal;
  bool current = true;
  String mount = 'mount-1';
  static Future<InvocationRecoveryFixture> create({
    bool completed = true,
    bool action = true,
    bool withImage = false,
    bool persistImage = true,
  }) async {
    final f = InvocationRecoveryFixture();
    f.database = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'invocation-recovery-${_serial++}.db',
    );
    f.media = ChatMediaService(
      database: f.database.raw,
      isCurrent: () => f.current,
      baseUri: Uri.https('example.invalid'),
      accessToken: () async => 'unused',
    );
    f.sidecars = AppInvocationSidecarStore(
      database: f.database.raw,
      scopeKey: scope,
      mountId: f.mount,
      currentMountId: () => f.mount,
      isCurrent: () => f.current,
    );
    final gateway = _RecoveryGateway();
    f.catalog = AppInvocationCatalog(
      catalog: gateway,
      discovery: gateway,
      loadLocalWidgets: () async =>
          f.onLoadLocal != null ? await f.onLoadLocal!() : f.locals,
      loadOwnedInventory: () async => AppletInventoryPage(
        items: [],
        quota: const AppletQuotaSnapshot(used: 0, limit: 5),
      ),
      readAvailableOfficialApplets: () => const [],
      sidecars: f.sidecars,
      adapterIdentityFor: (_) => (id: 'test-host', version: '1'),
      scopeKey: scope,
      mountId: f.mount,
      currentScopeKey: () => scope,
      currentMountId: () => f.mount,
      isCurrent: () => f.current,
    );
    f.widget = AgentWidget(
      id: 1,
      agentId: 'self',
      title: 'Flexible work',
      kind: 'surface',
      createdAt: DateTime.utc(2026),
      spec: {
        'surfaceId': 'local-work',
        'experienceType': 'utility',
        'rendering': 'webApp',
        'html': '<main>Independent function</main>',
        'js': 'Surface.onAgent = (action, args) => args;',
        'manifest': {
          'schemaVersion': 2,
          'actions': [
            {
              'name': 'any.function',
              'schema': {
                'type': 'object',
                'properties': <String, Object?>{},
                'additionalProperties': false,
              },
              'risk': 'localMutation',
              'consequencePolicy': 'reversible',
            },
          ],
        },
      },
    );
    AppletLocalOwnership.stamp(f.widget, scopeKey: scope);
    f.locals = [f.widget];
    final resolved = await f.catalog.resolveSelection(
      (await f.catalog.listPersonal()).entries.single,
    );
    f.descriptor = resolved.descriptor!;
    final handles = <Map<String, Object?>>[];
    if (withImage) {
      final png = Uint8List.fromList(
        image.encodePng(image.Image(width: 2, height: 2, numChannels: 4)),
      );
      f.inputImage = await f.media.prepareInvocationOutput(
        AppInvocationProducedImage(
          producerOutputKey: 'original',
          mime: 'image/png',
          bytes: png,
        ),
      );
      if (persistImage) await f.media.persist(f.inputImage!);
      handles.add(
        AppInvocationInputImage(
          id: f.inputImage!.attachment.id,
          mime: 'image/png',
          bytes: png,
        ).toHandleJson(),
      );
    }
    final source = resolved.executableSource!;
    f.snapshot = AppInvocationDraftSnapshot(
      scopeKey: scope,
      text: 'Please use this function',
      imageHandles: handles,
      sourceOrigin: source.locator.origin.name,
      sourceId: source.identity.sourceId,
      localWidgetId: source.locator.localWidgetId,
      sourceType: source.type.name,
      sourceTitle: source.title,
      revisionId: source.identity.revisionId,
      sourceDigest: source.identity.sourceDigest,
      contractDigest: source.contractDigest,
      adapterId: 'test-host',
      adapterVersion: '1',
    );
    f.bindProcess('process-1');
    f.run = await f.journal.admit(
      submissionToken: 'submission-1',
      turnId: 'original-turn',
      sessionId: 'self',
      descriptor: f.descriptor,
      adapterId: 'test-host',
      adapterVersion: '1',
      inputDigest: f.snapshot.inputDigest,
      draftSnapshot: f.snapshot,
      canContinue: () => f.current,
    );
    if (action) {
      await f.journal.reserveAction(
        invocationId: f.run.invocationId,
        requestId: 'request-1',
        actionId: 'any.function',
        arguments: {},
        observationId: 'observation-1',
        expectedStateVersion: 0,
        canContinue: () => f.current,
      );
      if (completed) {
        await f.journal.settle(
          AppInvocationActionReceipt(
            invocationId: f.run.invocationId,
            requestId: 'request-1',
            actionId: 'any.function',
            identity: f.descriptor.identity,
            contractDigest: f.descriptor.contractDigest,
            status: AppInvocationActionStatus.completed,
            stateVersion: 1,
            result: {'value': 42},
          ),
          canContinue: () => f.current,
        );
      }
    }
    f.reference = (await f.recovery.referenceForInvocation(
      invocationId: f.run.invocationId,
      sessionId: 'self',
      requestId: action ? 'request-1' : null,
    ))!;
    return f;
  }

  void bindProcess(String process) {
    journal = AppInvocationStore(
      database: database.raw,
      scopeKey: scope,
      mountId: mount,
      processId: process,
      isCurrent: () => current,
    );
    results = AppInvocationResultStore(
      database: database,
      invocationStore: journal,
      media: media,
      scopeKey: scope,
      mountId: mount,
      currentMountId: () => mount,
      isCurrent: () => current,
    );
    recovery = AppInvocationRecoveryService(
      database: database,
      store: journal,
      results: results,
      media: media,
      catalog: catalog,
      scopeKey: scope,
      mountId: mount,
      currentMountId: () => mount,
      isCurrent: () => current,
    );
  }

  Future<void> restartProcess() async {
    await recovery.deactivateAndDrain();
    await results.deactivateAndDrain();
    await journal.deactivateAndDrain();
    bindProcess('process-2');
  }

  AppInvocationChatReference altered(Map<String, Object?> fields) =>
      AppInvocationChatReference.tryParse({...reference.toJson(), ...fields})!;
  String get originalSource => jsonEncode(widget.toJson());
  Future<void> close() async {
    await recovery.deactivateAndDrain();
    await results.deactivateAndDrain();
    await journal.deactivateAndDrain();
    await catalog.deactivateAndDrain();
    sidecars.retire();
    await media.shutdown();
    await database.close();
  }
}

class _RecoveryGateway implements AppletCatalogGateway, AppletDiscoveryGateway {
  @override
  String get requestContextKey => 'test|owner|en';
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

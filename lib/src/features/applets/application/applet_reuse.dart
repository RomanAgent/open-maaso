import 'dart:async';
import 'package:http/http.dart' as http;
import 'package:sembast/sembast.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_catalog_service.dart';
import 'package:maaso/src/features/applets/domain/applet_catalog_models.dart';

final _sources = StoreRef<String, Map<String, Object?>>('applet_reuse_sources');
String _sourceKey(AppletChatReference reference) =>
    '${reference.scopeKey}|${reference.id}|${reference.sourceSha256}';

Future<AppletSourceDocument> loadReusedAppletSource(
  AppletChatReference reference, {
  required Future<AppletSourceDocument> Function() fetch,
}) async {
  void checkScope() {
    if (reference.scopeKey != AppletLocalOwnership.currentScopeKey()) {
      throw StateError('applet_request_context_changed');
    }
  }

  checkScope();
  final database = appServices.find<DBService>().raw;
  final record = _sources.record(_sourceKey(reference));
  AppletSourceDocument source;
  try {
    source = await fetch();
  } on AppletCatalogRequestException catch (error) {
    // A known withdrawal or access denial must never reopen the cached copy.
    if (error.statusCode >= 400 && error.statusCode < 500) {
      await record.delete(database);
    }
    rethrow;
  } catch (error) {
    if (error is! TimeoutException && error is! http.ClientException) rethrow;
    checkScope();
    final cached = await record.get(database);
    if (cached == null) rethrow;
    source = AppletSourceDocument.fromJson(cached);
  }
  checkScope();
  if (source.id != reference.id ||
      source.sourceSha256 != reference.sourceSha256 ||
      source.revisionNo != reference.revision) {
    throw StateError('applet_revision_changed');
  }
  validateAppletReuse(source, reference.actions);
  return source;
}

/// Validates the immutable published contract before any chat card is emitted.
void validateAppletReuse(
  AppletSourceDocument source,
  List<Map<String, Object?>> actions,
) {
  if (source.experienceType != 'utility' || actions.length > 8) {
    throw const FormatException('invalid_applet_reuse');
  }
  final project = SurfaceProject.fromJson(source.toProjectJson());
  SurfaceProjectValidator.validateForPublicApplet(project);
  for (final action in actions) {
    final name = action['name'];
    final arguments = action['arguments'];
    if (name is! String ||
        arguments is! Map ||
        project.manifest.validateAction(name, arguments) != null) {
      throw const FormatException('invalid_applet_configuration');
    }
  }
}

Future<void> queueAppletChatReference(
  AppletCatalogItem item,
  AppletSourceDocument source,
  List<Map<String, Object?>> actions,
) async {
  validateAppletReuse(source, actions);
  final scope = AppletLocalOwnership.currentScopeKey();
  final reference = AppletChatReference.tryParse(
    AppletChatReference(
      id: item.id,
      title: item.title,
      scopeKey: scope,
      revision: source.revisionNo,
      sourceSha256: source.sourceSha256,
      actions: actions,
    ).toJson(),
  );
  if (reference == null) {
    throw const FormatException('invalid_applet_configuration');
  }
  final database = appServices.find<DBService>();
  await _sources.record(_sourceKey(reference)).put(database.raw, {
    'id': source.id,
    'clientSurfaceId': source.clientSurfaceId,
    'revisionNo': source.revisionNo,
    'sourceSha256': source.sourceSha256,
    'experienceType': source.experienceType,
    'category': source.category,
    'skillInstructions': source.skillInstructions,
    'surface': source.surface,
  });
  if (scope != AppletLocalOwnership.currentScopeKey()) {
    throw StateError('applet_request_context_changed');
  }
  await database.saveChatMessage(
    ChatMessage(
      sessionId: 'self',
      senderId: 'self',
      receiverId: 'user',
      content: 'widgets.prepared_applet'.tr,
      appletReference: reference,
      timestamp: DateTime.now().toUtc(),
      turnOrigin: ChatMessageTurnOrigins.user,
      deliveryStatus: 'published',
    ),
  );
}

import 'dart:convert';

import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';

import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_draft.dart';

import 'package:maaso/src/features/agent/data/agent_core.dart';
import 'package:maaso/src/features/agent/data/skills/agent_skill_structured_action_schema.dart';
import 'package:maaso/src/features/agent/data/utils/logger.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/prompts/agent_prompt_catalog.dart';

import 'package:maaso/src/features/agent/application/surface/surface_manifest.dart';
import 'package:maaso/src/features/agent/application/surface/surface_authoring_theme.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project.dart';
import 'package:maaso/src/features/agent/application/surface/surface_agent_document.dart';
import 'package:maaso/src/features/agent/application/surface/surface_project_validator.dart';
import 'package:maaso/src/features/agent/application/surface/surface_execution_grant.dart';
import 'package:maaso/src/features/agent/application/surface/surface_interaction_grant.dart';
import 'package:maaso/src/features/agent/application/surface/surface_runtime.dart';
import 'package:maaso/src/features/agent/application/surface/surface_worker_health_gate.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/applets/data/applet_presentation_state.dart';
import 'package:maaso/src/features/agent_games/data/agent_game_cloud_service.dart';

class FreeformSurfaceSkill extends AgentSkill
    implements StructuredActionPromptSchemaProvider {
  FreeformSurfaceSkill({this.agentId, SurfaceRuntime? runtime})
    : _runtime = runtime;

  final String? agentId;
  final SurfaceRuntime? _runtime;
  final Map<String, SurfaceProject> _surfaces = {};
  final Set<String> _persistedSurfaceKeys = <String>{};

  DBService? get _db => appServices.isRegistered<DBService>()
      ? appServices.find<DBService>()
      : null;

  SurfaceRuntime get _surfaceRuntime {
    final runtime = _runtime;
    if (runtime != null) return runtime;
    if (appServices.isRegistered<SurfaceRuntime>()) {
      return appServices.find<SurfaceRuntime>();
    }
    return appServices.put(SurfaceRuntime());
  }

  @override
  String get skillName => 'FreeformSurface';

  @override
  String get namespace => 'skill';

  @override
  String get description =>
      AgentPromptCatalog.text('skill.FreeformSurface.description');
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'showSurface': _showSurface,
    'editSurface': _editSurface,
    'listSurfaces': _listSurfaces,
    'reopenSurface': _reopenSurface,
    'revertSurface': _revertSurface,
  };

  @override
  StructuredActionPromptSchemas get structuredActionPromptSchemas =>
      StructuredActionPromptSchemas(<String, Map<String, dynamic>>{
        'editSurface': {
          'type': 'object',
          'properties': {
            'surfaceId': {
              'type': 'string',
              'description':
                  'The exact id of the currently visible Surface from context.',
            },
            'title': {'type': 'string', 'maxLength': 240},
            'category': {
              'type': 'string',
              'enum': ['travel', 'tools', 'game'],
            },
            'skillInstructions': {
              'type': 'string',
              'maxLength': surfaceAgentDocumentMaxUtf8Bytes,
            },
            'html': {'type': 'string'},
            'css': {'type': 'string'},
            'js': {'type': 'string'},
            'manifest': {'type': 'object'},
            'backend': {'type': 'object'},
            'placement': {'type': 'object'},
            'transparent': {'type': 'boolean'},
            'rendering': {
              'type': 'string',
              'enum': SurfaceRendering.values
                  .map((value) => value.name)
                  .toList(),
            },
            'experienceType': {
              'type': 'string',
              'enum': SurfaceExperienceType.values
                  .map((value) => value.name)
                  .toList(),
            },
            'surface': {
              'type': 'string',
              'enum': SurfaceKind.values.map((value) => value.name).toList(),
            },
          },
          'required': ['surfaceId'],
          'additionalProperties': false,
        },
        'revertSurface': {
          'type': 'object',
          'properties': {
            'surfaceId': {
              'type': 'string',
              'description':
                  'The exact id of the currently visible Surface from context.',
            },
            'revisionId': {
              'type': 'string',
              'description':
                  'Optional revision id. Omit it to restore the latest prior '
                  'revision.',
            },
          },
          'required': ['surfaceId'],
          'additionalProperties': false,
        },
      });

  @override
  Map<String, String> get nativeMethodDescriptions => const {
    'editSurface':
        'Prepare a validated draft for the currently visible generated Surface. '
        'Preserve fields the user did not ask to change. The saved version stays '
        'unchanged until the user previews and applies the draft in version history.',
    'revertSurface':
        'Restore the currently visible generated Surface to a prior revision. '
        'Omit revisionId to undo the latest edit.',
  };

  Future<String> _showSurface(List<dynamic> args) async {
    int? shownSession;
    String? expectedScopeKey;
    AgentWidget? pendingWidget;
    var presentationCommitted = false;
    try {
      expectedScopeKey = AppletLocalOwnership.currentScopeKey();
      _requireExpectedScope(expectedScopeKey);
      final payload = _decodeMap(args);
      final catalogSummary = normalizeAppletCatalogSummary(payload['summary']);
      final project = _projectFrom(
        payload,
        generateId: true,
        applyAuthoringTheme: true,
      );
      if (project.experienceType == SurfaceExperienceType.game) {
        SurfaceProjectValidator.validateForPublicGame(project);
      } else {
        SurfaceProjectValidator.validateForShow(project);
      }
      final db = _db;
      if (db != null) {
        await AppletLocalOwnership.ensureCanCreate(
          db,
          proposedSurfaceId: project.id,
        );
        _requireExpectedScope(expectedScopeKey);
      }
      int? widgetId;
      if (db != null) {
        pendingWidget = AgentWidget(
          agentId: agentId ?? 'self',
          title: _surfaceTitle(project),
          subtitle: catalogSummary,
          kind: 'surface',
          spec: _specFromProject(project),
          createdAt: DateTime.now(),
        );
        AppletLocalOwnership.stamp(pendingWidget, scopeKey: expectedScopeKey);
        stampAgentGameCloudOwnership(
          pendingWidget,
          expectedScopeKey: expectedScopeKey,
        );
        markAppletPresentationPending(pendingWidget);
        widgetId = await AppletLocalOwnership.saveNew(
          db,
          pendingWidget,
          expectedScopeKey: expectedScopeKey,
        );
        _requireExpectedScope(expectedScopeKey);
        await syncNewAppletBeforePresent(pendingWidget);
        _requireExpectedScope(expectedScopeKey);
      }
      _requireExpectedScope(expectedScopeKey);
      shownSession = await _showForExpectedScope(project, expectedScopeKey);
      if (db != null && pendingWidget != null && widgetId != null) {
        final committedSpec = committedAppletPresentationSpec(pendingWidget);
        final merged = await db.updateGeneratedSurface(
          widgetId,
          spec: committedSpec,
          expectedScopeKey: expectedScopeKey,
          validateScope: (current, scopeKey) {
            _requireExpectedScope(scopeKey);
            return current.agentId == (agentId ?? 'self') &&
                AppletLocalOwnership.storedScopeKey(current) == scopeKey &&
                current.spec['surfaceId'] == project.id &&
                _surfaceRuntime.activeSession == shownSession &&
                _surfaceRuntime.activeSurfaceId == project.id;
          },
        );
        pendingWidget.spec = merged;
      }
      presentationCommitted = true;
      _remember(
        project,
        expectedScopeKey: expectedScopeKey,
        persisted: widgetId != null,
      );
      _requireExpectedScope(expectedScopeKey);
      return _surfaceResult(project, widgetId: widgetId);
    } catch (e, stackTrace) {
      Object reportedError = e;
      try {
        await _closeShownSession(shownSession);
      } catch (closeError, closeStackTrace) {
        Log.w(
          '[FreeformSurface] failed to close an unpresented Surface: '
          '$closeError\n$closeStackTrace',
        );
      }
      if (!presentationCommitted &&
          pendingWidget?.id != null &&
          expectedScopeKey != null) {
        try {
          await _discardUnpresentedWidget(
            pendingWidget!,
            expectedScopeKey: expectedScopeKey,
          );
        } catch (cleanupError, cleanupStackTrace) {
          Log.w(
            '[FreeformSurface] failed to compensate an unpresented Surface: '
            '$cleanupError\n$cleanupStackTrace',
          );
          reportedError = StateError('surface_cleanup_failed: $e');
        }
      }
      if (!identical(reportedError, e)) {
        Log.w('[FreeformSurface] original failure:\n$stackTrace');
      }
      return _error(reportedError);
    }
  }

  Future<String> _editSurface(List<dynamic> args) async {
    int? shownSession;
    try {
      final expectedScopeKey = AppletLocalOwnership.currentScopeKey();
      _requireExpectedScope(expectedScopeKey);
      final patch = _decodeMap(args);
      final id = _idFrom(patch);
      if (id.isEmpty) return _error('missing id');

      final match = await _findSavedSurface(
        patch,
        expectedScopeKey: expectedScopeKey,
      );
      SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
      _requireExpectedScope(expectedScopeKey);
      if (match != null) {
        final found = match.widget;
        requireAppletEditBaseline(found, expectedScopeKey);
        final spec = Map<String, Object?>.from(found.spec);
        final baseline = surfaceVersionFingerprint(
          found.spec,
          title: found.title,
        );
        final history = SurfaceVersionHistory.read(spec, title: found.title);
        _applySpecPatch(spec, patch);
        final title = patch['title']?.toString() ?? found.title;
        // A preview has no issued successful version. Model-provided history
        // cannot become the current source or bypass the visible Apply action.
        spec.remove('versionHistory');
        spec.remove('pendingVersionDraft');
        spec['revisions'] = const <Object?>[];
        final candidate = _copyWidget(found, title: title, spec: spec);
        final candidateProject = _projectFromWidget(candidate);
        if (candidateProject.experienceType == SurfaceExperienceType.game) {
          SurfaceProjectValidator.validateForPublicGame(candidateProject);
        } else {
          SurfaceProjectValidator.validateForShow(candidateProject);
        }
        await _validateDraftForExpectedScope(
          candidateProject,
          expectedScopeKey,
        );
        SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
        _requireExpectedScope(expectedScopeKey);
        final draft = SurfaceVersionDraft.create(
          source: candidateProject.toJson(),
          title: title,
          baseFingerprint: baseline,
        );
        await _db!.updateGeneratedSurface(
          found.id!,
          title: found.title,
          spec: {...found.spec, 'pendingVersionDraft': draft.toJson()},
          expectedSourceFingerprint: baseline,
          expectedScopeKey: expectedScopeKey,
          validateScope: _validateWidgetScope,
        );
        SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
        _requireExpectedScope(expectedScopeKey);
        return jsonEncode({
          'status': 'draft_ready',
          'applied': false,
          'surfaceId': candidateProject.id,
          'widgetId': found.id,
          'draftId': draft.id,
          'baseVersionId': history.current.id,
          'baseVersionNumber': history.current.number,
          'nextAction': 'user_preview_and_apply_in_version_history',
        });
      }

      final existing = _remembered(id, expectedScopeKey: expectedScopeKey);
      if (existing == null) return _error('surface not found');

      final merged = existing.toJson();
      final revisions =
          existing.revisions.map((revision) => revision.toJson()).toList()
            ..add(_revisionFromProject(existing));
      _applySpecPatch(merged, patch);
      if (patch['title'] != null) merged['title'] = patch['title'].toString();
      merged['revisions'] = revisions;
      merged['id'] = id;
      merged['versionHistory'] = SurfaceVersionHistory.read(
        existing.toJson(),
        title: existing.title,
      ).append(merged, title: (merged['title'] ?? '').toString()).toJson();

      final project = _projectFrom(merged);
      if (project.experienceType == SurfaceExperienceType.game) {
        SurfaceProjectValidator.validateForPublicGame(project);
      } else {
        SurfaceProjectValidator.validateForShow(project);
      }
      _requireExpectedScope(expectedScopeKey);
      shownSession = await _showForExpectedScope(project, expectedScopeKey);
      SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
      _remember(project, expectedScopeKey: expectedScopeKey);
      _requireExpectedScope(expectedScopeKey);
      return _surfaceResult(project);
    } catch (e) {
      await _closeShownSession(shownSession);
      if (e is SurfaceNotGrantedException) rethrow;
      return _error(e);
    }
  }

  Future<void> _validateDraftForExpectedScope(
    SurfaceProject project,
    String expectedScopeKey,
  ) async {
    _requireExpectedScope(expectedScopeKey);
    SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
    if (!surfaceRequiresFirstFrameValidation(project)) return;
    final waiter = appServices.maybeFind<SurfaceWorkerFirstFrameWaiter>();
    if (waiter == null) {
      throw const SurfaceWorkerFirstFrameException.unavailable();
    }
    final preview = SurfaceRuntime();
    var claimed = false;
    try {
      waiter.beginPresentation(runtime: preview);
      claimed = true;
      final session = await preview.showWithSession(project);
      final document = preview.document.value;
      if (document == null) {
        throw const SurfaceWorkerFirstFrameException.unavailable();
      }
      await waiter.waitForFirstFrame(
        session: session,
        document: document,
        timeout: project.rendering == SurfaceRendering.webApp
            ? const Duration(seconds: 15)
            : const Duration(seconds: 6),
      );
      if (!preview.isSessionCurrent(session)) {
        throw const SurfaceWorkerFirstFrameException.superseded();
      }
      SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
      _requireExpectedScope(expectedScopeKey);
    } catch (_) {
      if (claimed) waiter.cancelPresentation();
      rethrow;
    } finally {
      await preview.close();
      preview.onClose();
    }
  }

  Future<String> _listSurfaces(List<dynamic> _) async {
    try {
      final expectedScopeKey = AppletLocalOwnership.currentScopeKey();
      _requireExpectedScope(expectedScopeKey);
      final surfaces = <Map<String, Object?>>[];
      final listedSurfaceIds = <String>{};
      final unavailableSurfaceIds = <String>{};
      final db = _db;
      if (db != null) {
        final widgets = await db.getAllWidgets();
        _requireExpectedScope(expectedScopeKey);
        for (final widget in widgets) {
          if (!AppletLocalOwnership.isVisible(
            widget,
            scopeKey: expectedScopeKey,
          )) {
            continue;
          }
          if (!isAppletPresentationDiscoverable(
            widget,
            scopeKey: expectedScopeKey,
          )) {
            final surfaceId = widget.spec['surfaceId']?.toString().trim() ?? '';
            if (surfaceId.isNotEmpty) unavailableSurfaceIds.add(surfaceId);
            continue;
          }
          _requireExpectedScope(expectedScopeKey);
          final project = _projectFromWidget(widget);
          surfaces.add(_surfaceListItem(project, widgetId: widget.id));
          listedSurfaceIds.add(project.id);
        }
      }
      for (final project in _rememberedForScope(expectedScopeKey)) {
        if (!unavailableSurfaceIds.contains(project.id) &&
            listedSurfaceIds.add(project.id)) {
          surfaces.add(_surfaceListItem(project));
        }
      }
      _requireExpectedScope(expectedScopeKey);
      return jsonEncode({'surfaces': surfaces});
    } catch (e) {
      return _error(e);
    }
  }

  Future<String> _reopenSurface(List<dynamic> args) async {
    int? shownSession;
    try {
      final expectedScopeKey = AppletLocalOwnership.currentScopeKey();
      _requireExpectedScope(expectedScopeKey);
      final payload = _decodeMap(args);
      final match = await _findSavedSurface(
        payload,
        expectedScopeKey: expectedScopeKey,
      );
      SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
      _requireExpectedScope(expectedScopeKey);
      if (match != null) {
        final widget = match.widget;
        final project = _projectFromWidget(widget);
        SurfaceProjectValidator.validateForShow(project);
        _requireExpectedScope(expectedScopeKey);
        shownSession = await _showForExpectedScope(project, expectedScopeKey);
        if (match.openedByWidgetId && widget.id != null) {
          await _db?.resurfaceWidget(
            widget.id!,
            expectedScopeKey: expectedScopeKey,
            validateScope: _validateWidgetScope,
          );
          _requireExpectedScope(expectedScopeKey);
        }
        _remember(project, expectedScopeKey: expectedScopeKey, persisted: true);
        _requireExpectedScope(expectedScopeKey);
        return _surfaceResult(project, widgetId: widget.id);
      }

      final id = _projectLookupIdFrom(payload);
      var project = id.isEmpty
          ? null
          : _remembered(id, expectedScopeKey: expectedScopeKey);
      if (project == null && _hasProjectBody(payload)) {
        project = _projectFrom(payload, generateId: id.isEmpty);
      }
      if (project == null) return _error('surface not found');

      SurfaceProjectValidator.validateForShow(project);
      _requireExpectedScope(expectedScopeKey);
      shownSession = await _showForExpectedScope(project, expectedScopeKey);
      _remember(project, expectedScopeKey: expectedScopeKey);
      _requireExpectedScope(expectedScopeKey);
      return _surfaceResult(project);
    } catch (e) {
      await _closeShownSession(shownSession);
      return _error(e);
    }
  }

  Future<String> _revertSurface(List<dynamic> args) async {
    int? shownSession;
    try {
      final expectedScopeKey = AppletLocalOwnership.currentScopeKey();
      _requireExpectedScope(expectedScopeKey);
      final payload = _decodeMap(args);
      final id = _idFrom(payload);
      if (id.isEmpty) return _error('missing id');

      final requestedRevisionId = (payload['revisionId'] ?? '')
          .toString()
          .trim();

      final match = await _findSavedSurface(
        payload,
        expectedScopeKey: expectedScopeKey,
      );
      SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
      _requireExpectedScope(expectedScopeKey);
      if (match != null) {
        final found = match.widget;
        requireAppletEditBaseline(found, expectedScopeKey);
        final spec = Map<String, Object?>.from(found.spec);
        final baseline = surfaceVersionFingerprint(
          found.spec,
          title: found.title,
        );
        final history = SurfaceVersionHistory.read(spec, title: found.title);
        final revision = _versionToRestore(history, requestedRevisionId);
        if (revision == null) return _error('revision not found');
        final revisionId = revision.id;
        final revisions = _revisionMaps(spec['revisions'])
          ..add(_revisionFromSpec(spec, title: found.title));
        _restoreRevision(spec, revision.source);
        spec['revisions'] = revisions;
        final restoredTitle =
            revision.source['title']?.toString() ?? found.title;
        spec['versionHistory'] = history
            .append(spec, title: restoredTitle, restoredFromId: revisionId)
            .toJson();
        final candidate = _copyWidget(found, title: restoredTitle, spec: spec);
        final candidateProject = _projectFromWidget(candidate);
        SurfaceProjectValidator.validateForShow(candidateProject);
        _requireExpectedScope(expectedScopeKey);
        shownSession = await _showForExpectedScope(
          candidateProject,
          expectedScopeKey,
        );
        final storedSpec = await _db!.updateGeneratedSurface(
          found.id!,
          title: restoredTitle,
          spec: spec,
          expectedSourceFingerprint: baseline,
          expectedScopeKey: expectedScopeKey,
          validateScope: _validateWidgetScope,
        );
        SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
        _requireExpectedScope(expectedScopeKey);

        final updated = _copyWidget(
          found,
          title: restoredTitle,
          spec: storedSpec,
        );
        final project = _projectFromWidget(updated);
        acceptAppletEditRevision(updated, baseline);
        scheduleAgentGameCloudSync(updated);
        _remember(project, expectedScopeKey: expectedScopeKey, persisted: true);
        _requireExpectedScope(expectedScopeKey);
        return jsonEncode({
          'surfaceId': project.id,
          'widgetId': found.id,
          'revisionId': revisionId,
        });
      }

      final project = _remembered(id, expectedScopeKey: expectedScopeKey);
      if (project == null) return _error('surface not found');

      final history = SurfaceVersionHistory.read(
        project.toJson(),
        title: project.title,
      );
      final revision = _versionToRestore(history, requestedRevisionId);
      if (revision == null) return _error('revision not found');
      final json = project.toJson();
      _restoreRevision(json, revision.source);
      json['revisions'] = [
        ...project.revisions.map((candidate) => candidate.toJson()),
        _revisionFromProject(project),
      ];
      json['versionHistory'] = history
          .append(
            json,
            title: (json['title'] ?? '').toString(),
            restoredFromId: revision.id,
          )
          .toJson();
      final reverted = _projectFrom(json);
      SurfaceProjectValidator.validateForShow(reverted);
      _requireExpectedScope(expectedScopeKey);
      shownSession = await _showForExpectedScope(reverted, expectedScopeKey);
      SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
      _remember(reverted, expectedScopeKey: expectedScopeKey);
      _requireExpectedScope(expectedScopeKey);
      return jsonEncode({
        'surfaceId': reverted.id,
        'widgetId': reverted.id,
        'revisionId': revision.id,
      });
    } catch (e) {
      await _closeShownSession(shownSession);
      if (e is SurfaceNotGrantedException) rethrow;
      return _error(e);
    }
  }

  Map<String, Object?> _decodeMap(List<dynamic> args) {
    if (args.isEmpty) throw const FormatException('missing json');
    final raw = args.first;
    final decoded = raw is String ? jsonDecode(raw) : raw;
    if (decoded is! Map) {
      throw const FormatException('expected json object');
    }
    return decoded.map((key, value) => MapEntry(key.toString(), value));
  }

  SurfaceProject _projectFrom(
    Map<String, Object?> source, {
    bool generateId = false,
    bool applyAuthoringTheme = false,
  }) {
    final json = Map<String, Object?>.from(source);
    if (!json.containsKey('id') && json.containsKey('surfaceId')) {
      json['id'] = json['surfaceId'];
    }
    if (!json.containsKey('kind') && json.containsKey('surfaceKind')) {
      json['kind'] = json['surfaceKind'];
    }
    if (!json.containsKey('kind') && json.containsKey('surface')) {
      json['kind'] = json['surface'];
    }
    if (generateId) {
      json['id'] = _newId();
      // Only the host may issue version identities or historical records.
      json.remove('versionHistory');
      json['revisions'] = <Object?>[];
    }
    if (applyAuthoringTheme) {
      SurfaceAuthoringTheme.applyToNewSource(json);
    }
    if (generateId) {
      final normalized = SurfaceProject.fromJson(json);
      json['versionHistory'] = SurfaceVersionHistory.create(
        normalized.toJson(),
        title: normalized.title,
      ).toJson();
    }
    final project = SurfaceProject.fromJson(json);
    if (project.id.trim().isEmpty) {
      throw const FormatException('missing id');
    }
    return project;
  }

  String _idFrom(Map<String, Object?> json) =>
      (json['id'] ?? json['surfaceId'] ?? '').toString().trim();

  String _projectLookupIdFrom(Map<String, Object?> json) {
    final surfaceId = _surfaceIdFrom(json);
    if (surfaceId.isNotEmpty) return surfaceId;
    return _idFrom(json);
  }

  int? _widgetIdFrom(Map<String, Object?> json) {
    final raw = json['id'];
    if (raw == null) return null;
    if (raw is int) return raw;
    return int.tryParse(raw.toString());
  }

  String _surfaceIdFrom(Map<String, Object?> json) {
    final explicit = json['surfaceId']?.toString().trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final rawId = json['id'];
    if (rawId == null || int.tryParse(rawId.toString()) != null) return '';
    return rawId.toString().trim();
  }

  Future<_SurfaceMatch?> _findSavedSurface(
    Map<String, Object?> payload, {
    required String expectedScopeKey,
  }) async {
    _requireExpectedScope(expectedScopeKey);
    final db = _db;
    if (db == null) return null;
    final widgetId = _widgetIdFrom(payload);
    final surfaceId = _surfaceIdFrom(payload);
    if (widgetId == null && surfaceId.isEmpty) return null;

    final widgets = await db.getAllWidgets();
    _requireExpectedScope(expectedScopeKey);
    for (final widget in widgets) {
      if (!AppletLocalOwnership.isVisible(widget, scopeKey: expectedScopeKey)) {
        continue;
      }
      _requireExpectedScope(expectedScopeKey);
      final openedByWidgetId = widgetId != null && widget.id == widgetId;
      final openedBySurfaceId =
          surfaceId.isNotEmpty && widget.spec['surfaceId'] == surfaceId;
      if (!openedByWidgetId && !openedBySurfaceId) continue;
      if (!isAppletPresentationDiscoverable(
        widget,
        scopeKey: expectedScopeKey,
      )) {
        throw const FormatException('surface not found');
      }
      return _SurfaceMatch(widget, openedByWidgetId: openedByWidgetId);
    }
    return null;
  }

  bool _hasProjectBody(Map<String, Object?> json) {
    const keys = {'html', 'css', 'js', 'title', 'manifest', 'backend'};
    return keys.any(json.containsKey);
  }

  String _surfaceResult(SurfaceProject project, {Object? widgetId}) {
    return jsonEncode({
      'surfaceId': project.id,
      'widgetId': widgetId ?? project.id,
      if (project.versionHistory case final history?) ...{
        'versionId': history.current.id,
        'versionNumber': history.current.number,
      },
    });
  }

  String _error(Object error) {
    final raw = error is FormatException ? error.message : error.toString();
    final code = switch (raw) {
      'missing json' => 'missing_args',
      'expected json object' => 'expected_object',
      'missing id' => 'missing_id',
      'surface not found' => 'surface_not_found',
      'missing revisionId' => 'missing_revision_id',
      'revision not found' => 'revision_not_found',
      'surface_version_conflict' ||
      'Bad state: surface_version_conflict' => 'surface_version_conflict',
      'surface_version_history_invalid' => 'surface_version_history_invalid',
      'applet_quota_reached' => 'applet_quota_reached',
      'applet_quota_unavailable' => 'applet_quota_unavailable',
      _ => 'execution_failed',
    };
    if (code == 'execution_failed') {
      Log.w('[FreeformSurface] failed: $error');
    }
    return jsonEncode({'error': code});
  }

  String _newId() => 'surface_${DateTime.now().microsecondsSinceEpoch}';

  String _memoryKey(String expectedScopeKey, String surfaceId) =>
      '$expectedScopeKey::$surfaceId';

  void _remember(
    SurfaceProject project, {
    required String expectedScopeKey,
    bool persisted = false,
  }) {
    _requireExpectedScope(expectedScopeKey);
    final key = _memoryKey(expectedScopeKey, project.id);
    _surfaces[key] = project;
    if (persisted) _persistedSurfaceKeys.add(key);
    _requireExpectedScope(expectedScopeKey);
  }

  SurfaceProject? _remembered(
    String surfaceId, {
    required String expectedScopeKey,
  }) {
    _requireExpectedScope(expectedScopeKey);
    final key = _memoryKey(expectedScopeKey, surfaceId);
    final project = _db != null && _persistedSurfaceKeys.contains(key)
        ? null
        : _surfaces[key];
    _requireExpectedScope(expectedScopeKey);
    return project;
  }

  List<SurfaceProject> _rememberedForScope(String expectedScopeKey) {
    _requireExpectedScope(expectedScopeKey);
    final prefix = '$expectedScopeKey::';
    final projects = _surfaces.entries
        .where(
          (entry) =>
              entry.key.startsWith(prefix) &&
              (_db == null || !_persistedSurfaceKeys.contains(entry.key)),
        )
        .map((entry) => entry.value)
        .toList(growable: false);
    _requireExpectedScope(expectedScopeKey);
    return projects;
  }

  void _requireExpectedScope(String expectedScopeKey) {
    if (AppletLocalOwnership.currentScopeKey() != expectedScopeKey) {
      throw const AppletQuotaUnavailableException();
    }
  }

  bool _validateWidgetScope(AgentWidget current, String expectedScopeKey) {
    SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
    _requireExpectedScope(expectedScopeKey);
    return isAppletPresentationDiscoverable(
      current,
      scopeKey: expectedScopeKey,
    );
  }

  Future<int> _showForExpectedScope(
    SurfaceProject project,
    String expectedScopeKey,
  ) async {
    _requireExpectedScope(expectedScopeKey);
    final runtime = _surfaceRuntime;
    final firstFrameWaiter = surfaceRequiresFirstFrameValidation(project)
        ? appServices.maybeFind<SurfaceWorkerFirstFrameWaiter>()
        : null;
    SurfaceInteractionExecutionCheckpoint.requireCurrentIfPresent();
    final previousSession = runtime.activeSession;
    var firstFrameClaimed = false;
    var shownSession = -1;
    try {
      firstFrameWaiter?.beginPresentation(runtime: runtime);
      firstFrameClaimed = firstFrameWaiter != null;
      shownSession = await runtime.showWithSession(project);
      SurfaceInteractionExecutionCheckpoint.acceptHostTransitionIfPresent(
        runtime: runtime,
        previousSession: previousSession,
        surfaceId: project.id,
      );
      if (firstFrameWaiter != null) {
        final document = runtime.document.value;
        if (document == null) {
          throw const SurfaceWorkerFirstFrameException.unavailable();
        }
        await firstFrameWaiter.waitForFirstFrame(
          session: shownSession,
          document: document,
          timeout: project.rendering == SurfaceRendering.webApp
              ? const Duration(seconds: 15)
              : const Duration(seconds: 6),
        );
        if (runtime.activeSession != shownSession ||
            runtime.activeSurfaceId != project.id) {
          throw const SurfaceWorkerFirstFrameException.superseded();
        }
      }
    } catch (_) {
      if (firstFrameClaimed) firstFrameWaiter?.cancelPresentation();
      if (shownSession >= 0) await runtime.closeIfSession(shownSession);
      rethrow;
    }
    if (AppletLocalOwnership.currentScopeKey() != expectedScopeKey) {
      if (identical(runtime.activeProject.value, project)) {
        await runtime.closeIfSession(shownSession);
      }
      throw const AppletQuotaUnavailableException();
    }
    _requireExpectedScope(expectedScopeKey);
    return shownSession;
  }

  Future<void> _closeShownSession(int? shownSession) async {
    if (shownSession == null) return;
    await _surfaceRuntime.closeIfSession(shownSession);
  }

  Future<void> _discardUnpresentedWidget(
    AgentWidget widget, {
    required String expectedScopeKey,
  }) async {
    if (isCloudAppletWidget(widget) &&
        appServices.isRegistered<AgentGameCloudService>()) {
      await appServices.find<AgentGameCloudService>().compensateUnpresented(
        widget,
        expectedScopeKey: expectedScopeKey,
      );
      return;
    }
    final db = _db;
    final widgetId = widget.id;
    if (db == null || widgetId == null) return;
    await db.deleteWidgetValidated(
      widgetId,
      validate: (current) =>
          current.agentId == widget.agentId &&
          AppletLocalOwnership.storedScopeKey(current) == expectedScopeKey &&
          current.spec['surfaceId'] == widget.spec['surfaceId'] &&
          isAppletPresentationPending(current),
    );
  }

  String _surfaceTitle(SurfaceProject project) =>
      project.title.trim().isEmpty ? 'Surface' : project.title;

  AgentWidget _copyWidget(
    AgentWidget widget, {
    String? title,
    Map<String, Object?>? spec,
  }) {
    return AgentWidget(
      id: widget.id,
      agentId: widget.agentId,
      title: title ?? widget.title,
      subtitle: widget.subtitle,
      icon: widget.icon,
      kind: widget.kind,
      spec: spec ?? widget.spec,
      createdAt: widget.createdAt,
      seen: widget.seen,
    );
  }

  SurfaceProject _projectFromWidget(AgentWidget widget) {
    final json = Map<String, Object?>.from(widget.spec);
    json['id'] = (json['surfaceId'] ?? 'surface_${widget.id ?? ''}').toString();
    json['title'] = widget.title;
    json['kind'] = json['surfaceKind'] ?? json['surface'] ?? json['kind'];
    return _projectFrom(json);
  }

  Map<String, Object?> _specFromProject(SurfaceProject project) => {
    'surfaceId': project.id,
    'surfaceKind': project.kind.name,
    'experienceType': project.experienceType.name,
    'category': project.category,
    'skillInstructions': project.skillInstructions,
    'html': project.html,
    'css': project.css,
    'js': project.js,
    'manifest': project.manifest.toJson(),
    'backend': project.backend,
    'placement': project.placement.toJson(),
    'transparent': project.transparent,
    'rendering': project.rendering.name,
    if (project.versionHistory != null)
      'versionHistory': project.versionHistory!.toJson(),
    'revisions': project.revisions
        .map((revision) => revision.toJson())
        .toList(),
  };

  Map<String, Object?> _surfaceListItem(
    SurfaceProject project, {
    Object? widgetId,
  }) {
    return {
      'id': widgetId ?? project.id,
      'surfaceId': project.id,
      'title': project.title,
      'surface': project.kind.name,
      'rendering': project.rendering.name,
      'transparent': project.transparent,
      'placement': project.placement.toJson(),
      'manifest': project.manifest.toJson(),
      'revisionCount': project.revisions.length,
      if (project.versionHistory case final history?) ...{
        'currentVersionId': history.current.id,
        'versionNumber': history.current.number,
      },
    };
  }

  List<Object?> _revisionMaps(Object? raw) {
    if (raw is! List) return <Object?>[];
    // Preserve even unreadable historical records for recovery/audit. Only
    // the separate validated ledger determines which versions can be opened.
    return List<Object?>.from(raw);
  }

  Map<String, Object?> _revisionFromSpec(
    Map<String, Object?> spec, {
    required String title,
  }) => {
    'id': SurfaceVersionHistory.read(spec, title: title).current.id,
    'createdAt': DateTime.now().toIso8601String(),
    'title': title,
    'surfaceKind': (spec['surfaceKind'] ?? spec['surface'] ?? spec['kind'])
        ?.toString(),
    'rendering': spec['rendering']?.toString(),
    'transparent': spec['transparent'] == true,
    if (spec['placement'] != null) 'placement': spec['placement'],
    'experienceType': spec['experienceType']?.toString(),
    if (spec['category'] != null) 'category': spec['category'],
    if (spec['skillInstructions'] != null)
      'skillInstructions': spec['skillInstructions'],
    'html': spec['html']?.toString() ?? '',
    'css': spec['css']?.toString() ?? '',
    'js': spec['js']?.toString() ?? '',
    if (spec['manifest'] != null) 'manifest': spec['manifest'],
    if (spec['backend'] != null) 'backend': spec['backend'],
  };

  Map<String, Object?> _revisionFromProject(SurfaceProject project) => {
    'id': SurfaceVersionHistory.read(
      project.toJson(),
      title: project.title,
    ).current.id,
    'createdAt': DateTime.now().toIso8601String(),
    'title': project.title,
    'category': project.category,
    'skillInstructions': project.skillInstructions,
    'surfaceKind': project.kind.name,
    'rendering': project.rendering.name,
    'transparent': project.transparent,
    'placement': project.placement.toJson(),
    'experienceType': project.experienceType.name,
    'html': project.html,
    'css': project.css,
    'js': project.js,
    'manifest': project.manifest.toJson(),
    'backend': project.backend,
  };

  Map<String, Object?> _objectMap(Object? raw) {
    if (raw is! Map) return <String, Object?>{};
    return raw.map((key, value) => MapEntry(key.toString(), value));
  }

  void _applySpecPatch(Map<String, Object?> spec, Map<String, Object?> patch) {
    if (patch['category'] != null) {
      final value = patch['category'];
      if (!const {'travel', 'tools', 'game'}.contains(value)) {
        throw const FormatException('invalid_category');
      }
      spec['category'] = value;
    }
    if (patch['skillInstructions'] != null) {
      spec['skillInstructions'] = readSurfaceAgentDocument(
        patch['skillInstructions'],
        requireNonBlank: true,
      );
    }
    if (patch['html'] != null) spec['html'] = patch['html'].toString();
    if (patch['css'] != null || patch['transparent'] != null) {
      spec['css'] = SurfaceAuthoringTheme.preserveSnapshot(
        spec['css']?.toString() ?? '',
        (patch['css'] ?? spec['css'])?.toString() ?? '',
        transparent: patch['transparent'] == null
            ? null
            : _boolFrom(patch['transparent']),
      );
    }
    if (patch['js'] != null) spec['js'] = patch['js'].toString();
    if (patch['manifest'] != null) {
      spec['manifest'] = SurfaceManifest.fromSpec(patch['manifest']).toJson();
    }
    if (patch['backend'] != null) {
      spec['backend'] = _objectMap(patch['backend']);
    }
    if (patch['placement'] != null) {
      spec['placement'] = SurfacePlacement.fromJson(
        patch['placement'],
      ).toJson();
    }
    if (patch['transparent'] != null) {
      spec['transparent'] = _boolFrom(patch['transparent']);
    }
    if (patch['rendering'] != null) {
      spec['rendering'] = patch['rendering'].toString();
    }
    if (patch['experienceType'] != null) {
      spec['experienceType'] = patch['experienceType'].toString();
    }
    final surfaceKind = patch['surfaceKind'] ?? patch['surface'];
    if (surfaceKind != null) spec['surfaceKind'] = surfaceKind.toString();
  }

  void _restoreRevision(
    Map<String, Object?> spec,
    Map<String, Object?> revision,
  ) {
    if (revision.containsKey('title')) {
      spec['title'] = revision['title']?.toString() ?? '';
    }
    if (revision.containsKey('surfaceKind')) {
      final kind = revision['surfaceKind']?.toString() ?? '';
      spec['surfaceKind'] = kind;
      spec['kind'] = kind;
    }
    if (revision.containsKey('rendering')) {
      spec['rendering'] = revision['rendering']?.toString() ?? '';
    }
    if (revision.containsKey('transparent')) {
      spec['transparent'] = revision['transparent'] == true;
    }
    if (revision['placement'] != null) {
      spec['placement'] = SurfacePlacement.fromJson(
        revision['placement'],
      ).toJson();
    }
    if (revision.containsKey('category')) {
      spec['category'] = revision['category'];
    }
    if (revision.containsKey('skillInstructions')) {
      spec['skillInstructions'] = revision['skillInstructions'];
    }
    if (revision.containsKey('experienceType')) {
      spec['experienceType'] = revision['experienceType']?.toString() ?? '';
    }
    if (revision.containsKey('html')) {
      spec['html'] = revision['html']?.toString() ?? '';
    }
    if (revision.containsKey('css')) {
      spec['css'] = revision['css']?.toString() ?? '';
    }
    if (revision.containsKey('js')) {
      spec['js'] = revision['js']?.toString() ?? '';
    }
    if (revision['manifest'] != null) {
      spec['manifest'] = SurfaceManifest.fromSpec(
        revision['manifest'],
      ).toJson();
    }
    if (revision['backend'] != null) {
      spec['backend'] = _objectMap(revision['backend']);
    }
  }

  SurfaceVersionSnapshot? _versionToRestore(
    SurfaceVersionHistory history,
    String requestedId,
  ) {
    if (requestedId.isNotEmpty) return history.find(requestedId);
    // Consecutive undo walks the source ancestry, while every restoration is
    // still appended as a new immutable version.
    final origin = history.current.restoredFromId == null
        ? history.current
        : history.find(history.current.restoredFromId!)!;
    return origin.parentId == null ? null : history.find(origin.parentId!);
  }

  bool _boolFrom(Object? raw) {
    if (raw is bool) return raw;
    return raw?.toString().toLowerCase() == 'true';
  }
}

class _SurfaceMatch {
  const _SurfaceMatch(this.widget, {required this.openedByWidgetId});

  final AgentWidget widget;
  final bool openedByWidgetId;
}

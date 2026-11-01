import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/agent_widget.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/surface/surface_version_history.dart';
import 'package:maaso/src/features/applets/application/applet_version_history.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:sembast/sembast_memory.dart';

Map<String, Object?> _source(String text) => {
  'surfaceId': 'version-test',
  'surfaceKind': 'card',
  'rendering': 'dom',
  'experienceType': 'utility',
  'category': 'tools',
  'skillInstructions': 'Use this tool.',
  'html': '<main>$text</main>',
  'css': ':root{--theme:snapshot}',
  'js': '',
  'manifest': {'actions': <Object?>[], 'events': <Object?>[]},
  'backend': {
    'collections': ['saved'],
  },
};

AgentWidget _widget(Map<String, Object?> spec) {
  final item = AgentWidget(
    agentId: 'self',
    title: 'Versioned applet',
    kind: 'surface',
    spec: spec,
    createdAt: DateTime(2026),
    seen: true,
  );
  AppletLocalOwnership.stamp(item);
  return item;
}

void main() {
  setUp(() {
    appServices.testMode = true;
    appServices.reset();
  });
  tearDown(appServices.reset);

  test('snapshots deeply detach nested source and cannot be mutated', () {
    final spec = _source('V1');
    final history = SurfaceVersionHistory.read(spec, title: 'Test');
    ((spec['backend'] as Map)['collections'] as List).add('later');
    expect((history.current.source['backend'] as Map)['collections'], [
      'saved',
    ]);
    expect(
      () => ((history.current.source['backend'] as Map)['collections'] as List)
          .add('bad'),
      throwsUnsupportedError,
    );
    expect(() => history.versions.clear(), throwsUnsupportedError);
    final copy = SurfaceVersionHistory.read({
      'versionHistory': jsonDecode(jsonEncode(history.toJson())),
    }, title: 'Test');
    expect(copy.current.sourceSha256, history.current.sourceSha256);
  });

  test('restoring V1 appends V3 and preserves V2 with distinct ancestry', () {
    final v1 = SurfaceVersionHistory.read(_source('V1'), title: 'Test');
    final v2 = v1.append(_source('V2'), title: 'Test');
    final v3 = v2.append(
      v1.current.source,
      title: 'Test',
      restoredFromId: v1.current.id,
    );
    expect(v3.versions.map((v) => v.number), [1, 2, 3]);
    expect(v3.versions[1].source['html'], '<main>V2</main>');
    expect(v3.current.source['html'], '<main>V1</main>');
    expect(v3.current.parentId, v2.current.id);
    expect(v3.current.restoredFromId, v1.current.id);
    expect(v3.current.id, isNot(v1.current.id));
    expect(v3.current.source['css'], ':root{--theme:snapshot}');
  });

  test(
    'legacy revisions retain exact ids and current source becomes next version',
    () {
      final spec = _source('current');
      spec['revisions'] = [
        {..._source('old'), 'id': 'old-revision', 'title': 'Original'},
        {'id': 'damaged', 'html': 42},
      ];
      final original = jsonEncode(spec['revisions']);
      final history = SurfaceVersionHistory.read(spec, title: 'Current');
      expect(history.versions, hasLength(2));
      expect(history.versions.first.id, 'old-revision');
      expect(history.versions.first.source['title'], 'Original');
      expect(history.current.number, 2);
      expect(jsonEncode(spec['revisions']), original);
    },
  );

  test(
    'damaged persisted history is reported instead of silently reissued as V1',
    () {
      final history = SurfaceVersionHistory.read(_source('V1'), title: 'Test');
      final raw = jsonDecode(jsonEncode(history.toJson())) as Map;
      (raw['versions'][0]['source'] as Map)['html'] = 'tampered';
      expect(
        () =>
            SurfaceVersionHistory.read({'versionHistory': raw}, title: 'Test'),
        throwsFormatException,
      );
    },
  );

  test('fingerprint fences restore ABA while ignoring sync metadata', () {
    final source = _source('same');
    final history = SurfaceVersionHistory.read(source, title: 'Test');
    source['versionHistory'] = history.toJson();
    final first = surfaceVersionFingerprint(source, title: 'Test');
    source['cloud'] = {'revisionNo': 82};
    expect(surfaceVersionFingerprint(source, title: 'Test'), first);
    source['versionHistory'] = history
        .append(source, title: 'Test', restoredFromId: history.current.id)
        .toJson();
    expect(surfaceVersionFingerprint(source, title: 'Test'), isNot(first));
  });

  test('atomic baseline comparison allows only one competing edit', () async {
    final db = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'version-cas.db',
    );
    addTearDown(db.onClose);
    final item = _widget(_source('V1'));
    item.id = await db.saveAgentWidget(item);
    final baseline = surfaceVersionFingerprint(item.spec, title: item.title);
    await db.updateGeneratedSurface(
      item.id!,
      spec: {...item.spec, 'html': '<main>V2</main>'},
      expectedSourceFingerprint: baseline,
    );
    await expectLater(
      db.updateGeneratedSurface(
        item.id!,
        spec: {...item.spec, 'html': '<main>stale</main>'},
        expectedSourceFingerprint: baseline,
      ),
      throwsStateError,
    );
    expect((await db.getAllWidgets()).single.spec['html'], '<main>V2</main>');
  });

  test(
    'restoration persists new private version and rejects a stale repeat',
    () async {
      final db = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'version-restore.db',
      );
      appServices.put<DBService>(db);
      final v1 = SurfaceVersionHistory.read(
        _source('V1'),
        title: 'Versioned applet',
      );
      final spec = _source('V2');
      spec['versionHistory'] = v1
          .append(spec, title: 'Versioned applet')
          .toJson();
      final item = _widget(spec);
      item.id = await db.saveAgentWidget(item);
      final restored = await restoreAppletVersion(
        item: item,
        versionId: v1.current.id,
        scopeKey: AppletLocalOwnership.currentScopeKey(),
        firstFrameReady: true,
      );
      expect(restored.id, item.id);
      final history = SurfaceVersionHistory.read(
        restored.spec,
        title: restored.title,
      );
      expect(history.current.number, 3);
      expect(history.versions[1].source['html'], '<main>V2</main>');
      expect(history.current.source['html'], '<main>V1</main>');
      await expectLater(
        restoreAppletVersion(
          item: item,
          versionId: v1.current.id,
          scopeKey: AppletLocalOwnership.currentScopeKey(),
          firstFrameReady: true,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'JSON backup and restore preserves legacy history, immutable versions and public pointers',
    () async {
      final first = SurfaceVersionHistory.read(_source('V1'), title: 'Backup');
      final history = first
          .append(_source('V2'), title: 'Backup')
          .append(
            first.current.source,
            title: 'Backup',
            restoredFromId: first.current.id,
          );
      final original = _widget({
        ..._source('V1'),
        'versionHistory': history.toJson(),
        'revisions': [
          {'id': 'old-damaged-record', 'html': 42},
        ],
        'cloud': {
          'gameId': 'ag_backup',
          'revisionNo': 8,
          'publishedRevisionNo': 1,
          'hasPublished': true,
        },
        'versionCloudBindings': {
          first.current.id: {
            'revisionNo': 1,
            'sourceSha256': first.current.sourceSha256,
          },
        },
      });
      final before = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'backup-before-${DateTime.now().microsecondsSinceEpoch}.db',
      );
      original.id = await before.saveAgentWidget(original);
      final backup = jsonEncode(
        (await before.getAllWidgets())
            .map((row) => {'id': row.id, 'record': row.toJson()})
            .toList(),
      );
      await before.close();
      final after = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'backup-after-${DateTime.now().microsecondsSinceEpoch}.db',
      );
      for (final row in jsonDecode(backup) as List) {
        await after.saveAgentWidget(
          AgentWidget.fromJson(
            (row['record'] as Map).cast<String, Object?>(),
            id: row['id'] as int,
          ),
        );
      }
      final restored = (await after.getAllWidgets()).single;
      final restoredHistory = SurfaceVersionHistory.read(
        restored.spec,
        title: restored.title,
      );
      expect(
        restoredHistory.versions.map((v) => v.id),
        history.versions.map((v) => v.id),
      );
      expect(restoredHistory.current.number, 3);
      expect(restoredHistory.versions[1].source['html'], '<main>V2</main>');
      expect((restored.spec['cloud'] as Map)['publishedRevisionNo'], 1);
      expect((restored.spec['revisions'] as List).single, {
        'id': 'old-damaged-record',
        'html': 42,
      });
      await after.close();
    },
  );

  test('restoration requires the current owner scope', () async {
    final item = _widget(_source('V1'))..id = 1;
    final history = SurfaceVersionHistory.read(item.spec, title: item.title);
    await expectLater(
      restoreAppletVersion(
        item: item,
        versionId: history.current.id,
        scopeKey: 'another-account',
        firstFrameReady: true,
      ),
      throwsStateError,
    );
  });
}

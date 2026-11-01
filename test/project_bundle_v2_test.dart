import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/project_build/domain/project_bundle_v2.dart';
import 'package:maaso/src/features/project_build/domain/project_json_canonicalizer.dart';

Map<String, dynamic> _golden() =>
    jsonDecode(
          File(
            'tool/fixtures/project_bundle_v2_golden.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;
Map<String, dynamic> _wire() => _golden()['bundle'] as Map<String, dynamic>;

Map<String, dynamic> _rewriteFile(
  Map<String, dynamic> wire,
  String path,
  List<int> bytes,
) {
  final entry = (wire['files'] as List).cast<Map>().singleWhere(
    (item) => item['path'] == path,
  );
  entry['bytesBase64'] = base64Encode(bytes);
  entry['byteLength'] = bytes.length;
  entry['sha256'] = projectBundleV2BytesDigest(bytes);
  final manifest = wire['manifest'] as Map;
  final metadata = (manifest['files'] as List).cast<Map>().singleWhere(
    (item) => item['path'] == path,
  );
  metadata['byteLength'] = bytes.length;
  metadata['sha256'] = entry['sha256'];
  final files = (manifest['files'] as List)
      .map(ProjectBundleV2FileMetadata.fromJson)
      .toList();
  manifest['contentDigest'] = projectBundleV2FileIndexDigest(
    files,
    artifact: false,
  );
  manifest['artifactDigest'] = projectBundleV2FileIndexDigest(
    files,
    artifact: true,
  );
  return wire;
}

void main() {
  const codec = ProjectBundleV2Codec();
  test(
    'production golden has identical candidate/bundle and raw content/artifact digests',
    () {
      final golden = _golden();
      final bundle = codec.decode(golden['bundle']);
      final expected = golden['expected'] as Map;
      expect(bundle.candidateDigest, expected['candidateDigest']);
      expect(bundle.bundleDigest, expected['candidateDigest']);
      expect(bundle.manifest.contentDigest, expected['contentDigest']);
      expect(bundle.manifest.artifactDigest, expected['artifactDigest']);
      expect(
        const ProjectJsonCanonicalizer().canonicalize(bundle.manifest.toJson()),
        expected['canonicalManifest'],
      );
      expect(bundle.title, '离线清单');
      expect(bundle.routes.map((route) => route.routeId), ['home', 'details']);
      expect(bundle.routes.last.backTarget, 'home');
      expect(bundle.routes.first.acceptsParameters({}), isTrue);
      expect(
        bundle.routes.first.acceptsParameters({'unexpected': true}),
        isFalse,
      );
      expect(
        codec.decodeString(codec.encode(bundle)).candidateDigest,
        bundle.candidateDigest,
      );
    },
  );

  test('validated bundle and every nested contract are immutable', () {
    final bundle = codec.decode(_wire());
    expect(() => bundle.files.clear(), throwsUnsupportedError);
    expect(
      () => bundle.files['dist/index.html']![0] = 0,
      throwsUnsupportedError,
    );
    expect(
      () => bundle.manifest.toJson()['projectId'] = 'other',
      throwsUnsupportedError,
    );
    expect(
      () => (bundle.manifest.toJson()['files'] as List).clear(),
      throwsUnsupportedError,
    );
    expect(() => bundle.project['title'] = 'other', throwsUnsupportedError);
    expect(
      () => bundle.routes.first.toJson()['routeId'] = 'other',
      throwsUnsupportedError,
    );
    expect(
      () => (bundle.routes.first.toJson()['parametersSchema'] as Map).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => bundle.protocol.toJson()['projectKind'] = 'game',
      throwsUnsupportedError,
    );
  });

  test(
    'unknown/omitted fields and self-certified verification are rejected',
    () {
      for (final update in [
        {'packageSchema': 3},
        {'profile': 'maaso.project.preflight.v2'},
        {'sdkVersion': '9.0.0'},
        {'runtimeMinVersion': '1.0.0'},
        {'verified': true},
        {'hashAlgorithm': 'sha256'},
        {'entryPoint': 'dist/other.html'},
      ]) {
        final wire = _wire();
        (wire['manifest'] as Map).addAll(update);
        expect(() => codec.decode(wire), throwsFormatException);
      }
      final missing = _wire();
      (missing['manifest'] as Map).remove('baseRevision');
      expect(() => codec.decode(missing), throwsFormatException);
      final report = _wire()..['verification'] = {'passed': true};
      expect(() => codec.decode(report), throwsFormatException);
      final duplicate = jsonEncode(_wire()).replaceFirst(
        '"packageSchema":2',
        '"packageSchema":2,"packageSchema":2',
      );
      expect(() => codec.decodeString(duplicate), throwsFormatException);
    },
  );

  test('checks exact file set, metadata, raw bytes and canonical base64', () {
    final missing = _wire();
    (missing['files'] as List).removeLast();
    expect(() => codec.decode(missing), throwsFormatException);
    final duplicate = _wire();
    (duplicate['files'] as List)[1] = (duplicate['files'] as List).first;
    expect(() => codec.decode(duplicate), throwsFormatException);
    final metadata = _wire();
    ((metadata['files'] as List).first as Map)['mimeType'] = 'application/json';
    expect(() => codec.decode(metadata), throwsFormatException);
    final tampered = _wire();
    final file = (tampered['files'] as List).first as Map;
    final bytes = base64Decode(file['bytesBase64'] as String)..[0] = 0;
    file['bytesBase64'] = base64Encode(bytes);
    expect(() => codec.decode(tampered), throwsFormatException);
    final spaced = _wire();
    final encoded = (spaced['files'] as List).first as Map;
    encoded['bytesBase64'] = '${encoded['bytesBase64']}\n';
    expect(() => codec.decode(spaced), throwsFormatException);
  });

  test(
    'rejects portable-path aliases, directory collisions and unsupported runtime/assets',
    () {
      for (final path in [
        '../a',
        '/a',
        'a//b',
        'a/../b',
        r'a\b',
        'https://x',
        'a%2fb',
        '页面.png',
        'AUX.png',
        'a.',
      ]) {
        expect(() => validateProjectBundleV2Path(path), throwsFormatException);
      }
      expect(
        () => ProjectBundleV2File(
          path: 'dist/extra.js',
          mimeType: 'text/javascript',
          role: ProjectBundleV2FileRole.runtime,
          bytes: [],
        ),
        throwsFormatException,
      );
      expect(
        () => ProjectBundleV2File(
          path: 'assets/icon.svg',
          mimeType: 'image/svg+xml',
          role: ProjectBundleV2FileRole.asset,
          bytes: [],
        ),
        throwsFormatException,
      );
      expect(
        () => ProjectBundleV2File(
          path: 'assets/sound.wav',
          mimeType: 'audio/wav',
          role: ProjectBundleV2FileRole.asset,
          bytes: [],
        ),
        throwsFormatException,
      );
      final wire = _wire();
      final entries = (wire['manifest'] as Map)['files'] as List;
      final alias = Map<String, Object?>.from(entries.first as Map)
        ..['path'] = 'AGENT.md';
      entries.add(alias);
      entries.sort(
        (a, b) => (a['path'] as String).compareTo(b['path'] as String),
      );
      expect(() => codec.decode(wire), throwsFormatException);
    },
  );

  test('document and route changes cannot retain stale identity bindings', () {
    final badDoc = _wire();
    final docEntry = (badDoc['files'] as List).cast<Map>().singleWhere(
      (entry) => entry['path'] == 'agent.md',
    );
    final doc = utf8
        .decode(base64Decode(docEntry['bytesBase64'] as String))
        .replaceFirst('"protocolSha256":"', '"protocolSha256":"a');
    expect(
      () => codec.decode(_rewriteFile(badDoc, 'agent.md', utf8.encode(doc))),
      throwsFormatException,
    );
    final routesWire = _wire();
    final routeEntry = (routesWire['files'] as List).cast<Map>().singleWhere(
      (entry) => entry['path'] == 'routes.json',
    );
    final routes =
        jsonDecode(
              utf8.decode(base64Decode(routeEntry['bytesBase64'] as String)),
            )
            as Map;
    (routes['routes'] as List)[1]['parentRouteId'] = 'details';
    expect(
      () => codec.decode(
        _rewriteFile(
          routesWire,
          'routes.json',
          utf8.encode(jsonEncode(routes)),
        ),
      ),
      throwsFormatException,
    );
    final projectWire = _wire();
    final projectEntry = (projectWire['files'] as List).cast<Map>().singleWhere(
      (entry) => entry['path'] == 'project.json',
    );
    final project =
        jsonDecode(
              utf8.decode(base64Decode(projectEntry['bytesBase64'] as String)),
            )
            as Map;
    project['title'] = '😊' * 81;
    expect(
      () => codec.decode(
        _rewriteFile(
          projectWire,
          'project.json',
          utf8.encode(jsonEncode(project)),
        ),
      ),
      throwsFormatException,
    );
  });

  test('assets require declared image signatures and supported dimensions', () {
    final wire = _wire();
    expect(
      () => codec.decode(_rewriteFile(wire, 'assets/dot.png', [1, 2, 3, 4])),
      throwsFormatException,
    );
    final invalidUtf8 = _wire();
    expect(
      () =>
          codec.decode(_rewriteFile(invalidUtf8, 'src/main.js', [0xc3, 0x28])),
      throwsFormatException,
    );
  });

  test(
    'metadata budgets and mandatory sorted files are checked before payload decode',
    () {
      final wire = _wire();
      final manifest = wire['manifest'] as Map;
      (manifest['files'] as List).removeLast();
      expect(() => codec.decode(wire), throwsFormatException);
      final unsorted = _wire();
      final rows = (unsorted['manifest'] as Map)['files'] as List;
      final first = rows[0];
      rows[0] = rows[1];
      rows[1] = first;
      expect(() => codec.decode(unsorted), throwsFormatException);
      final oversized = _wire();
      ((oversized['manifest'] as Map)['files'] as List).first['byteLength'] =
          ProjectBundleV2Limits.maxFileBytes + 1;
      expect(() => codec.decode(oversized), throwsFormatException);
    },
  );
}

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/offline/local_surface_host.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });
  tearDown(appServices.reset);

  test(
    'runtime policy precedes authored source without changing saved body or CSS',
    () {
      const source =
          '<!doctype html><html lang="zh"><head><title>Game</title>'
          '<script src="https://example.test/remote.js"></script></head>'
          '<body class="custom" style="background:hotpink"><script>runGame()</script></body></html>';
      final document = localSurfaceDocument(source, {
        'score': '7',
      }, storageToken: 'own-work');
      expect(
        document.indexOf('Content-Security-Policy'),
        lessThan(document.indexOf('remote.js')),
      );
      expect(document, contains("connect-src 'none'"));
      expect(document, contains("worker-src data: blob:"));
      expect(
        document,
        contains("script-src 'unsafe-inline' 'unsafe-eval' data: blob:"),
      );
      expect(
        document,
        contains('<body class="custom" style="background:hotpink">'),
      );
      expect(document, contains('<script>runGame()</script>'));
      expect(document, contains('"score":"7"'));
      expect(source, isNot(contains('Content-Security-Policy')));
    },
  );

  test(
    'original player localStorage persists per work and fences previous document events',
    () async {
      final database = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'local-surface-state.db',
      );
      appServices.put<DBService>(database);
      addTearDown(database.close);
      final first = await LocalSurfaceStorage.open('game-a');
      first.receive(
        jsonEncode({
          'op': 'set',
          'key': 'score',
          'value': '42',
          'scopeToken': first.nonce,
        }),
      );
      final reopened = await LocalSurfaceStorage.open('game-a');
      expect(reopened.state, {'score': '42'});
      final other = await LocalSurfaceStorage.open('game-b');
      other.receive(
        jsonEncode({
          'op': 'set',
          'key': 'score',
          'value': 'wrong-game',
          'scopeToken': first.nonce,
        }),
      );
      expect(other.state, isEmpty);
      other.receive(
        jsonEncode({
          'op': 'set',
          'key': 'score',
          'value': '9',
          'scopeToken': other.nonce,
        }),
      );
      expect((await LocalSurfaceStorage.open('game-b')).state, {'score': '9'});
      expect((await LocalSurfaceStorage.open('game-a')).state, {'score': '42'});
    },
  );
}

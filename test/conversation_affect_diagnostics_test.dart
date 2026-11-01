import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/features/agent/application/conversation/conversation_affect_diagnostics.dart';
import 'package:sembast/sembast_memory.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late DBService service;
  late Database database;
  var current = true;
  final recent = StoreRef<String, List<Object?>>(
    ConversationAffectDiagnostics.storeName,
  ).record('recent');

  void record({
    String? mood = 'happy',
    double? intensity = .6,
    int? durationMs = 1500,
    bool? persistent = false,
    bool? rendererReady,
    int cueCount = 1,
    bool Function()? isCurrent,
  }) => ConversationAffectDiagnostics.record(
    mode: ConversationAffectDiagnosticMode.replyFirst,
    outcome: ConversationAffectDiagnosticOutcome.applied,
    reason: ConversationAffectDiagnosticReason.projectionApplied,
    isCurrent: isCurrent ?? () => current,
    cuePresent: true,
    cueCount: cueCount,
    mood: mood,
    intensity: intensity,
    durationMs: durationMs,
    persistent: persistent,
    rendererReady: rendererReady,
  );

  setUp(() async {
    await ConversationAffectDiagnostics.whenSettled;
    await appServices.reset();
    appServices.testMode = true;
    current = true;
    service = await DBService().init(
      factory: databaseFactoryMemory,
      path: 'affect-diagnostics',
    );
    database = service.raw;
    appServices.put<DBService>(service);
  });

  tearDown(() async {
    await ConversationAffectDiagnostics.whenSettled;
    await appServices.reset();
    await service.close();
    await databaseFactoryMemory.deleteDatabase('affect-diagnostics');
  });

  test(
    'only fixed categories and validated bounded metadata are persisted',
    () async {
      record();
      await ConversationAffectDiagnostics.whenSettled;
      final rows = await recent.get(database);
      final entry = (rows!.single as Map).cast<String, Object?>();
      expect(
        entry.keys,
        unorderedEquals([
          'atUtc',
          'mode',
          'outcome',
          'reason',
          'cuePresent',
          'cueCount',
          'mood',
          'intensity',
          'durationMs',
          'persistent',
        ]),
      );
      expect(DateTime.parse(entry['atUtc']! as String).isUtc, isTrue);
      expect(entry['mode'], 'replyFirst');
      expect(entry['outcome'], 'applied');
      expect(entry['reason'], 'projectionApplied');
      expect(entry['mood'], 'happy');
      expect(entry['intensity'], .6);
      expect(entry['durationMs'], 1500);
      expect(entry['cuePresent'], isTrue);
      expect(entry['cueCount'], 1);
      expect(entry['persistent'], isFalse);
    },
  );

  test('transactions keep only the latest twenty observations', () async {
    for (var index = 0; index < 27; index++) {
      record(durationMs: index);
    }
    await ConversationAffectDiagnostics.whenSettled;
    final rows = await recent.get(database);
    expect(rows, hasLength(20));
    expect((rows!.first as Map)['durationMs'], 7);
    expect((rows.last as Map)['durationMs'], 26);
  });

  test('hostile mood strings and nonfinite values never reach disk', () async {
    for (final mood in [
      'private prompt marker',
      'sk-secret-api-key',
      'https://private.example',
      'HAPPY',
      'happy\nprivate reply',
    ]) {
      record(mood: mood, intensity: double.nan);
    }
    record(intensity: double.infinity, durationMs: -100, cueCount: -3);
    record(intensity: 8, durationMs: 999999999, cueCount: 9999999);
    await ConversationAffectDiagnostics.whenSettled;
    final rows = await recent.get(database);
    final encoded = jsonEncode(rows);
    for (final marker in [
      'private',
      'secret',
      'https',
      'HAPPY',
      'NaN',
      'Infinity',
    ]) {
      expect(encoded, isNot(contains(marker)));
    }
    for (final entry in rows!.take(5)) {
      expect((entry as Map).containsKey('mood'), isFalse);
      expect(entry.containsKey('intensity'), isFalse);
    }
    expect((rows[5] as Map)['durationMs'], 0);
    expect((rows[5] as Map)['cueCount'], 0);
    expect((rows.last as Map)['durationMs'], 60000);
    expect((rows.last as Map)['cueCount'], 32);
    expect((rows.last as Map)['intensity'], 1.0);
  });

  test(
    'a stale originating context never writes queued observations',
    () async {
      record();
      current = false;
      await ConversationAffectDiagnostics.whenSettled;
      expect(await recent.get(database), isNull);
      record();
      await ConversationAffectDiagnostics.whenSettled;
      expect(await recent.get(database), isNull);
    },
  );

  test(
    'context is rechecked inside the transaction immediately before put',
    () async {
      var checks = 0;
      record(isCurrent: () => ++checks < 4);
      await ConversationAffectDiagnostics.whenSettled;
      expect(checks, 4);
      expect(await recent.get(database), isNull);
    },
  );

  test(
    'a completed turn retains its legal receipt while the account scope stays current',
    () async {
      var turnActive = true;
      var observedAfterCompletion = false;
      if (turnActive) {
        record(
          isCurrent: () {
            observedAfterCompletion |= !turnActive;
            return current;
          },
        );
      }
      turnActive = false;
      await ConversationAffectDiagnostics.whenSettled;
      expect(observedAfterCompletion, isTrue);
      expect(await recent.get(database), hasLength(1));
    },
  );

  test(
    'canonical playful and proud moods and readiness are retained',
    () async {
      record(mood: 'playful', rendererReady: true);
      record(mood: 'proud', rendererReady: false);
      await ConversationAffectDiagnostics.whenSettled;
      final rows = await recent.get(database);
      expect((rows!.first as Map)['mood'], 'playful');
      expect((rows.first as Map)['rendererReady'], isTrue);
      expect((rows.last as Map)['mood'], 'proud');
      expect((rows.last as Map)['rendererReady'], isFalse);
    },
  );

  test(
    'replacing account DB before scheduled work cannot borrow the new handle',
    () async {
      // Replacement registration intentionally does not close the old handle;
      // this proves identity fencing independently of a closed-DB exception.
      final replacement = await DBService().init(
        factory: databaseFactoryMemory,
        path: 'affect-new-account',
      );
      record();
      appServices.put<DBService>(replacement, overrideAbstract: true);
      try {
        await ConversationAffectDiagnostics.whenSettled;
        expect(await recent.get(database), isNull);
        expect(await recent.get(replacement.raw), isNull);
        record(mood: 'surprised');
        await ConversationAffectDiagnostics.whenSettled;
        expect(await recent.get(replacement.raw), hasLength(1));
      } finally {
        await replacement.close();
        await databaseFactoryMemory.deleteDatabase('affect-new-account');
      }
    },
  );

  test('logout registration removal drops queued observations', () async {
    final logoutService = await DBService(
      closeDatabase: (_) async {},
    ).init(factory: databaseFactoryMemory, path: 'affect-logout');
    final logoutDatabase = logoutService.raw;
    appServices.put<DBService>(logoutService, overrideAbstract: true);
    try {
      record();
      await appServices.delete<DBService>(force: true);
      await ConversationAffectDiagnostics.whenSettled;
      expect(await recent.get(logoutDatabase), isNull);
    } finally {
      await logoutService.close();
      await logoutDatabase.close();
      await databaseFactoryMemory.deleteDatabase('affect-logout');
    }
  });

  test(
    'record returns immediately even while a database transaction is blocked',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final blocker = database.transaction((_) async {
        entered.complete();
        await release.future;
      });
      await entered.future;
      try {
        expect(() => record(), returnsNormally);
        var settled = false;
        unawaited(
          ConversationAffectDiagnostics.whenSettled.then((_) => settled = true),
        );
        await Future<void>.delayed(Duration.zero);
        expect(settled, isFalse);
      } finally {
        release.complete();
      }
      await blocker;
      await ConversationAffectDiagnostics.whenSettled;
      expect(await recent.get(database), hasLength(1));
    },
  );

  test(
    'absent DB, throwing current fence and closed database fail without escaping',
    () async {
      expect(
        () => record(isCurrent: () => throw StateError('private')),
        returnsNormally,
      );
      await ConversationAffectDiagnostics.whenSettled;
      expect(await recent.get(database), isNull);
      await database.close();
      expect(() => record(), returnsNormally);
      await expectLater(ConversationAffectDiagnostics.whenSettled, completes);
      await appServices.reset();
      expect(() => record(), returnsNormally);
      await expectLater(ConversationAffectDiagnostics.whenSettled, completes);
    },
  );
}

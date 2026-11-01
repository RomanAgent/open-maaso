import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/features/agent/application/skills/app_control_skill.dart';
import 'package:maaso/src/features/agent/data/skills/memory_skill.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String storageKeyPrefix;

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
    storageKeyPrefix = 'memory-control-test-${_scopeSequence++}';
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  tearDown(() async {
    await appServices.reset();
  });

  test(
    'remember parses JSON args, uses MemoryBus, and awaits the write',
    () async {
      final writeGate = Completer<MemoryWriteResult>();
      final bus = _RecordingMemoryBus(writeResult: writeGate.future);
      appServices.put<MemoryBus>(bus);
      final handler = MemorySkill().methods['remember']!;

      var completed = false;
      final invocation =
          Future<dynamic>.sync(
            () => handler(<dynamic>[
              jsonEncode(<String, Object?>{'fact': '  用户喜欢乌龙茶  '}),
            ]),
          ).then((value) {
            completed = true;
            return value;
          });

      await Future<void>.delayed(Duration.zero);
      expect(bus.proposals, hasLength(1));
      expect(completed, isFalse);
      expect(bus.proposals.single.what, '用户喜欢乌龙茶');
      expect(bus.proposals.single.kind, EpisodeKind.fact);

      final persisted = bus.proposals.single..id = 41;
      writeGate.complete(
        MemoryWriteResult(
          disposition: MemoryWriteDisposition.accepted,
          episode: persisted,
          created: true,
          projected: true,
        ),
      );

      final output = jsonDecode((await invocation).toString()) as Map;
      expect(output['status'], 'success');
      expect(output['disposition'], MemoryWriteDisposition.accepted.name);
      expect(output['episodeId'], 41);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList(
          '$storageKeyPrefix.preferences.agent_long_term_facts',
        ),
        isNull,
      );
    },
  );

  test(
    'remember accepts a map and rejects malformed argument objects',
    () async {
      final episode = Episode(
        id: 7,
        when: DateTime.utc(2026, 8, 30),
        what: 'placeholder',
        reviewState: EpisodeReviewState.pending,
      );
      final bus = _RecordingMemoryBus(
        writeResult: Future<MemoryWriteResult>.value(
          MemoryWriteResult(
            disposition: MemoryWriteDisposition.quarantined,
            episode: episode,
            created: true,
            projected: false,
            reason: 'automatic_summary_requires_review',
          ),
        ),
      );
      appServices.put<MemoryBus>(bus);
      final handler = MemorySkill().methods['remember']!;

      final output =
          jsonDecode(
                (await Future<dynamic>.sync(
                  () => handler(<dynamic>[
                    <String, Object?>{'fact': '用户喜欢散步'},
                  ]),
                )).toString(),
              )
              as Map;
      expect(bus.proposals.single.what, '用户喜欢散步');
      expect(output['status'], 'pending_review');
      expect(output['disposition'], MemoryWriteDisposition.quarantined.name);
      expect(output['reviewState'], EpisodeReviewState.pending.name);
      expect(output['reason'], 'automatic_summary_requires_review');

      for (final args in <List<dynamic>>[
        const <dynamic>[],
        <dynamic>[
          jsonEncode(<String, Object?>{'fact': 12}),
        ],
        <dynamic>[
          <String, Object?>{'fact': 'valid', 'unexpected': true},
        ],
        const <dynamic>['not-json'],
      ]) {
        final invalid =
            jsonDecode(
                  (await Future<dynamic>.sync(() => handler(args))).toString(),
                )
                as Map;
        expect(invalid['error'], isNotEmpty);
      }
      expect(bus.proposals, hasLength(1));
    },
  );

  test(
    'forget never performs keyword deletion and directs review to Ledger',
    () async {
      final key = '$storageKeyPrefix.preferences.agent_long_term_facts';
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(key, <String>['keep this legacy fact']);
      final navigation = _ReviewNavigation(
        '{"status":"ok","page":"memory_ledger"}',
      );
      final handler = MemorySkill(appControl: navigation).methods['forget']!;

      final output =
          jsonDecode(
                (await Future<dynamic>.sync(
                  () => handler(const <dynamic>['keep']),
                )).toString(),
              )
              as Map;

      expect(output['status'], 'review_required');
      expect(output['reason'], 'memory_ledger_opened');
      expect(output['opened'], isTrue);
      expect(output['deleted'], isFalse);
      expect(output['confirmationRequired'], isTrue);
      expect(output['nextAction'], 'delete_memory');
      expect(navigation.requests, <Map<String, Object?>>[
        <String, Object?>{'page': 'memory_ledger'},
      ]);
      expect(prefs.getStringList(key), <String>['keep this legacy fact']);
    },
  );

  test(
    'forget reports navigation failure without claiming opened or deleted',
    () async {
      final navigation = _ReviewNavigation('{"error":"user_takeover"}');
      final output =
          jsonDecode(
                (await MemorySkill(appControl: navigation).methods['forget']!(
                  const <dynamic>[],
                )).toString(),
              )
              as Map;
      expect(output['opened'], isFalse);
      expect(output['deleted'], isFalse);
      expect(output['navigationError'], 'user_takeover');
    },
  );

  test('peer agent cannot open the owner memory review page', () async {
    final navigation = _ReviewNavigation('{"status":"ok"}');
    final output =
        jsonDecode(
              (await MemorySkill(
                agentId: 'peer',
                appControl: navigation,
              ).methods['forget']!(const <dynamic>[])).toString(),
            )
            as Map;
    expect(output['error'], 'owner_only');
    expect(navigation.requests, isEmpty);
  });
}

final class _ReviewNavigation extends AppControlSkill {
  _ReviewNavigation(this.receipt);
  final String receipt;
  final requests = <Map<String, Object?>>[];
  @override
  Map<String, dynamic Function(List<dynamic>)> get methods => {
    'execute': (args) {
      requests.add(Map<String, Object?>.from(args.single as Map));
      return receipt;
    },
  };
}

final class _RecordingMemoryBus extends MemoryBus {
  _RecordingMemoryBus({required this.writeResult});

  final Future<MemoryWriteResult> writeResult;
  final List<Episode> proposals = <Episode>[];

  @override
  Future<MemoryWriteResult> writeEpisodeWithResult(Episode episode) {
    proposals.add(episode);
    return writeResult;
  }
}

var _scopeSequence = 0;

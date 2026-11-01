import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/services/memory_bus.dart';
import 'package:maaso/src/core/services/memory_write_coordinator.dart';
import 'package:maaso/src/features/agent/application/skills/log_episode_skill.dart';
import 'package:maaso/src/features/agent/data/skills/memory_skill.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    await appServices.reset();
    appServices.testMode = true;
  });

  tearDown(appServices.reset);

  for (final skill in <String>['LogEpisode', 'MemoryControl']) {
    group('$skill memory write receipt', () {
      for (final receipt in _receipts) {
        test(receipt.label, () async {
          final episode = receipt.reviewState == null
              ? null
              : Episode(
                  id: 41,
                  when: DateTime.utc(2026, 9, 22),
                  what: _memoryText,
                  reviewState: receipt.reviewState!,
                );
          final bus = _ReceiptMemoryBus(
            Future<MemoryWriteResult>.value(
              MemoryWriteResult(
                disposition: receipt.disposition,
                episode: episode,
                created: receipt.created,
                projected: receipt.projected,
                reason: receipt.reason,
              ),
            ),
          );
          appServices.put<MemoryBus>(bus);

          final output = await _invoke(skill);

          expect(bus.proposals, hasLength(1));
          expect(bus.proposals.single.what, _memoryText);
          expect(
            output['status'],
            receipt.status == 'saved'
                ? (skill == 'LogEpisode' ? 'ok' : 'success')
                : receipt.status,
          );
          expect(output['disposition'], receipt.disposition.name);
          expect(output['reviewState'], receipt.reviewState?.name);
          expect(output['created'], receipt.created);
          expect(output['projected'], receipt.projected);
          expect(output['reason'], receipt.reason);
          expect(
            output[skill == 'LogEpisode' ? 'id' : 'episodeId'],
            episode?.id,
          );
          expect(jsonEncode(output), isNot(contains(_memoryText)));
        });
      }

      test('waits for the durable write before returning a receipt', () async {
        final write = Completer<MemoryWriteResult>();
        final bus = _ReceiptMemoryBus(write.future);
        appServices.put<MemoryBus>(bus);
        var completed = false;
        final invocation = _invoke(skill).then((output) {
          completed = true;
          return output;
        });

        await bus.submitted.future;
        expect(completed, isFalse);
        write.complete(
          MemoryWriteResult(
            disposition: MemoryWriteDisposition.accepted,
            episode: bus.proposals.single..id = 41,
            created: true,
            projected: true,
          ),
        );

        final output = await invocation;
        expect(completed, isTrue);
        expect(output['status'], skill == 'LogEpisode' ? 'ok' : 'success');
        expect(output['disposition'], 'accepted');
        expect(output['reviewState'], 'accepted');
      });
    });
  }
}

const _memoryText = '用户决定每周六上午学习陶艺';

const _receipts = <_ReceiptCase>[
  _ReceiptCase(
    label: 'accepted records retain the existing success status',
    disposition: MemoryWriteDisposition.accepted,
    reviewState: EpisodeReviewState.accepted,
    status: 'saved',
    created: true,
    projected: true,
    reason: 'explicit_user_save',
  ),
  _ReceiptCase(
    label: 'quarantined records report pending review instead of success',
    disposition: MemoryWriteDisposition.quarantined,
    reviewState: EpisodeReviewState.pending,
    status: 'pending_review',
    created: true,
    reason: 'automatic_summary_requires_review',
  ),
  _ReceiptCase(
    label: 'rejected writes return a structured receipt without an id',
    disposition: MemoryWriteDisposition.rejected,
    status: 'rejected',
    reason: 'explicit_no_save_request',
  ),
  _ReceiptCase(
    label: 'duplicates of accepted records report unchanged',
    disposition: MemoryWriteDisposition.duplicate,
    reviewState: EpisodeReviewState.accepted,
    status: 'unchanged',
    reason: 'exact_replay',
  ),
  _ReceiptCase(
    label: 'duplicates of pending records still require review',
    disposition: MemoryWriteDisposition.duplicate,
    reviewState: EpisodeReviewState.pending,
    status: 'pending_review',
    reason: 'exact_replay',
  ),
  _ReceiptCase(
    label: 'duplicates of rejected records do not claim memory was saved',
    disposition: MemoryWriteDisposition.duplicate,
    reviewState: EpisodeReviewState.rejected,
    status: 'rejected',
    reason: 'semantic_duplicate',
  ),
  _ReceiptCase(
    label: 'duplicates of deleted records do not claim memory was saved',
    disposition: MemoryWriteDisposition.duplicate,
    reviewState: EpisodeReviewState.tombstoned,
    status: 'rejected',
    reason: 'semantic_duplicate',
  ),
  _ReceiptCase(
    label: 'legacy writes retain their compatible success status',
    disposition: MemoryWriteDisposition.legacy,
    reviewState: EpisodeReviewState.accepted,
    status: 'saved',
    created: true,
    projected: true,
  ),
  _ReceiptCase(
    label: 'shadow writes retain their compatible success status',
    disposition: MemoryWriteDisposition.shadow,
    reviewState: EpisodeReviewState.accepted,
    status: 'saved',
    created: true,
    projected: true,
  ),
];

class _ReceiptCase {
  const _ReceiptCase({
    required this.label,
    required this.disposition,
    required this.status,
    this.reviewState,
    this.created = false,
    this.projected = false,
    this.reason,
  });

  final String label;
  final MemoryWriteDisposition disposition;
  final EpisodeReviewState? reviewState;
  final String status;
  final bool created;
  final bool projected;
  final String? reason;
}

Future<Map<String, dynamic>> _invoke(String skill) async {
  final handler = skill == 'LogEpisode'
      ? LogEpisodeSkill().methods['logEpisode']!
      : MemorySkill().methods['remember']!;
  final output = await Future<dynamic>.sync(
    () => handler(<dynamic>[
      jsonEncode(<String, Object?>{
        skill == 'LogEpisode' ? 'what' : 'fact': _memoryText,
      }),
    ]),
  );
  return jsonDecode(output.toString()) as Map<String, dynamic>;
}

final class _ReceiptMemoryBus extends MemoryBus {
  _ReceiptMemoryBus(this.result);

  final Future<MemoryWriteResult> result;
  final proposals = <Episode>[];
  final submitted = Completer<void>();

  @override
  Future<MemoryWriteResult> writeEpisodeWithResult(Episode episode) {
    proposals.add(episode);
    if (!submitted.isCompleted) submitted.complete();
    return result;
  }
}

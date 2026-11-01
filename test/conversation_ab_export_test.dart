import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:maaso/src/features/agent/application/persona/persona_utterance_decoder.dart';

import '../tool/conversation_ab_export.dart';

void main() {
  test('generated artifacts use the production response decoder', () {
    const decoder = ConversationReplyDecoder();
    expect(
      decoder
          .decode(
            '{"actions":[{"type":"reply.utterance","text":"协议测试。","after":"finish"}],"reply":"协议测试。"}',
          )
          .reply,
      '协议测试。',
    );
    final path = Platform.environment['MAASO_AB_RESULTS_PATH'];
    if (path == null || path.isEmpty) return;
    final file = File(path);
    final bytes = file.readAsBytesSync();
    final results = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    var checked = 0;
    final failures = <Map<String, Object?>>[];
    for (final sample in results['samples'] as List) {
      for (final turn in sample['turns'] as List) {
        if (turn['status'] != 'completed') continue;
        checked++;
        try {
          final decoded = decoder.decode(turn['raw'] as String);
          if (decoded.reply != turn['reply']) {
            throw const FormatException('aggregate_mismatch');
          }
        } catch (_) {
          failures.add({
            'scenarioId': sample['scenarioId'],
            'variant': sample['variant'],
            'turn': turn['index'],
            'code': 'production_decoder_rejected',
          });
        }
      }
    }
    final destination = File(
      '${file.parent.path}/production_protocol_receipt.json',
    );
    destination.writeAsStringSync(
      '${jsonEncode({'schemaVersion': 1, 'source': 'ConversationReplyDecoder', 'resultsSha256': sha256.convert(bytes).toString(), 'checkedTurns': checked, 'failures': failures})}\n',
    );
    expect(failures, isEmpty);
  });
  test(
    'exports all frozen synthetic conditions through current prompt builder',
    () {
      Map<String, Object?> read(String name) =>
          jsonDecode(File('tool/conversation_ab/$name.json').readAsStringSync())
              as Map<String, Object?>;
      final dev = read('corpus_dev');
      final holdout = read('corpus_holdout');
      final scenes = [
        ...(dev['scenarios'] as List),
        ...(holdout['scenarios'] as List),
      ].map((value) => Map<String, Object?>.from(value as Map)).toList();
      expect(scenes, hasLength(90));
      final pack = buildConversationAbPromptPack(
        scenarios: scenes,
        baseline: read('baseline'),
        manifest: read('manifest'),
      );
      final rows = (pack['scenarios'] as List).cast<Map<String, Object?>>();
      for (final row in rows) {
        final requests = row['requests'] as Map;
        expect(
          requests.keys,
          containsAll(['legacy', 'persona_only', 'current']),
        );
        for (final variant in requests.keys) {
          final turns = requests[variant] as List;
          expect(turns, hasLength(2));
          for (final raw in turns) {
            final messages = (raw as List).cast<Map<String, Object?>>();
            expect(messages[1]['content'], contains('Return exactly'));
            expect(row['turns'] as List, contains(messages.last['content']));
            if (row['isPrivate'] == false) {
              final text = jsonEncode(messages);
              expect(text, isNot(contains('私聊专属小海獭')));
              expect(text, isNot(contains('私聊禁称小河狸')));
              for (final canary in row['privateCanaries'] as List) {
                expect(text, isNot(contains(canary)));
              }
            }
          }
        }
        final current = jsonEncode(requests['current']);
        final legacy = jsonEncode(requests['legacy']);
        final label = jsonEncode(requests['persona_only']);
        expect(current, contains('不自动奉承'));
        expect(legacy, isNot(contains('不自动奉承')));
        expect(label, contains('角色标签：年轻、幽默、略微毒舌，会说梗'));
      }
      final destination = Platform.environment['MAASO_AB_EXPORT_PATH'];
      if (destination != null && destination.isNotEmpty) {
        File(destination).writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(pack)}\n',
        );
      }
    },
  );
}

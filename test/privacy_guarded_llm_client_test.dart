import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/privacy_guarded_llm_client.dart';
import 'package:maaso/src/features/agent/data/llm/llm_client.dart';
import 'package:maaso/src/features/agent/data/models/message.dart';

class _Client extends LLMClient {
  int sends = 0;
  @override
  Future<String> chat(List<Message> messages, {Duration? timeout}) async {
    sends++;
    return 'reply';
  }

  @override
  Future<String> generateJson(String prompt, {Duration? timeout}) async {
    sends++;
    return '{}';
  }

  @override
  Future<ChatTurnResult> chatWithTools(
    List<Message> messages,
    List<Map<String, dynamic>> tools, {
    Duration? timeout,
  }) async {
    sends++;
    return ChatTurnResult(content: 'reply', toolCalls: []);
  }
}

class _Presentation extends _Client implements PresentationStreamingLLMClient {
  @override
  Stream<LLMStreamEvent> streamPresentationChatEvents(
    List<Message> messages, {
    Duration? timeout,
  }) async* {
    sends++;
    yield const LLMStreamEvent(event: 'reply.delta', data: 'presentation');
  }
}

void main() {
  test(
    'all operations on a previously resolved client check current permission',
    () async {
      final inner = _Client();
      var allowed = true;
      var checks = 0;
      final client = privacyGuardedLLMClient(inner, () async {
        checks++;
        if (!allowed) throw StateError('permission withdrawn');
      });
      expect(client, isNot(isA<PresentationStreamingLLMClient>()));
      expect(await client.chat([]), 'reply');
      allowed = false;
      await expectLater(client.chat([]), throwsStateError);
      await expectLater(client.generateJson('prompt'), throwsStateError);
      await expectLater(client.chatWithTools([], []), throwsStateError);
      await expectLater(client.streamChat([]).toList(), throwsStateError);
      await expectLater(client.streamChatEvents([]).toList(), throwsStateError);
      expect(checks, 6);
      expect(inner.sends, 1);
    },
  );
  test(
    'presentation capability survives with its own dispatch check',
    () async {
      final inner = _Presentation();
      var allowed = true;
      final client =
          privacyGuardedLLMClient(inner, () async {
                if (!allowed) throw StateError('retired');
              })
              as PresentationStreamingLLMClient;
      expect(
        (await client.streamPresentationChatEvents([]).toList()).single.data,
        'presentation',
      );
      allowed = false;
      await expectLater(
        client.streamPresentationChatEvents([]).toList(),
        throwsStateError,
      );
      expect(inner.sends, 1);
    },
  );
}

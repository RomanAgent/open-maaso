import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/barge_in_self_echo_guard.dart';

void main() {
  const guard = BargeInSelfEchoGuard();

  test('matches a Chinese playback fragment after punctuation is removed', () {
    expect(
      guard.isLikelySelfEcho(
        transcript: '嗯，我想想，猪脚饭？',
        spokenText: '今天呀，嗯，我想想。猪脚饭？',
      ),
      isTrue,
    );
  });

  test('matches a lightly corrupted English playback transcript', () {
    expect(
      guard.isLikelySelfEcho(
        transcript: 'maybe we could get noodle today',
        spokenText: 'Maybe we could get noodles today.',
      ),
      isTrue,
    );
  });

  test('keeps a user interruption that contributes new meaning', () {
    expect(
      guard.isLikelySelfEcho(
        transcript: '昨天刚吃过猪脚饭，我们换一个吧',
        spokenText: '那就吃猪脚饭吧。',
      ),
      isFalse,
    );
    expect(
      guard.isLikelySelfEcho(
        transcript: 'No, I had noodles yesterday. Pick something else.',
        spokenText: 'Maybe we could get noodles today.',
      ),
      isFalse,
    );
  });

  test('leaves short acknowledgements to the backchannel classifier', () {
    for (final transcript in const <String>['', '嗯', 'ok', '对啊']) {
      expect(
        guard.isLikelySelfEcho(transcript: transcript, spokenText: '好的，那我接着说。'),
        isFalse,
        reason: transcript,
      );
    }
  });

  test('does not treat a small shared phrase as sufficient echo evidence', () {
    expect(
      guard.isLikelySelfEcho(
        transcript: '猪脚饭已经吃腻了',
        spokenText: '今天可以试试猪脚饭，附近那家应该还开着。',
      ),
      isFalse,
    );
  });
}

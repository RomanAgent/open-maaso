import 'package:flutter_test/flutter_test.dart';

import 'package:maaso/src/features/agent/application/agent_runtime.dart';

void main() {
  test(
    'projector/bluetooth requests are detected for prompt-detail inclusion',
    () {
      // Without this, the BleYoturetoys/Bluetooth skills stay "compact" (name
      // only) and the model never sees the connect→ask→transfer guidance or the
      // real method names.
      expect(textWantsProjector('连接yoturetoys投影仪并传输图片'), isTrue);
      expect(
        textWantsProjector('project this picture on the projector'),
        isTrue,
      );
      expect(textWantsProjector('connect bluetooth'), isTrue);
      expect(textWantsProjector('投屏一张图'), isTrue);

      // Must NOT over-trigger on unrelated turns (esp. "forecast" contains
      // "cast", which is why "cast" is deliberately not a keyword).
      expect(textWantsProjector('what is the weather forecast'), isFalse);
      expect(textWantsProjector('讲个笑话'), isFalse);
      expect(textWantsProjector('play a game'), isFalse);
    },
  );

  test('projector gallery follow-up keeps projector tool details', () {
    const recentConversation = '''
USER: connect to projector and send a photo to the device
AGENT: All connected! Would you like to send a photo from your gallery, or should I find one online for you?
''';

    expect(
      textWantsProjector('photo', recentConversation: recentConversation),
      isTrue,
    );
    expect(
      textWantsProjector(
        'from gallery',
        recentConversation: recentConversation,
      ),
      isTrue,
    );
    expect(
      textWantsProjector('照片', recentConversation: recentConversation),
      isTrue,
    );
    expect(
      textWantsProjector('帮我找一张小狗的图片', recentConversation: recentConversation),
      isTrue,
    );
    expect(
      textWantsProjector('cat', recentConversation: recentConversation),
      isTrue,
    );
    expect(
      textWantsProjector('silly cat', recentConversation: recentConversation),
      isTrue,
    );
    expect(
      textWantsFreeformSurface('photo', recentConversation: recentConversation),
      isFalse,
    );
    expect(
      textWantsFreeformSurface(
        '帮我找一张小狗的图片',
        recentConversation: recentConversation,
      ),
      isFalse,
    );
  });

  test('ordinary photo album requests still route to surface details', () {
    const recentProjectorConversation = '''
USER: connect to projector and send a photo to the device
AGENT: All connected! Would you like to send a photo from your gallery, or should I find one online for you?
''';

    expect(textWantsFreeformSurface('make me a photo album'), isTrue);
    expect(textWantsFreeformSurface('做个相册'), isTrue);
    expect(
      textWantsProjector(
        'make me a photo album',
        recentConversation: recentProjectorConversation,
      ),
      isFalse,
    );
    expect(
      textWantsFreeformSurface(
        'make me a photo album',
        recentConversation: recentProjectorConversation,
      ),
      isTrue,
    );
  });

  test('ordinary speech command is not treated as an image subject', () {
    const immediateProjectorQuestion = '''
USER: connect projector
AGENT: Connected. Want a photo from your gallery or should I find one online?
''';

    expect(
      textWantsProjector(
        'say hello',
        recentConversation: immediateProjectorQuestion,
      ),
      isFalse,
    );
    expect(
      textWantsProjector('说你好', recentConversation: immediateProjectorQuestion),
      isFalse,
    );
  });

  test('only the latest assistant turn can supply projector context', () {
    const changedTopicConversation = '''
USER: connect projector
AGENT: Connected. Want a photo from your gallery or should I find one online?
USER: tell me a joke
AGENT: Why did the robot cross the road? To recharge on the other side.
''';

    expect(
      textWantsProjector(
        'silly cat',
        recentConversation: changedTopicConversation,
      ),
      isFalse,
    );
    expect(
      textWantsProjector(
        'say hello',
        recentConversation: changedTopicConversation,
      ),
      isFalse,
    );
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/content_engagement/domain/content_engagement.dart';
import 'package:maaso/src/features/content_engagement/domain/public_consumption_hint.dart';

void main() {
  test(
    'public progress hints are bounded and cannot carry financial authority',
    () {
      expect(
        PublicConsumptionHint.parse(
          '{"event":"game_progress","progress":8000}',
          ContentConsumptionKind.game,
        )?.progress,
        8000,
      );
      for (final message in [
        '{"event":"game_progress","progress":10001}',
        '{"event":"game_progress","progress":-1}',
        '{"event":"game_progress","progress":5.5}',
        '{"event":"game_progress","progress":8000,"units":1000}',
        '{"event":"game_progress","progress":8000,"actorKind":"user"}',
        '{"event":"applet_operation"}',
        'not json',
        'x' * 257,
      ]) {
        expect(
          PublicConsumptionHint.parse(message, ContentConsumptionKind.game),
          isNull,
        );
      }
      expect(
        PublicConsumptionHint.parse(
          '{"event":"applet_operation"}',
          ContentConsumptionKind.applet,
        )?.operation,
        isTrue,
      );
      expect(
        PublicConsumptionHint.parse(
          '{"event":"applet_operation","coins":5}',
          ContentConsumptionKind.applet,
        ),
        isNull,
      );
    },
  );
}

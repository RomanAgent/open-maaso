// test/backchannel_classifier_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/backchannel_classifier.dart';

void main() {
  const c = BackchannelClassifier();

  group('backchannel (should resume the agent)', () {
    for (final u in [
      '嗯',
      '嗯嗯',
      '对',
      '对对',
      '好',
      '好的',
      '继续',
      '是的',
      'ok',
      'okay',
      'yeah',
      'mhm',
      'uh-huh',
      'right',
      'go on',
      'I see',
      'got it',
      '  yeah!  ',
      '',
    ]) {
      test('"$u" is a backchannel', () {
        expect(c.classify(u), BackchannelVerdict.backchannel);
      });
    }
  });

  group('interruption (should start a new turn)', () {
    for (final u in [
      '等等，其实我想问别的',
      'no that is wrong',
      'stop, what about the weather',
      '换个话题',
      'actually never mind that',
    ]) {
      test('"$u" is an interruption', () {
        expect(c.classify(u), BackchannelVerdict.interruption);
      });
    }
  });
}

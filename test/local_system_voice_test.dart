import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/local_system_voice.dart';

void main() {
  test(
    'embedded synthesis requires explicit installed non-network voice metadata',
    () {
      final local = {
        'name': 'embedded',
        'locale': 'en-US',
        'network_required': '0',
        'features': '',
      };
      expect(
        embeddedAndroidVoice([
          {...local, 'network_required': '1'},
          {...local, 'network_required': null},
          {...local, 'features': 'notInstalled'},
          {...local, 'locale': 'zh-CN'},
          local,
        ], 'en_US'),
        {'name': 'embedded', 'locale': 'en-US'},
      );
      expect(
        embeddedAndroidVoice([
          {'name': 'unknown', 'locale': 'en-US'},
        ], 'en-US'),
        isNull,
      );
      expect(embeddedAndroidVoice(null, 'en-US'), isNull);
    },
  );
}

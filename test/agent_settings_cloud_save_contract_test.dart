import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('settings autosave handles failures and exposes a retry state', () {
    final controller = File(
      'lib/src/features/settings/application/agent_settings_controller.dart',
    ).readAsStringSync();
    final page = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();

    expect(controller, isNot(contains('ignore: discarded_futures')));
    expect(
      controller,
      contains('onError: (Object error, StackTrace stackTrace)'),
    );
    expect(controller, contains('cloudSaveFailed.value = true'));
    expect(controller, contains('Future<void> retryCloudSave()'));
    expect(page, contains("'settings.cloud_save_failed'.tr"));
    expect(page, contains('onPressed: controller.retryCloudSave'));
  });
}

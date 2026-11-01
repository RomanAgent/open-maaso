import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('GIPHY credential and dependent skill are removed from the app', () {
    final mainSource = File('lib/main.dart').readAsStringSync();
    final settingsSource = File(
      'lib/src/features/settings/presentation/agent_settings_page.dart',
    ).readAsStringSync();
    final settingsControllerSource = File(
      'lib/src/features/settings/application/agent_settings_controller.dart',
    ).readAsStringSync();
    final catalogSource = File(
      'lib/src/features/agent/application/skill_catalog.dart',
    ).readAsStringSync();

    expect(
      mainSource,
      contains("await storage.delete('giphy_api_key');"),
      reason: 'existing encrypted credentials must be deleted on upgrade',
    );
    expect(settingsSource, isNot(contains('settings.giphy_api_key')));
    expect(settingsControllerSource, isNot(contains('giphyKey')));
    expect(catalogSource, isNot(contains("id: 'meme'")));
    expect(File('lib/agent_core/skills/meme_skill.dart').existsSync(), isFalse);

    final librarySource = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .map((file) => file.readAsStringSync())
        .join('\n');
    expect(librarySource, isNot(contains('GIPHY_API_KEY')));
    expect(librarySource, isNot(contains('api.giphy.com')));
    expect(librarySource, isNot(contains('MemeSkill')));
  });
}

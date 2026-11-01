import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';

import 'support/project_source_fixture.dart';

void main() {
  test(
    'native companion guidance stays optional for an uninstrumented game',
    () async {
      final client = SourceFixtureClient(sourceFixtureResponses());
      final result = await GeneratedGameArtifact(
        client: client,
        instruction: 'Make a complete tap game.',
        surfaceId: 'optional-companion',
        zh: false,
      ).generate();
      final surface = result.actions.single['surface'] as Map;
      expect(surface['html'], sourceHtml);
      expect(surface['js'], sourceJs);
      final prompt = client.requests.first.first.content;
      expect(prompt, contains('data-maaso-game-companion'));
      expect(prompt, contains('8KiB wire bound'));
      expect(prompt, contains('metadata is optional'));
      expect(prompt, contains('Do not emit companion.snapshot yourself'));
      expect(prompt, contains(r'\u003c'));
      final manifest = surface['manifest'] as Map;
      expect(manifest['actions'], isEmpty);
      expect((manifest['events'] as List).map((event) => event['name']), [
        'game.state',
        'game.event',
      ]);
    },
  );

  test(
    'optional JSON data survives source assembly without becoming executable',
    () async {
      const description =
          '<script type="application/json" data-maaso-game-companion>'
          '{"version":1,"name":"Tap score","rules":["Tap to earn points"]}</script>';
      final client = SourceFixtureClient([
        jsonEncode(sourcePlan),
        jsonEncode(boundSourceChunk('screen.html', '$description$sourceHtml')),
        jsonEncode(boundSourceChunk('skin.css', sourceCss)),
        jsonEncode(boundSourceChunk('game.js', sourceJs)),
      ]);
      final result = await GeneratedGameArtifact(
        client: client,
        instruction: 'Make a complete tap game.',
        surfaceId: 'described-companion',
        zh: false,
      ).generate();
      final surface = result.actions.single['surface'] as Map;
      expect(surface['html'], contains(description));
      expect(surface['js'], sourceJs);
    },
  );
}

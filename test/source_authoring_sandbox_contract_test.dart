import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/tasks/generated_game_artifact.dart';
import 'package:maaso/src/features/agent/application/tasks/source_workspace.dart';

import 'support/project_source_fixture.dart';

void main() {
  test(
    'generation and repair expose actual browser sandbox rules without reducing the requested game',
    () async {
      const requirement =
          'Make any complex game with all scenes and controls; preserve its complete requested art.';
      final client = SourceFixtureClient([
        ...sourceFixtureResponses(),
        jsonEncode({
          'fileId': 'game.js',
          'baseHash': sourceWorkspaceDigest(sourceJs),
          'edits': [
            {
              'oldText': 'let score=0;',
              'newText': 'let score=0;const repaired=true;',
            },
          ],
        }),
      ]);
      final producer = GeneratedGameArtifact(
        client: client,
        instruction: requirement,
        surfaceId: 'host-owned',
        zh: false,
      );
      final original = await producer.generate();
      final repaired = await producer.repair(
        original,
        'surface worker first frame rejected: runtime_failed',
      );
      expect(client.requests, hasLength(5));
      for (final request in client.requests) {
        expect(request.last.content, requirement);
        final prompt = request.first.content;
        expect(
          prompt,
          contains(
            'directly allowed members, such as document.getElementById and window.addEventListener',
          ),
        );
        expect(
          prompt,
          contains(
            'Never assign the whole window, globalThis, document, self or Object object',
          ),
        );
        expect(
          prompt,
          contains('never capture, alias or rebind DOM query methods'),
        );
        expect(
          prompt,
          contains(
            'Elements\nreturned by a direct document query can be stored',
          ),
        );
        expect(prompt, contains('top or parent for local bindings'));
        expect(
          prompt,
          contains('innerHTML, outerHTML, insertAdjacentHTML or setAttribute'),
        );
        expect(
          prompt,
          contains(
            'prototype/constructor or Object.assign/defineProperty/defineProperties',
          ),
        );
        expect(
          prompt,
          contains(
            'textContent, document.createElement, append,\nreplaceChildren',
          ),
        );
        expect(
          prompt,
          contains('preserve arbitrary gameplay and every requested feature'),
        );
        expect(prompt, contains('Do not simplify the requirement'));
      }
      final before = original.actions.single['surface'] as Map,
          after = repaired.actions.single['surface'] as Map;
      expect(after['html'], before['html']);
      expect(after['css'], before['css']);
      expect(after['manifest'], before['manifest']);
      expect(after['id'], before['id']);
    },
  );
}

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/conversation_policy.dart';
import 'package:maaso/src/core/models/episode.dart';
import 'package:maaso/src/core/models/relationship_state.dart';
import 'package:maaso/src/core/services/relationship_service.dart';
import 'package:maaso/src/features/memory/application/memory_wall_controller.dart';
import 'package:maaso/src/features/relationship/presentation/relationship_hub_page.dart';

import 'helpers/opaque_hub_navigation_probe.dart';

void main() {
  testWidgets('profile and memory wall share the evidence-based stage', (
    tester,
  ) async {
    await appServices.reset();
    addTearDown(appServices.reset);
    final relationship = appServices.put(RelationshipService());
    relationship.state.value = RelationshipState(
      firstMetAt: DateTime(2020, 1, 1),
      stage: RelationshipStage.attuned,
      score: 500,
    );
    appServices.put(MemoryWallController());
    await tester.pumpWidget(
      const MaterialApp(
        home: RelationshipHubPage(
          initialSection: RelationshipHubSection.profile,
        ),
      ),
    );
    expect(
      find.text(RelationshipExpressionStage.newlyMet.promptLabel()),
      findsOneWidget,
    );
    expect(find.text(RelationshipStage.attuned.labelKey.tr), findsNothing);
    relationship.updateConversationPolicy(
      ConversationPolicy.fromFacts([
        for (var id = 1; id <= 2; id++)
          ConversationFact(
            draft: ConversationFactDraft.sharedContext(
              contextKey: 'context-$id',
              label: '共同话题 $id',
              evidenceKind: ConversationEvidenceKind.confirmedContinuation,
            ),
            episodeId: id,
            revision: 1,
            sourceRefs: [
              EpisodeSourceRef(
                sourceId: 'chat_message:$id',
                sessionId: 'session-$id',
                origin: EpisodeSourceOrigin.user,
                contentHash: '$id'.padLeft(64, '0'),
              ),
            ],
          ),
      ], policyVersion: 1),
    );
    await tester.pump();
    expect(
      find.text(RelationshipExpressionStage.familiar.promptLabel()),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const ValueKey<String>('relationship-hub-memories')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text(RelationshipExpressionStage.familiar.promptLabel()),
      findsOneWidget,
    );
    relationship.updateConversationPolicy(
      ConversationPolicy.fromFacts(const [], policyVersion: 2),
    );
    await tester.pump();
    expect(
      find.text(RelationshipExpressionStage.newlyMet.promptLabel()),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final reduceMotion in <bool>[false, true]) {
      for (final size in <Size>[const Size(375, 667), const Size(667, 375)]) {
        testWidgets(
          'relationship tabs stay opaque: $brightness reduced=$reduceMotion $size',
          (tester) => verifyOpaqueHubNavigation(
            tester,
            brightness: brightness,
            reduceMotion: reduceMotion,
            size: size,
            paneNames: RelationshipHubSection.values
                .map((section) => section.name)
                .toList(),
            destinationKeys: const <String>[
              'relationship-hub-profile',
              'relationship-hub-moments',
              'relationship-hub-memories',
            ],
            buildHub: (pane) => RelationshipHubPage(
              initialSection: RelationshipHubSection.profile,
              sectionBuilders: {
                for (final section in RelationshipHubSection.values)
                  section: (_) => pane(section.name),
              },
            ),
          ),
        );
      }
    }
  }

  testWidgets('relationship hub builds only the selected section', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(667, 375);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final builds = <RelationshipHubSection, int>{};

    Widget section(RelationshipHubSection value) {
      builds[value] = (builds[value] ?? 0) + 1;
      return Center(child: Text('${value.name}-pane'));
    }

    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: RelationshipHubPage(
            initialSection: RelationshipHubSection.moments,
            sectionBuilders: {
              for (final value in RelationshipHubSection.values)
                value: (_) => section(value),
            },
          ),
        ),
      ),
    );

    expect(find.text('moments-pane'), findsOneWidget);
    expect(builds[RelationshipHubSection.moments], 1);
    expect(builds[RelationshipHubSection.profile], isNull);
    expect(builds[RelationshipHubSection.memories], isNull);

    await tester.tap(
      find.byKey(const ValueKey<String>('relationship-hub-profile')),
    );
    await tester.pumpAndSettle();

    expect(find.text('profile-pane'), findsOneWidget);
    expect(find.text('moments-pane'), findsNothing);
    expect(builds[RelationshipHubSection.profile], 1);
    expect(builds[RelationshipHubSection.memories], isNull);
    expect(tester.takeException(), isNull);
  });
}

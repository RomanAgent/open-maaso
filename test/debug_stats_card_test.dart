import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('debug stats service exposes model and storage groups', () {
    final source = File(
      'lib/src/core/services/debug_stats_service.dart',
    ).readAsStringSync();

    expect(source, contains("'model_rows'"));
    expect(source, contains("'storage_rows'"));
    expect(source, contains('SherpaModelRegistry.supertonicTts'));
    expect(source, isNot(contains('asrModelForEngine')));
    expect(source, contains('SherpaModelRegistry.sileroVad'));
    expect(source, contains("'DB'"));
    expect(source, contains('maaso.db'));
    expect(source, contains("'Secure storage'"));
  });

  test('debug stats card uses grouped sections and icon close', () {
    final source = File(
      'lib/src/core/widgets/agent_cards.dart',
    ).readAsStringSync();
    final debugBuilder = source.substring(
      source.indexOf('static AgentCard _buildDebugStats'),
      source.indexOf('// ─────────────────────── confirm_name body'),
    );

    expect(debugBuilder, contains('onClose'));
    expect(debugBuilder, isNot(contains("backLabel: 'common.close'")));
    expect(source, contains('Icons.close_rounded'));
    expect(source, contains('card.debug_models'));
    expect(source, contains('card.debug_storage'));
    expect(source, contains('card.debug_runtime'));
  });
}

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source = File(
    'lib/src/features/home/application/home_controller.dart',
  ).readAsStringSync();

  test('startup-only Home chats use the system turn origin', () {
    final startupGreeting = _between(
      source,
      'Future<void> _maybeStartupGreeting()',
      'bool _hasCallableStartupModel()',
    );
    final soulInterview = _between(
      source,
      'Future<void> _maybeBootstrapSoulInterview()',
      'void _onThought(',
    );

    for (final method in <String>[startupGreeting, soulInterview]) {
      expect(method, contains('runtime.chat('));
      expect(method, contains('origin: TurnOrigin.system'));
    }
  });
}

String _between(String source, String startMarker, String endMarker) {
  final start = source.indexOf(startMarker);
  final end = source.indexOf(endMarker, start + startMarker.length);
  expect(start, isNonNegative, reason: 'missing $startMarker');
  expect(end, greaterThan(start), reason: 'missing $endMarker');
  return source.substring(start, end);
}

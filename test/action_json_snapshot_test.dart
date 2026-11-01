import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/features/agent/application/action/action_json_snapshot.dart';

void main() {
  group('snapshotActionJson', () {
    test('recursively freezes the exact JSON value', () {
      final nested = <String, Object?>{'value': 'before'};
      final source = <String, Object?>{
        'nested': nested,
        'items': <Object?>[
          <String, Object?>{'enabled': true},
        ],
      };

      final snapshot = snapshotActionJson(source) as Map<String, Object?>;
      nested['value'] = 'after';
      (source['items']! as List).add('mutated');

      expect(snapshot['nested'], <String, Object?>{'value': 'before'});
      expect(snapshot['items'], <Object?>[
        <String, Object?>{'enabled': true},
      ]);
      expect(() => snapshot['extra'] = true, throwsUnsupportedError);
      expect(
        () => (snapshot['nested']! as Map)['value'] = 'changed',
        throwsUnsupportedError,
      );
      expect(
        () => (snapshot['items']! as List).add('changed'),
        throwsUnsupportedError,
      );
    });

    test('fails closed for cycles, unsupported values, and limits', () {
      final cyclic = <Object?>[];
      cyclic.add(cyclic);
      final cases = <void Function()>[
        () => snapshotActionJson(cyclic),
        () => snapshotActionJson(DateTime.utc(2026)),
        () => snapshotActionJson(<Object?, Object?>{1: 'bad key'}),
        () => snapshotActionJson(double.nan),
        () => snapshotActionJson(<Object?>[1, 2], maxNodes: 2),
        () => snapshotActionJson(<Object?>[
          <Object?>[
            <Object?>['deep'],
          ],
        ], maxDepth: 1),
        () => snapshotActionJson('secret', maxStringRunes: 3),
      ];

      for (final attempt in cases) {
        expect(attempt, throwsA(isA<ActionJsonSnapshotException>()));
      }
    });

    test('validation failures never render rejected content', () {
      const secret = 'private exact text';

      try {
        snapshotActionJson(secret, maxStringRunes: 1);
        fail('oversized content must fail closed');
      } on ActionJsonSnapshotException catch (error) {
        expect(error.toString(), isNot(contains(secret)));
        expect(error.code, 'string_too_long');
      }
    });
  });
}

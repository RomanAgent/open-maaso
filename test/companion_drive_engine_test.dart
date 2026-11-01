import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/companion_drive_engine.dart';

void main() {
  test('unit signals fail closed and stay in the closed unit interval', () {
    expect(UnitSignal.clamped(double.nan), UnitSignal.zero);
    expect(UnitSignal.clamped(double.infinity), UnitSignal.zero);
    expect(UnitSignal.clamped(double.negativeInfinity), UnitSignal.zero);
    expect(
      UnitSignal.clamped(double.nan, fallback: 0.4).value,
      closeTo(0.4, 1e-12),
    );
    expect(UnitSignal.clamped(-2), UnitSignal.zero);
    expect(UnitSignal.clamped(3), UnitSignal.one);
  });

  test('drive projection is deterministic and bounds every axis', () {
    const engine = CompanionDriveEngine();
    final inputs = <CompanionDriveSignals>[
      _signals(),
      _signals(
        silence: 1,
        energy: 1,
        engagement: 1,
        positive: 1,
        negative: 1,
        activation: 1,
        selfFocus: 1,
        restraint: 1,
        resting: 1,
        attendingUser: 1,
      ),
      _signals(
        silence: -100,
        energy: 100,
        engagement: double.nan,
        positive: double.infinity,
        negative: double.negativeInfinity,
        activation: 3,
        selfFocus: -3,
        restraint: 9,
        resting: -9,
        attendingUser: 4,
      ),
    ];

    for (final input in inputs) {
      final first = engine.evaluate(input);
      final second = engine.evaluate(input);
      final firstValues = _values(first);
      final secondValues = _values(second);

      expect(secondValues, firstValues);
      for (final value in firstValues) {
        expect(value, inInclusiveRange(0.0, 1.0));
        expect(value.isFinite, isTrue);
      }
    }
  });

  test('more interaction silence monotonically raises connection need', () {
    const engine = CompanionDriveEngine();
    final low = engine.evaluate(_signals(silence: 0.1));
    final medium = engine.evaluate(_signals(silence: 0.5));
    final high = engine.evaluate(_signals(silence: 0.9));

    expect(low.connectionNeed.value, lessThan(medium.connectionNeed.value));
    expect(medium.connectionNeed.value, lessThan(high.connectionNeed.value));
  });
}

CompanionDriveSignals _signals({
  num silence = 0.5,
  num energy = 0.5,
  num engagement = 0.5,
  num positive = 0.5,
  num negative = 0.5,
  num activation = 0.5,
  num selfFocus = 0.5,
  num restraint = 0.5,
  num resting = 0,
  num attendingUser = 0,
}) => CompanionDriveSignals(
  interactionSilence: UnitSignal.clamped(silence),
  energy: UnitSignal.clamped(energy),
  engagement: UnitSignal.clamped(engagement),
  positiveAffect: UnitSignal.clamped(positive),
  negativeAffect: UnitSignal.clamped(negative),
  activation: UnitSignal.clamped(activation),
  selfFocus: UnitSignal.clamped(selfFocus),
  defensiveRestraint: UnitSignal.clamped(restraint),
  resting: UnitSignal.clamped(resting),
  attendingUser: UnitSignal.clamped(attendingUser),
);

List<double> _values(CompanionDriveSnapshot snapshot) => <double>[
  snapshot.connectionNeed.value,
  snapshot.valence.value,
  snapshot.arousal.value,
  snapshot.immersion.value,
  snapshot.pride.value,
];

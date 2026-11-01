import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/gaze_director.dart';
import 'package:maaso/src/features/agent/application/avatar/avatar_runtime.dart';

/// Records what the director writes, so arbitration can be tested without a
/// renderer view.
class _FakeSink implements GazeSink {
  Map<String, double>? lastDrive;
  List<String>? lastRelease;
  int driveCount = 0;
  int releaseCount = 0;

  @override
  void drive(Map<String, double> params) {
    lastDrive = params;
    driveCount++;
  }

  @override
  void release(List<String> params) {
    lastRelease = params;
    releaseCount++;
  }
}

Rect _boxCentered(double cx, double cy, {double size = 20}) =>
    Rect.fromCenter(center: Offset(cx, cy), width: size, height: size);

void main() {
  group('faceToGaze', () {
    const frame = Size(100, 100);

    test('a centred face looks straight ahead', () {
      final g = faceToGaze(boundingBox: _boxCentered(50, 50), frameSize: frame);
      expect(g.eye.dx, closeTo(0, 1e-9));
      expect(g.eye.dy, closeTo(0, 1e-9));
      expect(g.head.dx, closeTo(0, 1e-9));
      expect(g.head.dy, closeTo(0, 1e-9));
    });

    test('mirror flips the horizontal axis', () {
      final right = faceToGaze(
        boundingBox: _boxCentered(90, 50),
        frameSize: frame,
      );
      final rightNoMirror = faceToGaze(
        boundingBox: _boxCentered(90, 50),
        frameSize: frame,
        mirror: false,
      );
      // A face on the right of the (mirrored) frame and the same face with
      // mirroring off must drive opposite horizontal directions.
      expect(right.eye.dx.sign, equals(-rightNoMirror.eye.dx.sign));
      expect(right.eye.dx, isNot(closeTo(0, 0.1)));
    });

    test('a face high in the frame looks up (positive eye.dy)', () {
      final high = faceToGaze(
        boundingBox: _boxCentered(50, 10),
        frameSize: frame,
      );
      expect(high.eye.dy, greaterThan(0));
    });

    test('output stays clamped to -1..1 at the edges', () {
      final corner = faceToGaze(
        boundingBox: _boxCentered(0, 0),
        frameSize: frame,
        eulerY: 90,
        eulerX: 90,
      );
      for (final v in [
        corner.eye.dx,
        corner.eye.dy,
        corner.head.dx,
        corner.head.dy,
      ]) {
        expect(v, inInclusiveRange(-1.0, 1.0));
      }
    });

    test('head pose adds a (small) mirror term beyond pure position', () {
      final box = _boxCentered(50, 50);
      final noPose = faceToGaze(boundingBox: box, frameSize: frame);
      final yawed = faceToGaze(boundingBox: box, frameSize: frame, eulerY: 30);
      // Centred face → position term is 0, so any head.dx difference is the
      // pose-mirror contribution.
      expect(noPose.head.dx, closeTo(0, 1e-9));
      expect(yawed.head.dx.abs(), greaterThan(0));
    });
  });

  group('GazeDirector arbitration', () {
    test('face beats window', () {
      final sink = _FakeSink();
      final d = GazeDirector(sink: sink);

      d.setWindowGaze(const Offset(0.2, 0.2));
      expect(sink.lastDrive!['ParamEyeBallX'], closeTo(0.2 * 1.0, 1e-9));

      d.setFaceGaze(const GazeFrame(eye: Offset(1, 0), head: Offset(1, 0)));
      // Face now wins: eyeball reflects the face frame, not the window.
      expect(sink.lastDrive!['ParamEyeBallX'], closeTo(1 * 1.0, 1e-9));
    });

    test('dropping the face falls back to the window', () {
      final sink = _FakeSink();
      final d = GazeDirector(sink: sink);

      d.setWindowGaze(const Offset(0.5, 0.5));
      d.setFaceGaze(const GazeFrame(eye: Offset(1, 1), head: Offset(1, 1)));
      d.setFaceGaze(null);

      // Back to the window target, not released.
      expect(sink.lastDrive!['ParamEyeBallX'], closeTo(0.5 * 1.0, 1e-9));
      expect(sink.releaseCount, 0);
    });

    test('desktop pointer wins while the independent pet is visible', () {
      final sink = _FakeSink();
      final d = GazeDirector(sink: sink);

      d.setFaceGaze(const GazeFrame(eye: Offset(0.2, 0), head: Offset(0.2, 0)));
      d.setDesktopPointerGaze(const Offset(0.8, -0.5));

      // Desktop eyes lead the head and clamp at their normalized travel limit,
      // so cursor following remains visible at the compact desktop-pet size.
      expect(sink.lastDrive!['ParamEyeBallX'], closeTo(1.0, 1e-9));
      expect(sink.lastDrive!['ParamEyeBallY'], closeTo(-0.53125, 1e-9));
      expect(sink.lastDrive!['ParamAngleX'], closeTo(14.88, 1e-9));
      expect(sink.lastDrive!['ParamAngleY'], closeTo(-7.92, 1e-9));
      expect(
        sink.lastDrive!['ParamAngleZ'],
        closeTo(0, 1e-9),
        reason: 'cursor tracking should turn/nod the head, never tilt it',
      );

      d.setDesktopPointerGaze(null);
      expect(sink.lastDrive!['ParamEyeBallX'], closeTo(0.2, 1e-9));
      expect(sink.releaseCount, 0);
    });

    test('behavior lease wins and carries roll plus upper-body gaze', () {
      final sink = _FakeSink();
      final d = GazeDirector(sink: sink);

      d.setDesktopPointerGaze(const Offset(0.8, -0.5));
      d.holdBehaviorGaze(
        const AvatarGaze(
          eyeX: -0.7,
          eyeY: 0.4,
          headX: -0.5,
          headY: 0.3,
          headRoll: 0.4,
          upperBodyX: -0.3,
        ),
        duration: const Duration(seconds: 1),
      );

      expect(sink.lastDrive!['ParamEyeBallX'], closeTo(-0.7, 1e-9));
      expect(sink.lastDrive!['ParamAngleX'], closeTo(-15, 1e-9));
      expect(sink.lastDrive!['ParamAngleZ'], closeTo(12, 1e-9));
      expect(sink.lastDrive!['ParamBodyAngleX'], closeTo(-3, 1e-9));

      d.onClose();
    });

    testWidgets('an old lease timer cannot clear its replacement', (
      tester,
    ) async {
      final sink = _FakeSink();
      final d = GazeDirector(sink: sink);
      d.setWindowGaze(const Offset(0.2, 0));

      d.holdBehaviorGaze(
        const AvatarGaze(eyeX: -0.6, eyeY: 0, headX: -0.4, headY: 0),
        duration: const Duration(milliseconds: 100),
      );
      await tester.pump(const Duration(milliseconds: 50));
      d.holdBehaviorGaze(
        const AvatarGaze(eyeX: 0.9, eyeY: 0, headX: 0.7, headY: 0),
        duration: const Duration(milliseconds: 200),
      );

      await tester.pump(const Duration(milliseconds: 60));
      expect(sink.lastDrive!['ParamEyeBallX'], closeTo(0.9, 1e-9));
      expect(sink.releaseCount, 0);

      await tester.pump(const Duration(milliseconds: 140));
      expect(sink.lastDrive!['ParamEyeBallX'], closeTo(0.2, 1e-9));
      expect(sink.releaseCount, 0);
      d.onClose();
    });

    testWidgets('lease expiry restores the newest ambient winner', (
      tester,
    ) async {
      final sink = _FakeSink();
      final d = GazeDirector(sink: sink);
      d.setFaceGaze(const GazeFrame(eye: Offset(0.2, 0), head: Offset(0.2, 0)));
      d.holdBehaviorGaze(
        const AvatarGaze(eyeX: -0.8, eyeY: 0, headX: -0.5, headY: 0),
        duration: const Duration(milliseconds: 100),
      );

      d.setDesktopPointerGaze(const Offset(0.5, 0));
      expect(sink.lastDrive!['ParamEyeBallX'], closeTo(-0.8, 1e-9));

      await tester.pump(const Duration(milliseconds: 100));
      expect(sink.lastDrive!['ParamEyeBallX'], closeTo(0.7, 1e-9));
      expect(sink.releaseCount, 0);
      d.onClose();
    });

    test('releasing both sources hands all params back to idle once', () {
      final sink = _FakeSink();
      final d = GazeDirector(sink: sink);

      d.setFaceGaze(const GazeFrame(eye: Offset(1, 0), head: Offset(1, 0)));
      d.setFaceGaze(null);

      expect(sink.releaseCount, 1);
      expect(sink.lastRelease, equals(GazeDirector.driveParams));
      expect(sink.lastRelease!.length, 6);

      // Releasing again with nothing active must not spam clearOverride.
      d.setWindowGaze(null);
      expect(sink.releaseCount, 1);
    });
  });
}

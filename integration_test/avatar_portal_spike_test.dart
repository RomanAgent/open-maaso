import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as image;
import 'package:integration_test/integration_test.dart';

const _unityChannel = MethodChannel('maaso/unity_avatar');
const _portalChannel = MethodChannel('maaso/avatar_portal');
const _backgroundColor = Color(0xFFFF00FF);
const _cycleCount = 20;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'physical device reuses one Unity Avatar through a zero-copy portal',
    (tester) async {
      expect(Platform.isIOS || Platform.isAndroid, isTrue);

      final unityReady = Completer<void>();
      final firstFrames = <int, Completer<Map<Object?, Object?>>>{};
      final portalStages = <String>[];
      final unexpectedEvents = <Object?>[];
      final texture = ValueNotifier<_PortalTexture?>(null);
      addTearDown(texture.dispose);

      _unityChannel.setMethodCallHandler((call) async {
        if (call.method == 'ready' && !unityReady.isCompleted) {
          unityReady.complete();
        }
        return null;
      });
      _portalChannel.setMethodCallHandler((call) async {
        if (call.method != 'event' || call.arguments is! Map) {
          unexpectedEvents.add(call.arguments);
          return null;
        }
        final event = Map<Object?, Object?>.from(call.arguments as Map);
        final generation = event['generation'];
        final type = event['type'];
        if (type is String && generation is int) {
          portalStages.add('$generation:$type');
        }
        if (type == 'firstFrame' && generation is int) {
          final waiter = firstFrames[generation];
          if (waiter != null && !waiter.isCompleted) {
            waiter.complete(event);
          }
        }
        return null;
      });
      addTearDown(() async {
        final active = texture.value;
        if (active != null) {
          await _portalChannel.invokeMethod<void>('release', {
            'generation': active.generation,
          });
        }
        _portalChannel.setMethodCallHandler(null);
        _unityChannel.setMethodCallHandler(null);
      });

      await tester.pumpWidget(_PortalSpikeApp(texture: texture));
      await _unityChannel.invokeMethod<void>('prepareView');
      await unityReady.future.timeout(
        const Duration(seconds: 45),
        onTimeout: () => throw TimeoutException(
          'The existing Unity Avatar runtime did not report ready.',
        ),
      );

      final firstFrameLatencies = <Duration>[];
      for (var generation = 1; generation <= _cycleCount; generation++) {
        final firstFrame = Completer<Map<Object?, Object?>>();
        firstFrames[generation] = firstFrame;
        final stopwatch = Stopwatch()..start();
        final rawLease = await _portalChannel.invokeMapMethod<Object?, Object?>(
          'acquire',
          {'generation': generation, 'profile': 'compactHigh'},
        );
        final lease = _PortalTexture.fromMap(rawLease, generation: generation);
        texture.value = lease;
        await tester.pump();

        final event = await firstFrame.future.timeout(
          const Duration(seconds: 3),
          onTimeout: () => throw TimeoutException(
            'Avatar portal generation $generation produced no first frame. '
            'Stages: ${portalStages.where((value) => value.startsWith('$generation:')).join(', ')}',
          ),
        );
        stopwatch.stop();
        firstFrameLatencies.add(stopwatch.elapsed);
        expect(event['generation'], generation);
        expect(event['textureId'], lease.textureId);
        expect(event['width'], lease.width);
        expect(event['height'], lease.height);
        expect(lease.width, 320);
        expect(lease.height, 560);

        await tester.pump(const Duration(milliseconds: 120));
        if (generation < _cycleCount) {
          await _portalChannel.invokeMethod<void>('release', {
            'generation': generation,
          });
          texture.value = null;
          await tester.pump(const Duration(milliseconds: 80));
        }
      }

      final cold = firstFrameLatencies.first;
      final warm = firstFrameLatencies.skip(1).toList()..sort();
      final warmP95 =
          warm[((warm.length * 0.95).ceil() - 1).clamp(0, warm.length - 1)];
      debugPrint(
        '[AvatarPortalSpike] cycles=$_cycleCount '
        'coldMs=${cold.inMilliseconds} warmP95Ms=${warmP95.inMilliseconds} '
        'warmMs=${warm.map((value) => value.inMilliseconds).join(',')}',
      );

      expect(cold, lessThanOrEqualTo(const Duration(milliseconds: 2500)));
      expect(warmP95, lessThanOrEqualTo(const Duration(milliseconds: 400)));
      expect(unexpectedEvents, isEmpty);

      if (Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
        await tester.pump();
      }
      final screenshot = await binding.takeScreenshot(
        'avatar-portal-${Platform.operatingSystem}-cycle-20',
      );
      expect(screenshot.length, greaterThan(4096));
      final screenshotBytes = Uint8List.fromList(screenshot);
      _expectPortalContainsRenderedPixels(screenshotBytes);
      _expectPortalDoesNotSwapRedAndBlue(screenshotBytes);

      await _portalChannel.invokeMethod<void>('release', {
        'generation': _cycleCount,
      });
      texture.value = null;
      await tester.pump(const Duration(milliseconds: 120));
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

void _expectPortalDoesNotSwapRedAndBlue(Uint8List pngBytes) {
  final screenshot = image.decodePng(pngBytes);
  expect(screenshot, isNotNull);
  final decoded = screenshot!;
  var sampled = 0;
  var redMinusBlue = 0;
  var redDominant = 0;
  var blueDominant = 0;
  final minX = (decoded.width * 0.42).round();
  final maxX = (decoded.width * 0.58).round();
  final minY = (decoded.height * 0.38).round();
  final maxY = (decoded.height * 0.64).round();
  for (var y = minY; y < maxY; y += 2) {
    for (var x = minX; x < maxX; x += 2) {
      final pixel = decoded.getPixel(x, y);
      final red = pixel.r.toInt();
      final green = pixel.g.toInt();
      final blue = pixel.b.toInt();
      final backgroundDistance =
          (red - _backgroundColor.r * 255).abs() +
          (green - _backgroundColor.g * 255).abs() +
          (blue - _backgroundColor.b * 255).abs();
      if (backgroundDistance <= 60 ||
          math.max(red, math.max(green, blue)) < 96) {
        continue;
      }
      sampled++;
      redMinusBlue += red - blue;
      if (red - blue >= 18) redDominant++;
      if (blue - red >= 18) blueDominant++;
    }
  }
  expect(sampled, greaterThan(40));
  final meanRedMinusBlue = redMinusBlue / sampled;
  debugPrint(
    '[AvatarPortalSpike] colorSamples=$sampled '
    'meanRedMinusBlue=${meanRedMinusBlue.toStringAsFixed(2)} '
    'redDominant=$redDominant blueDominant=$blueDominant',
  );
  expect(
    meanRedMinusBlue,
    greaterThanOrEqualTo(-4),
    reason:
        'The rendered Avatar is blue-skewed, which indicates that an RGBA '
        'Unity texture was copied into a BGRA Flutter texture without GPU '
        'format conversion.',
  );
  expect(
    blueDominant,
    lessThan(redDominant * 2 + 24),
    reason: 'Blue-dominant Avatar pixels substantially outnumber warm pixels.',
  );
}

void _expectPortalContainsRenderedPixels(Uint8List pngBytes) {
  final screenshot = image.decodePng(pngBytes);
  expect(screenshot, isNotNull);
  final decoded = screenshot!;
  var sampled = 0;
  var nonBackground = 0;
  final minX = (decoded.width * 0.42).round();
  final maxX = (decoded.width * 0.58).round();
  final minY = (decoded.height * 0.38).round();
  final maxY = (decoded.height * 0.64).round();
  for (var y = minY; y < maxY; y += 3) {
    for (var x = minX; x < maxX; x += 3) {
      final pixel = decoded.getPixel(x, y);
      sampled++;
      final distance =
          (pixel.r.toInt() - _backgroundColor.r * 255).abs() +
          (pixel.g.toInt() - _backgroundColor.g * 255).abs() +
          (pixel.b.toInt() - _backgroundColor.b * 255).abs();
      if (distance > 60) {
        nonBackground++;
      }
    }
  }
  expect(sampled, greaterThan(0));
  expect(
    nonBackground / sampled,
    greaterThan(0.02),
    reason:
        'The composed portal area was indistinguishable from its '
        'transparent magenta background.',
  );
}

final class _PortalTexture {
  const _PortalTexture({
    required this.textureId,
    required this.width,
    required this.height,
    required this.generation,
  });

  factory _PortalTexture.fromMap(
    Map<Object?, Object?>? raw, {
    required int generation,
  }) {
    if (raw == null ||
        raw['textureId'] is! int ||
        raw['width'] is! int ||
        raw['height'] is! int ||
        raw['generation'] != generation) {
      throw StateError('Invalid Avatar portal lease: $raw');
    }
    return _PortalTexture(
      textureId: raw['textureId']! as int,
      width: raw['width']! as int,
      height: raw['height']! as int,
      generation: generation,
    );
  }

  final int textureId;
  final int width;
  final int height;
  final int generation;
}

final class _PortalSpikeApp extends StatelessWidget {
  const _PortalSpikeApp({required this.texture});

  final ValueNotifier<_PortalTexture?> texture;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: ColoredBox(
        color: _backgroundColor,
        child: Center(
          child: ValueListenableBuilder<_PortalTexture?>(
            valueListenable: texture,
            builder: (context, lease, _) {
              return SizedBox(
                width: 160,
                height: 280,
                child: lease == null
                    ? const SizedBox.shrink()
                    : Texture(
                        textureId: lease.textureId,
                        filterQuality: FilterQuality.medium,
                      ),
              );
            },
          ),
        ),
      ),
    );
  }
}

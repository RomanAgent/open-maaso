import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import 'package:maaso/src/features/chat/data/chat_video_native.dart';

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getTemporaryPath() async => path;
}

class _Video extends VideoPlayerPlatform {
  final files = <File>[];
  final streams = <StreamController<VideoEvent>>[];
  bool fail = false;
  @override
  Future<void> init() async {}
  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    files.add(File.fromUri(Uri.parse(options.dataSource.uri!)));
    final stream = StreamController<VideoEvent>();
    streams.add(stream);
    if (fail) {
      stream.addError(
        PlatformException(code: 'bad-video', message: 'Invalid video fixture'),
      );
    } else {
      stream.add(
        VideoEvent(
          eventType: VideoEventType.initialized,
          duration: const Duration(seconds: 1),
          size: const Size(100, 100),
        ),
      );
    }
    return streams.length - 1;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) => streams[playerId].stream;
  @override
  Future<void> dispose(int playerId) async {
    await streams[playerId].close();
  }

  @override
  Future<void> setLooping(int playerId, bool looping) async {}
  @override
  Future<void> setVolume(int playerId, double volume) async {}
  @override
  Future<void> pause(int playerId) async {}
  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late _Video platform;
  late PathProviderPlatform oldPaths;
  late VideoPlayerPlatform oldVideo;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('maaso-video-test-');
    oldPaths = PathProviderPlatform.instance;
    oldVideo = VideoPlayerPlatform.instance;
    PathProviderPlatform.instance = _Paths(root.path);
    platform = _Video();
    VideoPlayerPlatform.instance = platform;
  });
  tearDown(() async {
    PathProviderPlatform.instance = oldPaths;
    VideoPlayerPlatform.instance = oldVideo;
    await root.delete(recursive: true);
  });
  test(
    'identical clips have independently owned playback files and delete on disposal',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final first = await createChatVideo(bytes, 'video/mp4');
      final second = await createChatVideo(bytes, 'video/mp4');
      expect(platform.files[0].path, isNot(platform.files[1].path));
      await first.dispose();
      expect(await platform.files[0].exists(), isFalse);
      expect(await platform.files[1].readAsBytes(), bytes);
      await second.dispose();
      expect(await root.list().toList(), isEmpty);
    },
  );
  test('failed initialization cleans temporary media', () async {
    platform.fail = true;
    await expectLater(
      createChatVideo(Uint8List.fromList([1]), 'video/quicktime'),
      throwsA(isA<PlatformException>()),
    );
    expect(await root.list().toList(), isEmpty);
  });
}

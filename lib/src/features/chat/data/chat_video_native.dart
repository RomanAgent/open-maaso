import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_kit.dart';
import 'package:ffmpeg_kit_flutter_new_min/ffmpeg_session.dart';
import 'package:ffmpeg_kit_flutter_new_min/return_code.dart';

Future<File> _videoFile(Uint8List bytes, String mime) async {
  final root = await getTemporaryDirectory();
  final dir = await root.createTemp('maaso-chat-video-');
  final suffix = mime == 'video/quicktime' ? 'mov' : 'mp4';
  final file = File('${dir.path}/media.$suffix');
  try {
    await file.writeAsBytes(bytes, flush: true);
    return file;
  } catch (_) {
    await dir.delete(recursive: true);
    rethrow;
  }
}

Future<VideoPlayerController> createChatVideo(
  Uint8List bytes,
  String mime,
) async {
  final file = await _videoFile(bytes, mime);
  final controller = _PrivateChatVideoController(file);
  try {
    await controller.initialize().timeout(const Duration(seconds: 12));
  } catch (_) {
    await controller.dispose();
    rethrow;
  }
  return controller;
}

class _PrivateChatVideoController extends VideoPlayerController {
  _PrivateChatVideoController(this.file) : super.file(file);
  final File file;
  @override
  Future<void> dispose() async {
    try {
      await super.dispose();
    } finally {
      if (await file.parent.exists()) await file.parent.delete(recursive: true);
    }
  }
}

Future<Uint8List?> chatVideoThumbnail(Uint8List bytes, String mime) async {
  if (!Platform.isIOS && !Platform.isAndroid && !Platform.isMacOS) return null;
  final input = await _videoFile(bytes, mime);
  final output = File('${input.path}.jpg');
  FFmpegSession? session;
  try {
    final completed = Completer<FFmpegSession>();
    session = await FFmpegKit.executeWithArgumentsAsync(
      [
        '-y',
        '-loglevel',
        'error',
        '-i',
        input.path,
        '-frames:v',
        '1',
        '-vf',
        'scale=240:240:force_original_aspect_ratio=decrease',
        output.path,
      ],
      (value) {
        if (!completed.isCompleted) completed.complete(value);
      },
    );
    final result = await completed.future.timeout(const Duration(seconds: 12));
    if (!ReturnCode.isSuccess(await result.getReturnCode()) ||
        !await output.exists()) {
      return null;
    }
    return await output.readAsBytes();
  } catch (_) {
    await session?.cancel();
    return null;
  } finally {
    if (await input.parent.exists()) {
      await input.parent.delete(recursive: true);
    }
  }
}

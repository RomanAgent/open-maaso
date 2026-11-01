import 'dart:typed_data';
import 'package:video_player/video_player.dart';

Future<VideoPlayerController> createChatVideo(
  Uint8List bytes,
  String mime,
) async {
  final uri = Uri.dataFromBytes(bytes, mimeType: mime);
  final controller = VideoPlayerController.networkUrl(uri);
  try {
    await controller.initialize().timeout(const Duration(seconds: 12));
    return controller;
  } catch (_) {
    await controller.dispose();
    rethrow;
  }
}

Future<Uint8List?> chatVideoThumbnail(Uint8List bytes, String mime) async =>
    null;

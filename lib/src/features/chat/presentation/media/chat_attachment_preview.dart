import 'dart:convert';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_attachment.dart';
import '../../data/chat_media_service.dart';
import '../../data/chat_video.dart';

class ChatAttachmentThumbnail extends StatefulWidget {
  const ChatAttachmentThumbnail({
    super.key,
    required this.attachment,
    this.onTap,
    this.size = 84,
  });
  final ChatAttachment attachment;
  final VoidCallback? onTap;
  final double size;

  @override
  State<ChatAttachmentThumbnail> createState() =>
      _ChatAttachmentThumbnailState();
}

class _ChatAttachmentThumbnailState extends State<ChatAttachmentThumbnail> {
  MemoryImage? _thumbnail;

  @override
  void initState() {
    super.initState();
    _readThumbnail();
  }

  @override
  void didUpdateWidget(ChatAttachmentThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.attachment.id != widget.attachment.id ||
        oldWidget.attachment.thumbnailJpeg != widget.attachment.thumbnailJpeg) {
      _releaseThumbnail();
      _readThumbnail();
    }
  }

  void _readThumbnail() {
    final encoded = widget.attachment.thumbnailJpeg;
    if (encoded.isEmpty) return;
    // MemoryImage keys on the bytes' identity. Decoding in build would replace
    // its stream and clear the displayed frame on every parent animation tick.
    _thumbnail = MemoryImage(base64Decode(encoded));
  }

  void _releaseThumbnail() {
    final thumbnail = _thumbnail;
    _thumbnail = null;
    // Keep decoded media scoped to this preview, never a cross-account cache.
    if (thumbnail != null) unawaited(thumbnail.evict());
  }

  @override
  void dispose() {
    _releaseThumbnail();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Widget placeholder() => const ColoredBox(
      color: Color(0xff182335),
      child: Center(child: Icon(Icons.movie_outlined, color: Colors.white)),
    );
    return Semantics(
      button: widget.onTap != null,
      label: widget.attachment.kind == 'video'
          ? 'Video attachment'
          : 'Image attachment',
      child: GestureDetector(
        onTap: widget.onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (_thumbnail == null)
                  placeholder()
                else
                  Image(
                    image: _thumbnail!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => placeholder(),
                  ),
                if (widget.attachment.kind == 'video')
                  const Align(
                    alignment: Alignment.bottomRight,
                    child: Padding(
                      padding: EdgeInsets.all(6),
                      child: Icon(
                        Icons.videocam_rounded,
                        size: 18,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> openChatAttachment(
  BuildContext context,
  ChatAttachment attachment,
) async {
  final owner = appServices.maybeFind<ChatMediaService>();
  if (owner == null || !owner.isCurrent) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _ChatAttachmentDialog(owner: owner, attachment: attachment),
  );
}

class _ChatAttachmentDialog extends StatefulWidget {
  const _ChatAttachmentDialog({required this.owner, required this.attachment});
  final ChatMediaService owner;
  final ChatAttachment attachment;
  @override
  State<_ChatAttachmentDialog> createState() => _ChatAttachmentDialogState();
}

class _ChatAttachmentDialogState extends State<_ChatAttachmentDialog> {
  PreparedChatMedia? _media;
  VideoPlayerController? _video;
  bool _failed = false;
  bool _retired = false;
  Worker? _retirement;
  @override
  void initState() {
    super.initState();
    _retirement = ever<bool>(widget.owner.retired, (retired) {
      if (retired) _retire();
    });
    if (widget.owner.isCurrent) {
      _load();
    } else {
      _retire();
    }
  }

  Future<void> _load() async {
    try {
      final value = await widget.owner.read(widget.attachment);
      if (!mounted || !widget.owner.isCurrent) return;
      if (value == null) throw StateError('media_missing');
      VideoPlayerController? video;
      if (value.attachment.kind == 'video') {
        video = await createChatVideo(value.bytes, value.mime);
      }
      if (!mounted || !widget.owner.isCurrent) {
        await video?.dispose();
        return;
      }
      setState(() {
        _media = value;
        _video = video;
      });
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    }
  }

  void _clearMedia() {
    final media = _media;
    _media = null;
    if (media != null) unawaited(MemoryImage(media.bytes).evict());
    final video = _video;
    _video = null;
    if (video != null) unawaited(video.dispose());
  }

  void _retire() {
    if (_retired) return;
    _retired = true;
    _clearMedia();
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final route = ModalRoute.of(context);
      if (route == null || !route.isActive) return;
      final navigator = Navigator.of(context);
      if (route.isCurrent) {
        navigator.pop();
      } else {
        navigator.removeRoute(route);
      }
    });
  }

  @override
  void dispose() {
    _retirement?.dispose();
    _clearMedia();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    if (_retired || !widget.owner.isCurrent) return const SizedBox.shrink();
    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: SafeArea(
        child: Stack(
          children: [
            Center(
              child: _failed
                  ? Text(
                      chinese
                          ? '当前设备暂时没有这个附件'
                          : 'This attachment is unavailable on this device',
                      style: const TextStyle(color: Colors.white),
                    )
                  : _media == null
                  ? const CircularProgressIndicator()
                  : _video != null
                  ? AspectRatio(
                      aspectRatio: _video!.value.aspectRatio,
                      child: VideoPlayer(_video!),
                    )
                  : InteractiveViewer(child: Image.memory(_media!.bytes)),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: IconButton(
                tooltip: chinese ? '关闭' : 'Close',
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close, color: Colors.white),
              ),
            ),
            if (_video != null)
              Positioned(
                bottom: 16,
                left: 0,
                right: 0,
                child: Center(
                  child: IconButton(
                    tooltip: chinese ? '播放或暂停' : 'Play or pause',
                    onPressed: () {
                      if (_video!.value.isPlaying) {
                        _video!.pause();
                      } else {
                        _video!.play();
                      }
                      setState(() {});
                    },
                    icon: Icon(
                      _video!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

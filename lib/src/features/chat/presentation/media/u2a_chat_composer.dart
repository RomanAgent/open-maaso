import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/widgets/chat_input_bar.dart';
import '../../application/u2a_chat_controller.dart';
import 'chat_attachment_preview.dart';

/// Fullscreen chat uses the same composer and attachment previews as Home.
class U2aChatComposer extends StatelessWidget {
  const U2aChatComposer({super.key, required this.controller});
  final U2aChatController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller;
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    return AppReactiveBuilder(
      () => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (c.pendingMedia.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: SizedBox(
                height: 68,
                child: ListView.separated(
                  key: const ValueKey('u2a-pending-media'),
                  scrollDirection: Axis.horizontal,
                  itemCount: c.pendingMedia.length,
                  separatorBuilder: (_, _) => const SizedBox(width: 8),
                  itemBuilder: (context, index) {
                    final media = c.pendingMedia[index];
                    return Stack(
                      children: [
                        ChatAttachmentThumbnail(
                          attachment: media.attachment,
                          size: 64,
                        ),
                        Positioned(
                          right: 0,
                          top: 0,
                          child: IconButton(
                            key: ValueKey(
                              'u2a-remove-media-${media.attachment.id}',
                            ),
                            tooltip: chinese ? '移除附件' : 'Remove attachment',
                            onPressed: c.busy
                                ? null
                                : () => c.removeMedia(media.attachment.id),
                            icon: const Icon(Icons.cancel, size: 20),
                            constraints: const BoxConstraints.tightFor(
                              width: 36,
                              height: 36,
                            ),
                            padding: EdgeInsets.zero,
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ChatInputBar(
            key: const ValueKey('u2a-fullscreen-composer'),
            controller: c.inputController,
            onSend: c.sendMessage,
            onVoiceSend: c.sendMessage,
            isThinking: c.busy,
            onInterrupt: c.interruptCurrent,
            allowRealtimeVoice: false,
            floatingGlass: true,
            textInputBorder: true,
            leading: IconButton(
              key: const ValueKey('u2a-attach-media'),
              tooltip: chinese ? '添加图片或视频' : 'Add image or video',
              onPressed: c.busy || c.preparingMedia.value
                  ? null
                  : () => _pickMedia(context),
              constraints: const BoxConstraints.tightFor(width: 40, height: 44),
              padding: EdgeInsets.zero,
              icon: c.preparingMedia.value
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.add_rounded, size: 24),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pickMedia(BuildContext context) async {
    final chinese = Localizations.localeOf(context).languageCode == 'zh';
    FocusManager.instance.primaryFocus?.unfocus();
    final kind = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: Text(chinese ? '上传图片' : 'Choose image'),
              onTap: () => Navigator.pop(sheetContext, 'image'),
            ),
            ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: Text(chinese ? '上传视频' : 'Choose video'),
              subtitle: Text(
                chinese
                    ? '60 秒以内，最多 12 MB；识别视频画面'
                    : 'Up to 60 seconds / 12 MB; visual content analysis',
              ),
              onTap: () => Navigator.pop(sheetContext, 'video'),
            ),
          ],
        ),
      ),
    );
    if (kind == null || controller.isClosed) return;
    try {
      final picker = ImagePicker();
      final file = kind == 'image'
          ? await picker.pickImage(
              source: ImageSource.gallery,
              maxWidth: 1600,
              maxHeight: 1600,
              imageQuality: 85,
            )
          : await picker.pickVideo(
              source: ImageSource.gallery,
              maxDuration: const Duration(seconds: 60),
            );
      if (file == null || controller.isClosed) return;
      if (await file.length() > (kind == 'image' ? 20 : 12) * 1024 * 1024) {
        appNavigation.showSnackBar(
          message: chinese
              ? '附件过大，请选择较小的文件'
              : 'Attachment too large. Choose a smaller file',
        );
        return;
      }
      await controller.addMedia(
        await file.readAsBytes(),
        video: kind == 'video',
        mime: file.name.toLowerCase().endsWith('.mov')
            ? 'video/quicktime'
            : 'video/mp4',
      );
    } catch (_) {
      if (!controller.isClosed) {
        appNavigation.showSnackBar(
          message: chinese
              ? '未能读取附件，请重试'
              : 'Could not read the attachment. Please retry',
        );
      }
    }
  }
}

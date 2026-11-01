import 'package:maaso/src/features/chat/data/chat_media_service.dart';

import 'app_invocation_catalog.dart';
import 'app_invocation_execution_contract.dart';

/// A native-owned, frozen Home submission. This is not an execution grant.
/// The service revalidates the source and issues its own bounded capability.
final class AppInvocationTurnInput {
  AppInvocationTurnInput({
    required this.source,
    required this.submissionToken,
    required this.sourceTitle,
    required bool Function() isOwnerCurrent,
    Iterable<PreparedChatMedia> images = const [],
  }) : _isOwnerCurrent = isOwnerCurrent,
       inputImages = List.unmodifiable([
         for (final item in images)
           AppInvocationInputImage(
             id: item.attachment.id,
             mime: item.mime,
             bytes: item.bytes,
           ),
       ]) {
    requireAppInvocationIdentifier(submissionToken);
    if (sourceTitle != source.title) {
      throw const FormatException('invocation_source_title_mismatch');
    }
    if (inputImages.length > appInvocationMaximumImages ||
        inputImages.map((i) => i.id).toSet().length != inputImages.length) {
      throw const FormatException('invocation_input_images_invalid');
    }
  }
  final AppInvocationPinnedSource source;
  final String submissionToken, sourceTitle;
  final List<AppInvocationInputImage> inputImages;
  final bool Function() _isOwnerCurrent;
  bool get isCurrent {
    try {
      return _isOwnerCurrent() && source.isCurrent;
    } catch (_) {
      return false;
    }
  }
}

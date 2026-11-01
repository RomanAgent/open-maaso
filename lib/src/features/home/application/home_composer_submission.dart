import 'package:flutter/services.dart';
import 'package:maaso/src/core/services/locale_config_service.dart';
import 'package:maaso/src/features/agent/application/app_invocation/app_invocation_catalog.dart';
import 'package:maaso/src/features/applets/application/applet_edit_reference.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'package:maaso/src/features/project_build/domain/project_build_edit_target.dart';

enum HomeComposerAdmissionOutcome { notAdmitted, admitted }

/// Native-owned input captured before the first await. It is neither an app
/// grant nor a mutable view of the currently visible composer.
final class HomeComposerSubmission {
  HomeComposerSubmission({
    required this.token,
    required this.ownerToken,
    required this.isOwnerCurrent,
    required this.scopeKey,
    required this.locale,
    required this.text,
    this.draftRevision,
    this.draftValue,
    Iterable<PreparedChatMedia> media = const [],
    this.invocation,
    this.projectEdit,
    this.appletEdit,
    this.planRequested = false,
  }) : selectedMedia = List.unmodifiable(media),
       media = List.unmodifiable(
         media.map(
           (item) => PreparedChatMedia(
             item.attachment,
             Uint8List.fromList(item.bytes),
             item.mime,
           ),
         ),
       );

  final String token, scopeKey, text;
  final Object ownerToken;
  final bool Function() isOwnerCurrent;
  final AppLocale locale;
  final int? draftRevision;
  final TextEditingValue? draftValue;
  final List<PreparedChatMedia> selectedMedia, media;
  final AppInvocationSelection? invocation;
  final ProjectBuildEditTarget? projectEdit;
  final AppletEditReference? appletEdit;
  final bool planRequested;

  bool get isVoice => draftValue == null;
  bool get hasExplicitReference =>
      invocation != null || projectEdit != null || appletEdit != null;
  bool get allowInputMerge => !isVoice && !hasExplicitReference;
}

/// Only the exact untouched state produced by our own consumption may be
/// restored. Empty text alone is not evidence that the user left it untouched.
final class HomeComposerDraftReceipt {
  const HomeComposerDraftReceipt({
    required this.submissionToken,
    required this.ownerToken,
    required this.revision,
  });
  final String submissionToken;
  final Object ownerToken;
  final int revision;
}

import '../media/chat_attachment_preview.dart';
import 'package:maaso/src/features/applets/presentation/applet_chat_card.dart';
import 'package:maaso/src/features/agent/presentation/agent_task_chat_card.dart';
import 'package:flutter/material.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_native_frost_group.dart';
import 'package:maaso/src/core/widgets/ui/glass/maaso_frost_tokens.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_actions.dart';
import 'app_invocation_chat_card.dart';

// Small labels must also clear 4.5:1 when the white message material sits on
// a completely dark part of the avatar scene.
Color messageSecondaryForeground(MaasoGlassTheme glass) =>
    Color.lerp(glass.foregroundPrimary, glass.foregroundSecondary, .5)!;

/// Shared message shell with a readable fill until its native frost is ready.
class MessageFrostSurface extends StatelessWidget {
  const MessageFrostSurface({
    required this.child,
    this.isUser = false,
    this.foregroundBuilder,
    super.key,
  });

  final Widget child;
  final bool isUser;
  final Widget Function(Widget child)? foregroundBuilder;

  @override
  Widget build(BuildContext context) {
    final glass = MaasoGlassTheme.of(context);
    final native = AppNativeFrostRegion.available(context);
    final materialReady = AppNativeFrostRegion.materialReady(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final fill = isUser
        ? (dark
                  ? MaasoFrostTokens.darkUserMessage
                  : MaasoFrostTokens.lightUserMessage)
              .withValues(alpha: MaasoFrostTokens.messageUserFillAlpha)
        : glass.surface.withValues(alpha: MaasoFrostTokens.messageFillAlpha);
    final padded = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 48, minHeight: 44),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        child: child,
      ),
    );
    final foreground = foregroundBuilder?.call(padded) ?? padded;
    return LayoutBuilder(
      builder: (context, constraints) => Align(
        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: (constraints.maxWidth * .86).clamp(0, 680),
          ),
          child: native
              ? Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 5,
                  ),
                  child: AppNativeFrostRegion(
                    radius: MaasoFrostTokens.messageRadius,
                    userTint: isUser,
                    child: DecoratedBox(
                      key: const ValueKey('native-message-fallback'),
                      decoration: BoxDecoration(
                        color: materialReady ? null : fill,
                        borderRadius: BorderRadius.circular(
                          MaasoFrostTokens.messageRadius,
                        ),
                      ),
                      child: foreground,
                    ),
                  ),
                )
              : AppGlassSurface(
                  role: AppGlassSurfaceRole.message,
                  tintColor: fill,
                  margin: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 5,
                  ),
                  cornerRadius: MaasoFrostTokens.messageRadius,
                  child: foreground,
                ),
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final bool dim;
  final MessageActionSidePolicy actionSidePolicy;
  final VoidCallback? onReport;
  final Future<void> Function(AppInvocationChatReference)? onRecoverInvocation;
  final Future<void> Function(AppInvocationChatReference)?
  onRestoreInvocationDraft;

  const MessageBubble({
    super.key,
    required this.message,
    this.dim = false,
    this.actionSidePolicy = MessageActionSidePolicy.bySender,
    this.onReport,
    this.onRecoverInvocation,
    this.onRestoreInvocationDraft,
  });

  @override
  Widget build(BuildContext context) {
    final isMe = message.isUserMessage || message.senderId == 'user';
    final glass = MaasoGlassTheme.of(context);
    final userForeground = Theme.of(context).brightness == Brightness.dark
        ? MaasoFrostTokens.darkOnUserMessage
        : MaasoFrostTokens.lightOnUserMessage;
    final textColor = isMe ? userForeground : glass.foregroundPrimary;
    final secondaryColor = isMe
        ? userForeground
        : messageSecondaryForeground(glass);
    return MessageFrostSurface(
      isUser: isMe,
      foregroundBuilder: (child) => MessageActionsAnchor(
        message: message,
        enabled: !dim && message.taskReference == null,
        sidePolicy: actionSidePolicy,
        onReport: onReport,
        child: child,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (message.invocationReference case final reference?)
            AppInvocationChatCard(
              reference: reference,
              sessionId: message.sessionId,
              enabled: !dim,
              onRecover: onRecoverInvocation,
              onRestore: onRestoreInvocationDraft,
            ),
          if (message.taskReference case final reference?)
            AgentTaskChatCard(reference: reference),
          if (message.appletReference case final reference?)
            AppletChatCard(reference: reference),
          if (message.attachments.isNotEmpty) ...[
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: message.attachments
                  .map(
                    (a) => ChatAttachmentThumbnail(
                      attachment: a,
                      size: 100,
                      onTap: () => openChatAttachment(context, a),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 8),
          ],
          if (message.content.isNotEmpty)
            Text(
              message.content,
              style: TextStyle(
                color: dim ? secondaryColor : textColor,
                fontSize: 15,
                height: 1.42,
                fontWeight: FontWeight.w500,
              ),
            ),
        ],
      ),
    );
  }
}

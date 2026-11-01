import 'package:flutter/material.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/features/agent/application/controllers/agent_core_controller.dart';
import 'package:maaso/src/features/chat/presentation/media/u2a_chat_composer.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_history_edge.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_thinking_bubble.dart';
import 'package:maaso/src/features/chat/application/u2a_chat_controller.dart';
import 'package:maaso/src/core/widgets/agent_avatar.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';

class U2aChatPage extends AppView<U2aChatController> {
  const U2aChatPage({super.key});

  @override
  Widget build(BuildContext context) {
    final core = appServices.find<AgentCoreController>();
    return AppSecondaryScaffold(
      safeAreaBottom: false,
      header: _Header(core: core),
      body: Column(
        children: [
          Expanded(
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: ChatHistoryEdge(
                child: AppReactiveBuilder(() {
                  final messages = controller.todayMessages;
                  return ListView.builder(
                    key: const ValueKey('u2a-chat-scroll-view'),
                    controller: controller.scrollController,
                    addRepaintBoundaries: false,
                    keyboardDismissBehavior:
                        ScrollViewKeyboardDismissBehavior.onDrag,
                    padding: const EdgeInsets.fromLTRB(12, 56, 12, 12),
                    itemCount:
                        messages.length + (controller.isTyping.value ? 1 : 0),
                    itemBuilder: (_, i) => ChatHistoryEdgeItem(
                      child: RepaintBoundary(
                        child: i < messages.length
                            ? MessageBubble(message: messages[i])
                            : const ChatThinkingBubble(
                                key: ValueKey('u2a-chat-thinking'),
                              ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
          AppReactiveBuilder(() {
            final error = controller.sendError.value;
            return error == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    child: Semantics(
                      liveRegion: true,
                      child: Text(
                        error,
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  );
          }),
          U2aChatComposer(controller: controller),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final AgentCoreController core;
  const _Header({required this.core});

  @override
  Widget build(BuildContext context) {
    return AppReactiveBuilder(
      () => AppSecondaryHeader(
        onBack: () => appNavigation.pop(),
        titleLeading: AgentAvatarThumb(
          emoji: core.profile.value?.avatar ?? '',
          size: 40,
        ),
        title: core.profile.value?.nickname ?? 'chat.my_agent'.tr,
        subtitle: 'chat.online_with_you'.tr,
      ),
    );
  }
}

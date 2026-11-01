import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show mapEquals;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/services/db_service.dart';
import 'package:maaso/src/core/services/mic_capture_service.dart';
import 'package:maaso/src/core/services/platform_asr_service.dart';
import 'package:maaso/src/core/services/volc_rtc_session_service.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_glass.dart';
import 'package:maaso/src/core/widgets/ui/glass/app_native_frost_group.dart';
import 'package:maaso/src/features/chat/application/local_chat_day.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_window_visibility.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_actions.dart';
import 'package:maaso/src/features/chat/presentation/widgets/message_bubble.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_history_edge.dart';
import 'package:maaso/src/features/chat/presentation/widgets/chat_thinking_bubble.dart';
import 'package:maaso/src/features/home/application/home_controller.dart';
import 'package:maaso/src/features/agent/application/tasks/agent_task_job_store.dart';
import 'package:maaso/src/features/applets/data/applet_local_ownership.dart';
import 'package:maaso/src/features/people_safety/data/people_safety_client.dart';
import 'package:maaso/src/features/people_safety/presentation/home_ai_report.dart';

/// Shared persistent conversation, full-height in chat mode and bounded on the
/// avatar stage. Reading ownership is preserved when new messages arrive.
class HomeChatHistory extends StatefulWidget {
  const HomeChatHistory({
    required this.contentPadding,
    required this.latestButtonBottom,
    required this.topFadeHeight,
    this.compact = false,
    this.autoHide = false,
    this.keepVisible = false,
    this.activityToken,
    this.trailing,
    this.clock,
    super.key,
  });

  final EdgeInsets contentPadding;
  final double latestButtonBottom;
  final double topFadeHeight;
  final bool compact;
  final bool autoHide;
  final bool keepVisible;
  final Object? activityToken;
  final Widget? trailing;
  final DateTime Function()? clock;

  @override
  State<HomeChatHistory> createState() => _HomeChatHistoryState();
}

class _HomeChatHistoryState extends State<HomeChatHistory>
    with WidgetsBindingObserver {
  static const _latestTolerance = 80.0;
  static const _replyRefreshDelay = Duration(milliseconds: 500);

  final _scrollController = ScrollController();
  late final LocalChatDayClock _dayClock;
  DateTime? _latestReplyAt;
  List<ChatMessage> _messages = const [];
  DBService? _messageDatabase;
  String? _messageScopeKey;
  PeopleSafetyClient? _messageReportClient;
  String? _messageReportContextKey;
  Worker? _thinkingWorker;
  Worker? _replyWorker;
  Worker? _conversationWorker;
  Worker? _thoughtWorker;
  Timer? _replyRefreshTimer;
  int _loadGeneration = 0;
  int _interactionGeneration = 0;
  int _returnGeneration = 0;
  bool _loading = true;
  bool _followingLatest = true;
  bool _userScrolling = false;
  bool _showLatestButton = false;
  bool _tailUpdateScheduled = false;
  bool _startingOwnedScroll = false;
  bool _returningToLatest = false;

  bool get _nearLatest =>
      !_scrollController.hasClients ||
      _scrollController.position.extentAfter <= _latestTolerance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    final home = appServices.find<HomeController>();
    _dayClock = LocalChatDayClock(clock: widget.clock)
      ..addListener(_onDayRefresh);
    _latestReplyAt = home.latestBubbleAt ?? _dayClock.now;
    _conversationWorker = home.conversationRevision.listen(
      (_) => unawaited(_reload()),
    );
    _thinkingWorker = home.isThinking.listen((_) => unawaited(_reload()));
    _thoughtWorker = home.latestThought.listen((_) => _scheduleTailUpdate());
    _replyWorker = home.latestBubble.listen((_) {
      _latestReplyAt = home.latestBubbleAt ?? _dayClock.now;
      _scheduleTailUpdate();
      if (home.isThinking.value) return;
      _replyRefreshTimer?.cancel();
      _replyRefreshTimer = Timer(
        _replyRefreshDelay,
        () => unawaited(_reload()),
      );
    });
    unawaited(_reload());
  }

  @override
  void didUpdateWidget(covariant HomeChatHistory oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.contentPadding != widget.contentPadding) {
      // Keep the newest reply above the composer when the keyboard opens.
      // A reader who has scrolled away keeps their chosen position instead.
      _scheduleTailUpdate();
    }
  }

  @override
  void didChangeMetrics() {
    // Scaffold can consume MediaQuery's keyboard inset before this subtree.
    // Keep the compact viewport synchronized with the moving composer.
    if (mounted && widget.compact) setState(() {});
  }

  Future<void> _reload() async {
    final generation = ++_loadGeneration;
    final day = LocalChatDay.at(_dayClock.now);
    final currentTasks = appServices.maybeFind<AgentTaskJobStore>();
    final currentScope = AppletLocalOwnership.currentScopeKey();
    bool deleted(ChatMessage message, AgentTaskJobStore? tasks, String scope) {
      final reference = message.taskReference;
      return reference != null &&
          reference.scopeKey == scope &&
          (tasks?.isTaskDeleted(reference.taskId, expectedScopeKey: scope) ??
              false);
    }

    if (mounted &&
        _messages.any((m) => deleted(m, currentTasks, currentScope))) {
      setState(
        () => _messages = _messages
            .where((m) => !deleted(m, currentTasks, currentScope))
            .toList(),
      );
    }
    try {
      final database = appServices.find<DBService>();
      final scope = AppletLocalOwnership.currentScopeKey();
      final reportClient = appServices.maybeFind<PeopleSafetyClient>();
      final reportContextKey = reportClient?.contextKey;
      final messages = await database.getMessagesInRange(
        'self',
        from: day.start,
        before: day.end,
      );
      if (!mounted || generation != _loadGeneration) return;
      if (!identical(database, appServices.maybeFind<DBService>()) ||
          scope != AppletLocalOwnership.currentScopeKey() ||
          !identical(
            reportClient,
            appServices.maybeFind<PeopleSafetyClient>(),
          ) ||
          reportContextKey != reportClient?.contextKey) {
        unawaited(_reload());
        return;
      }
      final taskStore = appServices.maybeFind<AgentTaskJobStore>();
      // Recheck after the database await. A read begun before deletion must
      // not republish a card whose positive tombstone is now durable.
      messages.removeWhere((message) => deleted(message, taskStore, scope));
      final references = messages
          .map((row) => row.taskReference?.taskId)
          .whereType<String>()
          .toSet();
      if (taskStore != null) {
        for (final job in taskStore.jobs.reversed) {
          if (job.agentId != 'self' ||
              job.appletScopeKey != scope ||
              taskStore.isTaskDeleted(job.taskId, expectedScopeKey: scope) ||
              !taskStore.isCurrentAttempt(job) ||
              references.contains(job.taskId)) {
            continue;
          }
          final card = taskStore.cardFor(job);
          if (day.contains(card.timestamp) || job.isActive) {
            messages.add(card);
            references.add(job.taskId);
          }
        }
        messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));
      }
      if (!mounted || generation != _loadGeneration) return;
      if (day != LocalChatDay.at(_dayClock.now)) {
        _dayClock.refresh();
        return;
      }
      setState(() {
        _messageDatabase = database;
        _messageScopeKey = scope;
        _messageReportClient = reportClient;
        _messageReportContextKey = reportContextKey;
        final unchanged =
            _messages.length == messages.length &&
            Iterable<int>.generate(messages.length).every((index) {
              final before = _messages[index];
              final after = messages[index];
              return before.id == after.id &&
                  mapEquals(before.toJson(), after.toJson());
            });
        if (!unchanged) _messages = messages;
        _loading = false;
      });
      // Recheck the live scroll intent after the read. A gesture made while
      // the database was busy must win over automatic following.
      _scheduleTailUpdate();
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() => _loading = false);
    }
  }

  bool _canReport(ChatMessage message) =>
      mounted &&
      LocalChatDay.at(_dayClock.now).contains(message.timestamp) &&
      isReportableHomeAIReply(message) &&
      identical(_messageDatabase, appServices.maybeFind<DBService>()) &&
      _messageScopeKey == AppletLocalOwnership.currentScopeKey() &&
      _messageReportClient?.active == true &&
      identical(
        _messageReportClient,
        appServices.maybeFind<PeopleSafetyClient>(),
      ) &&
      _messageReportContextKey == _messageReportClient?.contextKey;

  void _onDayRefresh() {
    if (!mounted) return;
    // Hide expired rows immediately, including while a replacement read waits.
    setState(() {
      final current = _messages
          .where((message) => _dayClock.day.contains(message.timestamp))
          .toList();
      if (current.length != _messages.length) _messages = current;
    });
    unawaited(_reload());
  }

  void _onScroll() {
    if (_userScrolling) _followingLatest = _nearLatest;
    final show = !_nearLatest;
    if (mounted && show != _showLatestButton) {
      setState(() => _showLatestButton = show);
    }
  }

  bool _onScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if ((notification is ScrollStartNotification && !_startingOwnedScroll) ||
        (notification is UserScrollNotification &&
            notification.direction != ScrollDirection.idle)) {
      if (!_userScrolling) _interactionGeneration++;
      _userScrolling = true;
      _followingLatest = _nearLatest;
    } else if (notification is ScrollEndNotification) {
      if (_userScrolling) _followingLatest = _nearLatest;
      _userScrolling = false;
    }
    return false;
  }

  void _scheduleTailUpdate() {
    if (!mounted || _tailUpdateScheduled) return;
    _tailUpdateScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _tailUpdateScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      if (_followingLatest && !_userScrolling && !_returningToLatest) {
        final position = _scrollController.position;
        if ((position.maxScrollExtent - position.pixels).abs() > 0.5) {
          _startOwnedScroll(
            () => _scrollController.jumpTo(position.maxScrollExtent),
          );
        }
      }
      _onScroll();
    });
  }

  T _startOwnedScroll<T>(T Function() start) {
    // Scrollbar track clicks and keyboard actions also emit non-drag starts.
    // Suppress only our synchronous start, never the animation's lifetime.
    _startingOwnedScroll = true;
    try {
      return start();
    } finally {
      _startingOwnedScroll = false;
    }
  }

  Future<void> _returnToLatest() async {
    if (!_scrollController.hasClients) return;
    final interaction = _interactionGeneration;
    final returnGeneration = ++_returnGeneration;
    _followingLatest = true;
    _userScrolling = false;
    _returningToLatest = true;
    final target = _scrollController.position.maxScrollExtent;
    try {
      if (MediaQuery.disableAnimationsOf(context) ||
          MediaQuery.accessibleNavigationOf(context)) {
        _startOwnedScroll(() => _scrollController.jumpTo(target));
      } else {
        await _startOwnedScroll(
          () => _scrollController.animateTo(
            target,
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
          ),
        );
      }
    } finally {
      if (mounted && returnGeneration == _returnGeneration) {
        _returningToLatest = false;
      }
    }
    if (!mounted ||
        returnGeneration != _returnGeneration ||
        interaction != _interactionGeneration) {
      return;
    }
    final position = _scrollController.position;
    if (!_nearLatest && position.pixels < target - 1) {
      // A keyboard/track moveTo can replace an active driven animation without
      // emitting another ScrollStart. Completion alone does not mean arrival.
      _interactionGeneration++;
      _followingLatest = false;
      _userScrolling = position.isScrollingNotifier.value;
      _onScroll();
      return;
    }
    // Lazy rows or a concurrently arriving reply can extend the scroll extent.
    _scheduleTailUpdate();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _replyRefreshTimer?.cancel();
    _dayClock.dispose();
    _thinkingWorker?.dispose();
    _replyWorker?.dispose();
    _conversationWorker?.dispose();
    _thoughtWorker?.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final home = appServices.find<HomeController>();
    final interaction = HomeChatInteractionScope.maybeOf(context);
    final content = Semantics(
      key: const ValueKey('desktop-home-chat-history'),
      container: true,
      label: 'chat.history'.tr,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_loading && _messages.isEmpty)
            const Center(
              child: SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            Positioned.fill(
              child: ChatHistoryEdge(
                key: const ValueKey('home-chat-top-fade'),
                extent: widget.topFadeHeight,
                child: _buildList(),
              ),
            ),
          if (_showLatestButton && !widget.compact)
            Positioned(
              right: widget.contentPadding.right,
              bottom: widget.latestButtonBottom,
              child: AppGlassSurface(
                role: AppGlassSurfaceRole.chrome,
                cornerRadius: 24,
                child: IconButton(
                  key: const ValueKey('home-chat-scroll-to-latest'),
                  tooltip: 'chat.scroll_to_latest'.tr,
                  constraints: const BoxConstraints.tightFor(
                    width: 48,
                    height: 48,
                  ),
                  onPressed: () => unawaited(_returnToLatest()),
                  icon: const Icon(Icons.arrow_downward_rounded, size: 22),
                ),
              ),
            ),
        ],
      ),
    );
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: home.inputController,
      child: content,
      builder: (context, input, child) => AppReactiveBuilder(() {
        final voiceActive =
            (appServices.maybeFind<MicCaptureService>()?.isRecording.value ??
                false) ||
            (appServices.maybeFind<PlatformAsrService>()?.isListening.value ??
                false) ||
            (appServices.maybeFind<VolcRtcSessionService>()?.isJoined.value ??
                false);
        final window = ChatWindowVisibility(
          enabled: widget.autoHide,
          suppressed: widget.compact && (interaction?.menuExpanded ?? false),
          dismissToken: widget.compact ? interaction?.dismissToken : null,
          resumeAfterSuppression:
              !widget.compact && (interaction?.resumeAfterSuppression ?? true),
          explicitWakeOnly: widget.compact,
          onUserInteraction: widget.compact ? interaction?.activity : null,
          keepVisible:
              widget.keepVisible ||
              home.busy ||
              voiceActive ||
              (widget.compact && (interaction?.hasFocus ?? false)),
          activityToken: widget.compact
              ? interaction?.activityToken
              : (
                  widget.activityToken,
                  interaction?.activityToken,
                  input,
                  home.conversationRevision.value,
                  home.latestBubble.value,
                  home.latestThought.value,
                  home.latestTaskJob.value,
                  _messages,
                ),
          presentationBuilder: (context, child, opacity) => AppNativeFrostGroup(
            enabled: widget.compact,
            opacity: opacity,
            topFadeHeight: widget.topFadeHeight,
            bottomFadeHeight: 24,
            child: child,
          ),
          child: child!,
        );
        return widget.compact
            ? HomeChatActivityRegion(wakeOnPointerDown: false, child: window)
            : window;
      }),
    );
  }

  Widget _buildList() => AppReactiveBuilder(() {
    final home = appServices.find<HomeController>();
    final actionSidePolicy = widget.compact
        ? MessageActionSidePolicy.left
        : MessageActionSidePolicy.bySender;
    final thinking = home.isThinking.value;
    final thought = home.latestThought.value;
    final showThinking = thinking || (thought?.trim().isNotEmpty ?? false);
    // Also retain non-persisted notices/errors previously shown only by the
    // avatar's latest-reply overlay. Persisted conversation turns stay unique.
    final streamingReply = !home.conversationActive.value
        ? home.latestBubble.value?.trim() ?? ''
        : '';
    String? lastPersistedReply;
    for (final message in _messages.reversed) {
      if (message.isUserMessage) continue;
      lastPersistedReply = message.content.trim();
      break;
    }
    final latestReplyAt = home.latestBubbleAt ?? _latestReplyAt;
    final showStreamingReply =
        streamingReply.isNotEmpty &&
        latestReplyAt != null &&
        LocalChatDay.at(_dayClock.now).contains(latestReplyAt) &&
        streamingReply != lastPersistedReply;
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        _scheduleTailUpdate();
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _onScrollNotification,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final extraGutter = ((constraints.maxWidth - 840) / 2).clamp(
              0.0,
              double.infinity,
            );
            final list = ScrollConfiguration(
              behavior: ScrollConfiguration.of(
                context,
              ).copyWith(scrollbars: false),
              child: ListView.builder(
                key: const ValueKey('home-chat-scroll-view'),
                controller: _scrollController,
                addRepaintBoundaries: false,
                shrinkWrap: widget.compact,
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                padding: widget.contentPadding.add(
                  EdgeInsets.fromLTRB(
                    extraGutter,
                    0,
                    extraGutter,
                    widget.compact ? 24 : 0,
                  ),
                ),
                itemCount:
                    _messages.length +
                    (showStreamingReply ? 1 : 0) +
                    (showThinking ? 1 : 0) +
                    (widget.trailing == null ? 0 : 1),
                itemBuilder: (context, index) {
                  Widget row;
                  if (index < _messages.length) {
                    final message = _messages[index];
                    row = MessageBubble(
                      key: ValueKey(
                        message.id ??
                            '${message.timestamp.toIso8601String()}:${message.senderId}:$index',
                      ),
                      message: message,
                      onRecoverInvocation: home.recoverInvocation,
                      onRestoreInvocationDraft: home.restoreInvocationDraft,
                      actionSidePolicy: actionSidePolicy,
                      onReport: _canReport(message)
                          ? () {
                              if (_canReport(message)) {
                                unawaited(reportHomeAIReply(context, message));
                              }
                            }
                          : null,
                    );
                  } else if (showStreamingReply && index == _messages.length) {
                    row = MessageBubble(
                      key: const ValueKey('home-chat-streaming-reply'),
                      dim: thinking,
                      actionSidePolicy: actionSidePolicy,
                      message: ChatMessage(
                        sessionId: 'self',
                        senderId: 'self',
                        receiverId: 'user',
                        content: streamingReply,
                        timestamp: latestReplyAt,
                      ),
                    );
                  } else if (showThinking &&
                      index ==
                          _messages.length + (showStreamingReply ? 1 : 0)) {
                    row = ChatThinkingBubble(
                      key: const ValueKey('home-chat-thinking'),
                      thinking: thinking,
                      thought: thought,
                      onDismissThought: home.dismissThought,
                    );
                  } else {
                    row = widget.trailing!;
                  }
                  return ChatHistoryEdgeItem(
                    extent: widget.topFadeHeight,
                    child: RepaintBoundary(child: row),
                  );
                },
              ),
            );
            return widget.compact
                ? Align(alignment: Alignment.bottomCenter, child: list)
                : list;
          },
        ),
      ),
    );
  });
}

import 'package:flutter/material.dart';
import 'dart:async';
import 'package:maaso/src/core/widgets/ui/glass/app_glass_notice_surface.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/proactive_conversation_topic.dart';
import 'package:maaso/src/core/notifications/notification_preferences_service.dart';
import 'package:maaso/src/core/services/outreach_feedback_collector.dart';
import 'package:maaso/src/core/services/proactive_preference_service.dart';
import 'package:maaso/src/core/widgets/ui/secondary/app_secondary.dart';

/// Controls the existing account contact agreement. Reminders keep their
/// separate notification setting and are never changed by these controls.
class ProactiveConversationControls extends StatelessWidget {
  const ProactiveConversationControls({super.key});

  @override
  Widget build(BuildContext context) {
    final service = appServices.maybeFind<ProactivePreferenceService>();
    if (service == null) return const SizedBox.shrink();
    final zh = Localizations.localeOf(context).languageCode == 'zh';
    String label(String chinese, String english) => zh ? chinese : english;
    Future<void> change(Future<void> Function() operation) async {
      try {
        if (!identical(
              appServices.maybeFind<ProactivePreferenceService>(),
              service,
            ) ||
            !service.isAvailable) {
          throw StateError('account changed');
        }
        await operation();
      } on Object {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            appGlassSnackBar(
              content: Text(
                label('设置未保存，请重试。', 'Could not save this setting. Try again.'),
              ),
            ),
          );
        }
      }
    }

    return AppReactiveBuilder(() {
      final value = service.effectiveSnapshot;
      final controlsAvailable = service.isAvailable;
      final enabled =
          (value.foregroundAllowed || value.osOutreachAllowed) &&
          value.authorizationCurrentAt(DateTime.now());
      final notifications = appServices
          .maybeFind<NotificationPreferencesService>();
      final device = notifications?.state.value;
      final categoriesAvailable =
          controlsAvailable &&
          notifications?.personaMemoryAvailable == true &&
          notifications?.personaMemoryAccount == service.accountScopeDigest;
      void requireCategoryOwner() {
        if (!identical(
              appServices.maybeFind<NotificationPreferencesService>(),
              notifications,
            ) ||
            notifications?.personaMemoryAvailable != true ||
            notifications?.personaMemoryAccount != service.accountScopeDigest) {
          throw StateError('account changed');
        }
      }

      return AppSecondarySection(
        title: label('主动陪伴', 'Proactive companionship'),
        subtitle: label(
          '由你决定它什么时候主动找你，选择会保留在 Agent 的记忆里。',
          'You choose when your Agent reaches out. It remembers your choices.',
        ),
        child: AppSecondaryCard(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!controlsAvailable)
                Text(
                  label(
                    '主动陪伴偏好暂不可用，目前保持关闭。请重新打开页面后重试。',
                    'Contact preferences are unavailable and check-ins stay off. Reopen this page to retry.',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (value.needsConsentReview)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    label(
                      '主动聊天授权需要重新确认，目前保持关闭。免打扰和频率设置已保留，可在这里选择。',
                      'Contact consent needs confirmation, so ordinary check-ins are off. Your quiet hours and frequency are preserved.',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                title: Text(label('主动找我聊天', 'Start a conversation with me')),
                subtitle: Text(
                  label(
                    '默认关闭。未回复就等待；明确提醒单独执行。',
                    'Off by default. Wait after an unanswered check-in. Reminders remain separate.',
                  ),
                ),
                value: enabled,
                onChanged: !controlsAvailable
                    ? null
                    : (next) => change(() async {
                        final wasMuted = service.effectiveSnapshot.hardMuted;
                        await service.setContactAgreement(
                          enabled: next,
                          scope: value.contactScope,
                          expiresAt:
                              value.authorizedUntil?.isAfter(DateTime.now()) ==
                                  true
                              ? value.authorizedUntil
                              : null,
                        );
                        final durable = service.effectiveSnapshot;
                        final collector = appServices
                            .maybeFind<OutreachFeedbackCollector>();
                        if (!wasMuted &&
                            durable.hardMuted &&
                            collector != null) {
                          unawaited(
                            collector.recordMuted(
                              preferenceRevision: durable.revision,
                            ),
                          );
                        } else if (wasMuted &&
                            !durable.hardMuted &&
                            collector != null) {
                          unawaited(
                            collector.recordUnmuted(
                              preferenceRevision: durable.revision,
                            ),
                          );
                        }
                      }),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(label('聊天范围', 'Contact scope')),
                subtitle: DropdownButton<ProactiveConversationScope>(
                  isExpanded: true,
                  value: value.contactScope,
                  items: [
                    DropdownMenuItem(
                      value: ProactiveConversationScope.openTopics,
                      child: Text(label('仅约好的话题', 'Agreed topics only')),
                    ),
                    DropdownMenuItem(
                      value: ProactiveConversationScope.everyday,
                      child: Text(
                        label('日常与约定话题', 'Everyday and agreed topics'),
                      ),
                    ),
                  ],
                  onChanged: !controlsAvailable
                      ? null
                      : (scope) {
                          if (scope != null) {
                            change(() => service.setContactScope(scope));
                          }
                        },
                ),
              ),
              Text(
                label(
                  '一次性续聊可以直接说：明天15点问我面试结果。',
                  'For one check-in, say: tomorrow at 15:00 ask me about the interview.',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(label('每天最多', 'Daily limit')),
                subtitle: DropdownButton<int>(
                  isExpanded: true,
                  value: value.dailyBudget >= 1 && value.dailyBudget <= 3
                      ? value.dailyBudget
                      : null,
                  items: [
                    for (final count in [1, 2, 3])
                      DropdownMenuItem(
                        value: count,
                        child: Text(
                          label(
                            '$count 次',
                            '$count check-in${count == 1 ? '' : 's'}',
                          ),
                        ),
                      ),
                  ],
                  onChanged: !controlsAvailable
                      ? null
                      : (budget) {
                          if (budget != null) {
                            change(() => service.setDailyBudget(budget));
                          }
                        },
                ),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('settings.notifications_quiet_hours'.tr),
                subtitle: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton(
                    key: const ValueKey('persona-contact-quiet-hours'),
                    onPressed: !controlsAvailable
                        ? null
                        : () => _pickQuietHours(context, service, change),
                    child: Text(
                      '${_formatMinutes(value.quietStartMinutes)}–${_formatMinutes(value.quietEndMinutes)}',
                    ),
                  ),
                ),
              ),
              if (notifications != null && device != null) ...[
                if (!categoriesAvailable)
                  Text(
                    label(
                      '主动问候偏好暂不可用，请重新打开页面后重试。',
                      'Check-in preferences are unavailable. Reopen this page to retry.',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text('settings.notifications_greetings'.tr),
                  value: device.greetingsEnabled,
                  onChanged: !categoriesAvailable
                      ? null
                      : (next) => change(() async {
                          requireCategoryOwner();
                          await notifications.setGreetingsEnabled(next);
                        }),
                ),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  title: Text('settings.notifications_check_ins'.tr),
                  value: device.randomCheckInsEnabled,
                  onChanged: !categoriesAvailable
                      ? null
                      : (next) => change(() async {
                          requireCategoryOwner();
                          await notifications.setRandomCheckInsEnabled(next);
                        }),
                ),
                if (!device.canNotify)
                  Text(
                    label(
                      '后台问候还需要在设置中允许系统通知。',
                      'Background check-ins also need notification permission in Settings.',
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
              ],
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(label('授权期限', 'Authorization expires')),
                subtitle: Text(
                  value.authorizedUntil == null
                      ? label('直到我关闭', 'Until I turn it off')
                      : MaterialLocalizations.of(
                          context,
                        ).formatMediumDate(value.authorizedUntil!.toLocal()),
                ),
                trailing: PopupMenuButton<String>(
                  enabled: controlsAvailable,
                  icon: const Icon(Icons.edit_calendar_outlined),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'week',
                      child: Text(label('一周', 'One week')),
                    ),
                    PopupMenuItem(
                      value: 'month',
                      child: Text(label('30 天', '30 days')),
                    ),
                    PopupMenuItem(
                      value: 'none',
                      child: Text(label('直到关闭', 'Until turned off')),
                    ),
                  ],
                  onSelected: (period) => change(
                    () => service.setAuthorizationExpiry(
                      period == 'none'
                          ? null
                          : DateTime.now().add(
                              Duration(days: period == 'week' ? 7 : 30),
                            ),
                    ),
                  ),
                ),
              ),
              Text(
                label(
                  '切换运行设备或重新取得运行权限时，需要重新确认主动聊天授权。',
                  'Confirm contact consent again when the running device or its ownership changes.',
                ),
                style: Theme.of(context).textTheme.bodySmall,
              ),
              for (final topic in value.topics.where(
                (topic) => topic.openAt(DateTime.now()),
              ))
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(topic.label),
                  subtitle: Text(
                    '${MaterialLocalizations.of(context).formatMediumDate(topic.dueAt.toLocal())} ${TimeOfDay.fromDateTime(topic.dueAt.toLocal()).format(context)}',
                  ),
                  trailing: TextButton(
                    onPressed: !controlsAvailable
                        ? null
                        : () => change(
                            () => service.closeConversationTopic(topic.id),
                          ),
                    child: Text(label('已完成', 'Done')),
                  ),
                ),
            ],
          ),
        ),
      );
    });
  }

  Future<void> _pickQuietHours(
    BuildContext context,
    ProactivePreferenceService service,
    Future<void> Function(Future<void> Function()) change,
  ) async {
    final initial = service.effectiveSnapshot;
    final start = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: initial.quietStartMinutes ~/ 60,
        minute: initial.quietStartMinutes % 60,
      ),
      helpText: 'settings.notifications_quiet_hours_start'.tr,
    );
    if (start == null || !context.mounted) return;
    final end = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
        hour: initial.quietEndMinutes ~/ 60,
        minute: initial.quietEndMinutes % 60,
      ),
      helpText: 'settings.notifications_quiet_hours_end'.tr,
    );
    if (end == null || !context.mounted) return;
    await change(
      () => service.setQuietHours(
        start: start.hour * 60 + start.minute,
        end: end.hour * 60 + end.minute,
      ),
    );
  }

  String _formatMinutes(int value) =>
      '${(value ~/ 60).toString().padLeft(2, '0')}:${(value % 60).toString().padLeft(2, '0')}';
}

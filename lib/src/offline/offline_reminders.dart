import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../core/notifications/local_notification_delivery.dart';
import '../core/notifications/notification_delivery.dart';
import '../core/notifications/notification_models.dart';
import 'offline_reminder.dart';
import 'offline_store.dart';

export 'offline_reminder.dart';

/// Owns explicit local schedules through the existing native delivery service.
/// It does not install Firebase, create model requests, or run prompts on taps.
class OfflineReminderService extends ChangeNotifier {
  OfflineReminderService({
    required this.store,
    NotificationDelivery? delivery,
    bool? schedulingSupported,
    DateTime Function()? clock,
    this.operationTimeout = const Duration(seconds: 10),
  }) : _providedDelivery = delivery,
       supported =
           schedulingSupported ??
           (!kIsWeb &&
               const {
                 TargetPlatform.android,
                 TargetPlatform.iOS,
                 TargetPlatform.macOS,
               }.contains(defaultTargetPlatform)),
       _clock = clock ?? DateTime.now {
    if (operationTimeout <= Duration.zero ||
        operationTimeout > const Duration(seconds: 30)) {
      throw ArgumentError('Invalid reminder operation timeout.');
    }
  }
  final OfflineStore store;
  final NotificationDelivery? _providedDelivery;
  final bool supported;
  final DateTime Function() _clock;
  final Duration operationTimeout;
  NotificationDelivery? _instance;
  Future<void> _tail = Future<void>.value();
  final Map<String, Future<void>> _pendingPlatformSchedules = {};
  int _generation = 0, _operations = 0;
  bool _disposed = false;
  List<OfflineReminder> reminders = [];
  String? error;
  bool get busy => _operations > 0;
  NotificationDelivery get _delivery =>
      _instance ??= _providedDelivery ?? LocalNotificationDelivery();

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    if (_disposed) return Future.error(StateError('Reminder service closed.'));
    _operations++;
    _notify();
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation.whenComplete(() {
      _operations--;
      _notify();
    });
  }

  bool _current(int generation) => !_disposed && generation == _generation;
  void _requireCurrent(int generation) {
    if (!_current(generation)) {
      throw const OfflineReminderException('cancelled');
    }
  }

  DateTime _updated(OfflineReminder reminder) {
    final now = _clock().toUtc();
    return now.isBefore(reminder.updatedAt) ? reminder.updatedAt : now;
  }

  Future<void> _reload() async {
    reminders = await store.listReminders();
    _notify();
  }

  Future<void> _initialize() async {
    if (!supported) {
      throw const OfflineReminderException('unsupported_platform');
    }
    final delivery = _delivery;
    if (!delivery.isAvailable) {
      await delivery.initialize().timeout(operationTimeout);
    }
    if (!delivery.isAvailable ||
        delivery is ScheduledNotificationDeliveryCapabilities &&
            !(delivery as ScheduledNotificationDeliveryCapabilities)
                .supportsLocalScheduling) {
      throw const OfflineReminderException('unsupported_platform');
    }
  }

  bool _mayHavePlatformRequest(OfflineReminder r) => const {
    OfflineReminderStatus.pending,
    OfflineReminderStatus.scheduled,
    OfflineReminderStatus.cancelPending,
  }.contains(r.status);

  /// Recovery cancels uncertain requests; it never asks permission or reschedules.
  Future<void> load() => _serial(() async {
    error = null;
    final records = await store.listReminders();
    for (final reminder in records) {
      if (reminder.status == OfflineReminderStatus.pending ||
          reminder.status == OfflineReminderStatus.cancelPending) {
        try {
          await _cancelOne(reminder);
        } catch (_) {
          error = '有提醒尚未完成撤销，请重试。';
        }
      }
    }
    await _reload();
  });

  DateTime _target(OfflineReminder reminder) {
    final now = _clock();
    var target = reminder.scheduledAt.toLocal();
    if (!target.isAfter(now)) {
      if (!reminder.repeatsDaily) {
        throw const OfflineReminderException('invalid_time');
      }
      target = DateTime(
        now.year,
        now.month,
        now.day,
        target.hour,
        target.minute,
        target.second,
      );
      if (!target.isAfter(now)) {
        target = DateTime(
          now.year,
          now.month,
          now.day + 1,
          target.hour,
          target.minute,
          target.second,
        );
      }
    }
    return target;
  }

  /// Explicit UI save. A disabled draft works on platforms without notifications.
  Future<OfflineReminder> save(
    OfflineReminder reminder, {
    bool schedule = false,
  }) {
    final generation = _generation;
    return _serial(() async {
      _requireCurrent(generation);
      final checked = OfflineReminder.fromJson(reminder.toJson());
      if (schedule) _target(checked);
      final old = await store.getReminder(checked.id);
      if (old != null && _mayHavePlatformRequest(old)) await _cancelOne(old);
      _requireCurrent(generation);
      final draft = checked.copyWith(
        status: OfflineReminderStatus.disabled,
        errorCode: '',
        updatedAt: _updated(checked),
      );
      await store.upsertReminder(draft, mayWrite: () => _current(generation));
      if (schedule) await _enable(draft, generation);
      await _reload();
      return (await store.getReminder(draft.id))!;
    });
  }

  Future<void> enable(String id) {
    final generation = _generation;
    return _serial(() async {
      final reminder = await store.getReminder(id);
      if (reminder == null) {
        throw const OfflineReminderException('missing_reminder');
      }
      _target(reminder);
      if (_mayHavePlatformRequest(reminder)) await _cancelOne(reminder);
      await _enable(reminder, generation);
      await _reload();
    });
  }

  Future<void> _enable(OfflineReminder reminder, int generation) async {
    final target = _target(reminder);
    _requireCurrent(generation);
    try {
      await _initialize();
      _requireCurrent(generation);
      final allowed = await _delivery.requestPermission().timeout(
        operationTimeout,
      );
      _requireCurrent(generation);
      if (!allowed) {
        await store.upsertReminder(
          reminder.copyWith(
            status: OfflineReminderStatus.failed,
            errorCode: 'permission_denied',
            updatedAt: _updated(reminder),
          ),
        );
        await _reload();
        throw const OfflineReminderException('permission_denied');
      }
      final pending = reminder.copyWith(
        status: OfflineReminderStatus.pending,
        errorCode: '',
        updatedAt: _updated(reminder),
      );
      await store.upsertReminder(pending, mayWrite: () => _current(generation));
      _requireCurrent(generation);
      var abandoned = false;
      final scheduling = _delivery.schedule(
        notification: MaasoNotification(
          deliveryId: reminder.deliveryId,
          kind: MaasoNotificationKind.scheduledTask,
          title: reminder.title,
          body: reminder.body,
          data: {'offlineReminderId': reminder.id},
        ),
        target: target,
        repeatsDaily: reminder.repeatsDaily,
      );
      // If a native operation finishes after our timeout, revoke that late request.
      final settled = scheduling.then<void>((_) async {
        if (abandoned || !_current(generation)) {
          try {
            await _delivery
                .cancel(reminder.deliveryId)
                .timeout(operationTimeout);
          } catch (_) {
            /* durable pending/cancelPending row remains for recovery */
          }
        }
      }, onError: (Object _, StackTrace _) {});
      _pendingPlatformSchedules[reminder.deliveryId] = settled;
      unawaited(
        settled.then((_) {
          if (identical(
            _pendingPlatformSchedules[reminder.deliveryId],
            settled,
          )) {
            _pendingPlatformSchedules.remove(reminder.deliveryId);
          }
        }),
      );
      try {
        await scheduling.timeout(operationTimeout);
        _requireCurrent(generation);
        await store.upsertReminder(
          pending.copyWith(
            status: OfflineReminderStatus.scheduled,
            scheduledAt: target,
            updatedAt: _updated(pending),
          ),
          mayWrite: () => _current(generation),
        );
      } catch (_) {
        abandoned = true;
        try {
          await _cancelOne(pending);
        } catch (_) {
          await _reload();
          rethrow;
        }
        if (_current(generation)) {
          await store.upsertReminder(
            pending.copyWith(
              status: OfflineReminderStatus.failed,
              errorCode: 'schedule_failed',
              updatedAt: _updated(pending),
            ),
          );
        }
        await _reload();
        throw const OfflineReminderException('schedule_failed');
      }
      error = null;
    } on OfflineReminderException catch (failure) {
      error = failure.message;
      _notify();
      rethrow;
    } catch (_) {
      error = '本机通知暂不可用，提醒数据仍保留在本地。';
      _notify();
      throw const OfflineReminderException('schedule_failed');
    }
  }

  Future<void> _cancelOne(OfflineReminder reminder) async {
    if (!_mayHavePlatformRequest(reminder)) return;
    final pending = reminder.copyWith(
      status: OfflineReminderStatus.cancelPending,
      errorCode: '',
      updatedAt: _updated(reminder),
    );
    await store.upsertReminder(pending);
    try {
      await _initialize();
      await _delivery.cancel(reminder.deliveryId).timeout(operationTimeout);
      if (_pendingPlatformSchedules.containsKey(reminder.deliveryId)) {
        // A timed-out native schedule can still finish later. Keep its durable
        // cancellation record; logout/reset must not erase this unresolved work.
        throw const OfflineReminderException('cancellation_failed');
      }
      await store.upsertReminder(
        pending.copyWith(
          status: OfflineReminderStatus.disabled,
          errorCode: '',
          updatedAt: _updated(pending),
        ),
      );
    } catch (_) {
      await store.upsertReminder(
        pending.copyWith(
          errorCode: 'cancellation_failed',
          updatedAt: _updated(pending),
        ),
      );
      throw const OfflineReminderException('cancellation_failed');
    }
  }

  Future<void> disable(String id) => _serial(() async {
    final reminder = await store.getReminder(id);
    if (reminder != null) {
      await _cancelOne(reminder);
      await store.upsertReminder(
        reminder.copyWith(
          status: OfflineReminderStatus.disabled,
          errorCode: '',
          updatedAt: _updated(reminder),
        ),
      );
    }
    error = null;
    await _reload();
  });

  Future<void> remove(String id) => _serial(() async {
    final reminder = await store.getReminder(id);
    if (reminder != null) await _cancelOne(reminder);
    await store.deleteReminder(id);
    error = null;
    await _reload();
  });

  /// Call before logout/reset/import. App disposal alone keeps valid OS schedules.
  Future<void> cancelAll() {
    _generation++;
    return _serial(() async {
      var failed = false;
      for (final reminder in await store.listReminders()) {
        try {
          await _cancelOne(reminder);
        } catch (_) {
          failed = true;
        }
      }
      await _reload();
      if (failed) throw const OfflineReminderException('cancellation_failed');
    });
  }

  @override
  void dispose() {
    _generation++;
    _disposed = true;
    final delivery = _instance;
    if (_providedDelivery == null && delivery is LocalNotificationDelivery) {
      delivery.onClose();
    }
    super.dispose();
  }
}

class OfflineReminderException implements Exception {
  const OfflineReminderException(this.code);
  final String code;
  String get message => switch (code) {
    'permission_denied' => '通知权限未开启，提醒已保留。可在系统设置允许后重试。',
    'unsupported_platform' => '此平台暂不支持本机通知，仍可保存提醒清单。',
    'invalid_time' => '请选择未来的日期和时间。',
    'cancelled' => '提醒操作已取消。',
    'missing_reminder' => '提醒已不存在。',
    'cancellation_failed' => '系统提醒尚未成功撤销，请重试后再删除或重置。',
    _ => '系统提醒未设置成功，请重试。',
  };
  @override
  String toString() => message;
}

class OfflineRemindersPage extends StatefulWidget {
  const OfflineRemindersPage({super.key, required this.service});
  final OfflineReminderService service;
  @override
  State<OfflineRemindersPage> createState() => _OfflineRemindersPageState();
}

class _OfflineRemindersPageState extends State<OfflineRemindersPage> {
  String? error;
  @override
  void initState() {
    super.initState();
    unawaited(_run(widget.service.load));
  }

  Future<void> _run(Future<void> Function() operation) async {
    try {
      await operation();
      if (mounted) setState(() => error = null);
    } catch (failure) {
      if (mounted) {
        setState(
          () => error = failure is OfflineReminderException
              ? failure.message
              : '本地提醒操作未完成，请重试。',
        );
      }
    }
  }

  Future<void> _edit([OfflineReminder? current]) async {
    final reminder = await showModalBottomSheet<OfflineReminder>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ReminderEditor(initial: current),
    );
    if (reminder == null || !mounted) return;
    await _run(() async {
      await widget.service.save(reminder, schedule: widget.service.supported);
    });
  }

  Future<void> _remove(OfflineReminder reminder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除本地提醒？'),
        content: const Text('这会同时撤销已安排的系统通知。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _run(() => widget.service.remove(reminder.id));
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.service,
    builder: (context, _) {
      final s = widget.service;
      return Scaffold(
        appBar: AppBar(title: const Text('本地提醒')),
        body: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(
              s.supported
                  ? '由设备系统安排通知，不调用模型或后台。系统省电策略可能使提醒延后。'
                  : '此平台可保存提醒清单，暂不支持系统通知。',
            ),
            if (error ?? s.error case final String text)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  text,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (s.busy) const LinearProgressIndicator(),
            if (s.reminders.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 36),
                child: Text('还没有提醒，点击下方按钮添加。'),
              ),
            for (final r in s.reminders)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(r.title),
                        subtitle: Text(
                          '${_dateLabel(r.scheduledAt)}${r.repeatsDaily ? ' · 每日' : ''}\n${r.body}',
                        ),
                        trailing: Switch(
                          value: r.enabled,
                          onChanged: s.busy || !s.supported
                              ? null
                              : (v) => _run(
                                  () => v ? s.enable(r.id) : s.disable(r.id),
                                ),
                        ),
                      ),
                      Text(switch (r.status) {
                        OfflineReminderStatus.disabled => '未启用系统提醒',
                        OfflineReminderStatus.pending => '正在交给系统安排',
                        OfflineReminderStatus.scheduled => '已交给系统安排',
                        OfflineReminderStatus.cancelPending => '等待确认撤销',
                        OfflineReminderStatus.failed => '未设置成功，可重试',
                      }),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: s.busy ? null : () => _edit(r),
                            child: const Text('编辑'),
                          ),
                          TextButton(
                            onPressed: s.busy ? null : () => _remove(r),
                            child: const Text('删除'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: s.busy ? null : _edit,
          icon: const Icon(Icons.add_alert_outlined),
          label: const Text('添加提醒'),
        ),
      );
    },
  );
}

String _dateLabel(DateTime value) {
  final d = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
}

class _ReminderEditor extends StatefulWidget {
  const _ReminderEditor({this.initial});
  final OfflineReminder? initial;
  @override
  State<_ReminderEditor> createState() => _ReminderEditorState();
}

class _ReminderEditorState extends State<_ReminderEditor> {
  late final TextEditingController title, body;
  late DateTime at;
  late bool daily;
  String? error;
  @override
  void initState() {
    super.initState();
    title = TextEditingController(text: widget.initial?.title ?? '');
    body = TextEditingController(text: widget.initial?.body ?? '');
    at =
        widget.initial?.scheduledAt.toLocal() ??
        DateTime.now().add(const Duration(hours: 1));
    daily = widget.initial?.repeatsDaily ?? false;
  }

  @override
  void dispose() {
    title.dispose();
    body.dispose();
    super.dispose();
  }

  Future<void> pickDate() async {
    final now = DateTime.now();
    final last = DateTime(now.year + 10);
    final initial = at.isBefore(now) ? now : (at.isAfter(last) ? last : at);
    final date = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(now.year, now.month, now.day),
      lastDate: last,
      helpText: '选择提醒日期',
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(at),
      helpText: '选择提醒时间',
    );
    if (time != null && mounted) {
      setState(
        () => at = DateTime(
          date.year,
          date.month,
          date.day,
          time.hour,
          time.minute,
        ),
      );
    }
  }

  void submit() {
    if (title.text.trim().isEmpty || (!daily && !at.isAfter(DateTime.now()))) {
      setState(() => error = '请填写标题并选择未来时间');
      return;
    }
    final now = DateTime.now();
    final result = OfflineReminder(
      id: widget.initial?.id ?? const Uuid().v4(),
      title: title.text.trim(),
      body: body.text.trim(),
      scheduledAt: at,
      createdAt: widget.initial?.createdAt ?? now,
      updatedAt: now,
      repeatsDaily: daily,
    );
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        24 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.initial == null ? '添加本地提醒' : '编辑提醒',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: title,
            maxLength: 120,
            decoration: const InputDecoration(labelText: '标题'),
          ),
          TextField(
            controller: body,
            maxLength: 1000,
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(labelText: '提醒内容'),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_dateLabel(at)),
            trailing: const Icon(Icons.schedule),
            onTap: pickDate,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: daily,
            onChanged: (v) => setState(() => daily = v),
            title: const Text('每天重复'),
          ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          FilledButton(onPressed: submit, child: const Text('保存提醒')),
        ],
      ),
    ),
  );
}

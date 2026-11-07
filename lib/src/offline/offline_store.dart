import 'dart:convert';

import 'package:sembast/sembast.dart';

import 'offline_database.dart';
import 'offline_models.dart';
import 'offline_samples.dart';
import 'offline_reminder.dart';
import 'offline_skill.dart';

/// A single local demo identity owns this isolated, on-device database.
///
/// There is no account server, network client, token or credential record here.
/// The demo login is a convenience gate, not device-level data encryption.
class OfflineStore {
  OfflineStore._(this._database);

  static const demoUsername = 'test';
  static const demoPassword = 'test123456';
  static const schemaVersion = 3;
  static const maxBackupBytes = 20 * 1024 * 1024;
  static const maxWorks = 250;
  static const maxMessages = 5000;
  static const maxMemories = 500;
  static const maxTasks = 500;
  static const maxWorkStateBytes = 256 * 1024;
  static const maxWorkStateEntries = 128;

  static final _meta = StoreRef<String, Object?>('offline_meta');
  static final _works = stringMapStoreFactory.store('offline_works');
  static final _messages = stringMapStoreFactory.store('offline_messages');
  static final _workStates = stringMapStoreFactory.store('offline_work_state');
  static final _tasks = stringMapStoreFactory.store('offline_creation_tasks');
  static final _reminders = stringMapStoreFactory.store('offline_reminders');
  static final _skills = stringMapStoreFactory.store('offline_skills');
  final Database _database;
  bool _closed = false;
  Future<void>? _closeFuture;
  final Map<String, Future<void>> _stateWrites = {};
  final Map<String, int> _workStateGenerations = {};
  int _stateGeneration = 0;

  static Future<OfflineStore> open({
    DatabaseFactory? factory,
    String? path,
    bool seedSamples = true,
  }) async {
    if (factory == null && path != null) {
      throw ArgumentError(
        'A custom path requires an explicit database factory.',
      );
    }
    final database = factory == null
        ? await openOfflineDatabase()
        : await factory.openDatabase(path ?? 'open-maaso-offline-test.db');
    final store = OfflineStore._(database);
    try {
      await database.transaction((transaction) async {
        final version = await _meta.record('schemaVersion').get(transaction);
        if (version != null && !const {1, 2, schemaVersion}.contains(version)) {
          throw const FormatException('Unsupported offline database version.');
        }
        if (version == null) {
          await _meta.record('schemaVersion').put(transaction, schemaVersion);
          await _meta.record('loggedIn').put(transaction, false);
          if (seedSamples) {
            for (final work in offlineSampleWorks()) {
              await _works.record(work.id).put(transaction, work.toJson());
            }
            for (final skill in OfflineSkill.defaults) {
              await _skills.record(skill.id).put(transaction, skill.toJson());
            }
          }
        } else if (version == 1 || version == 2) {
          // New stores are additive; existing user documents stay intact.
          await _meta.record('schemaVersion').put(transaction, schemaVersion);
          if (seedSamples && await _skills.count(transaction) == 0) {
            for (final skill in OfflineSkill.defaults) {
              await _skills.record(skill.id).put(transaction, skill.toJson());
            }
          }
        }
        final tasks = await _tasks.find(transaction);
        for (final record in tasks) {
          final task = OfflineCreationTask.fromJson(record.value);
          final recovered = _interruptedTask(task);
          if (!identical(task, recovered)) {
            await _tasks.record(task.id).put(transaction, recovered.toJson());
          }
        }
      });
      return store;
    } catch (_) {
      await database.close();
      rethrow;
    }
  }

  Database get _db {
    if (_closed) throw StateError('OfflineStore is closed.');
    return _database;
  }

  Future<void> close() {
    final existing = _closeFuture;
    if (existing != null) return existing;
    _closed = true;
    return _closeFuture = _finishClose();
  }

  Future<void> _finishClose() async {
    await _flushStateWrites();
    await _database.close();
  }

  Future<void> _flushStateWrites() async {
    while (_stateWrites.isNotEmpty) {
      await Future.wait(_stateWrites.values.toList());
    }
  }

  Future<bool> isLoggedIn() async =>
      await _meta.record('loggedIn').get(_db) == true;

  Future<bool> login({
    required String username,
    required String password,
  }) async {
    if (username.trim() != demoUsername || password != demoPassword) {
      return false;
    }
    await _meta.record('loggedIn').put(_db, true);
    return true;
  }

  Future<void> logout() => _meta.record('loggedIn').put(_db, false);

  /// Clears local state without touching any other Maaso database.
  /// The credential owner must separately erase its platform-secure API keys.
  Future<void> deleteAccount() {
    _stateGeneration++;
    return _db.transaction((transaction) async {
      await _works.delete(transaction);
      await _messages.delete(transaction);
      await _workStates.delete(transaction);
      await _tasks.delete(transaction);
      await _reminders.delete(transaction);
      await _skills.delete(transaction);
      await _meta.delete(transaction);
      await _meta.record('schemaVersion').put(transaction, schemaVersion);
      await _meta.record('loggedIn').put(transaction, false);
    });
  }

  Future<OfflineProfile> readProfile() async {
    final value = await _meta.record('profile').get(_db);
    return value == null
        ? const OfflineProfile()
        : OfflineProfile.fromJson(_object(value));
  }

  Future<void> saveProfile(OfflineProfile profile) async {
    final checked = OfflineProfile.fromJson(profile.toJson());
    await _meta.record('profile').put(_db, checked.toJson());
  }

  Future<OfflineSettings> readSettings() async {
    final value = await _meta.record('settings').get(_db);
    return value == null
        ? const OfflineSettings()
        : OfflineSettings.fromJson(_object(value));
  }

  Future<void> saveSettings(OfflineSettings settings) async {
    final checked = OfflineSettings.fromJson(settings.toJson());
    await _meta.record('settings').put(_db, checked.toJson());
  }

  Future<List<OfflineWork>> listWorks({OfflineWorkKind? kind}) async {
    final records = await _works.find(_db);
    final works = records.map((r) => OfflineWork.fromJson(r.value));
    final result = works
        .where((work) => kind == null || work.kind == kind)
        .toList();
    result.sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime == 0 ? a.id.compareTo(b.id) : byTime;
    });
    return result;
  }

  Future<OfflineWork?> getWork(String id) async {
    final value = await _works.record(id).get(_db);
    return value == null ? null : OfflineWork.fromJson(value);
  }

  Future<void> upsertWork(OfflineWork work) => upsertWorks([work]);

  /// Validates every generated result before committing any of them.
  /// A retiring conversation/session can revoke the transaction with mayWrite.
  Future<void> upsertWorks(
    List<OfflineWork> works, {
    OfflineCreationTask? completedTask,
    bool Function()? mayWrite,
  }) async {
    if (works.length > maxWorks) {
      throw const FormatException('Too many local works.');
    }
    final checked = works.map((w) => OfflineWork.fromJson(w.toJson())).toList();
    final ids = checked.map((w) => w.id).toSet();
    if (ids.length != checked.length) {
      throw const FormatException('Duplicate work IDs.');
    }
    final completion = completedTask == null
        ? null
        : OfflineCreationTask.fromJson(completedTask.toJson());
    if (completion != null &&
        (completion.status != OfflineTaskStatus.completed ||
            completion.resultWorkIds.length != ids.length ||
            !ids.containsAll(completion.resultWorkIds) ||
            checked.any((work) => work.kind != completion.kind))) {
      throw const FormatException(
        'Creation receipt does not match its outputs.',
      );
    }
    await _db.transaction((transaction) async {
      _requireWrite(mayWrite);
      final existing = await _works.findKeys(transaction);
      if ({...existing, ...ids}.length > maxWorks) {
        throw const FormatException('The local work library is full.');
      }
      if (completion != null &&
          !await _tasks.record(completion.id).exists(transaction) &&
          await _tasks.count(transaction) >= maxTasks) {
        throw const FormatException('Local creation history is full.');
      }
      for (final work in checked) {
        _requireWrite(mayWrite);
        await _works.record(work.id).put(transaction, work.toJson());
      }
      if (completion != null) {
        _requireWrite(mayWrite);
        await _tasks
            .record(completion.id)
            .put(transaction, completion.toJson());
      }
      _requireWrite(mayWrite);
    });
  }

  Future<void> deleteWork(String id) {
    _workStateGenerations[id] = (_workStateGenerations[id] ?? 0) + 1;
    return _db.transaction((transaction) async {
      await _works.record(id).delete(transaction);
      await _workStates.record(id).delete(transaction);
    });
  }

  Future<List<OfflineMessage>> listMessages() async {
    final records = await _messages.find(_db);
    final result = records
        .map((r) => OfflineMessage.fromJson(r.value))
        .toList();
    result.sort((a, b) {
      final byTime = a.createdAt.compareTo(b.createdAt);
      return byTime == 0 ? a.id.compareTo(b.id) : byTime;
    });
    return result;
  }

  Future<void> appendMessage(
    OfflineMessage message, {
    bool Function()? mayWrite,
  }) async {
    final checked = OfflineMessage.fromJson(message.toJson());
    await _db.transaction((transaction) async {
      _requireWrite(mayWrite);
      final existing = await _messages.record(checked.id).get(transaction);
      if (existing != null) {
        if (jsonEncode(existing) != jsonEncode(checked.toJson())) {
          throw const FormatException(
            'Message ID already has different content.',
          );
        }
        return;
      }
      if (await _messages.count(transaction) >= maxMessages) {
        throw const FormatException(
          'Local message history is full. Export or clear it first.',
        );
      }
      _requireWrite(mayWrite);
      await _messages.record(checked.id).put(transaction, checked.toJson());
      _requireWrite(mayWrite);
    });
  }

  Future<void> clearMessages() => _messages.delete(_db);

  Future<List<String>> listMemories() async {
    final value = await _meta.record('memories').get(_db);
    return value == null ? [] : _memories(value);
  }

  Future<void> saveMemories(List<String> memories) async {
    await _meta.record('memories').put(_db, _memories(memories));
  }

  Future<List<OfflineCreationTask>> listTasks() async {
    final records = await _tasks.find(_db);
    final tasks = records
        .map((r) => OfflineCreationTask.fromJson(r.value))
        .toList();
    tasks.sort((a, b) {
      final byTime = b.updatedAt.compareTo(a.updatedAt);
      return byTime == 0 ? a.id.compareTo(b.id) : byTime;
    });
    return tasks;
  }

  Future<void> upsertTask(
    OfflineCreationTask task, {
    bool Function()? mayWrite,
  }) async {
    final checked = OfflineCreationTask.fromJson(task.toJson());
    await _db.transaction((transaction) async {
      _requireWrite(mayWrite);
      final present = await _tasks.record(checked.id).exists(transaction);
      if (!present && await _tasks.count(transaction) >= maxTasks) {
        throw const FormatException('Local creation history is full.');
      }
      _requireWrite(mayWrite);
      await _tasks.record(checked.id).put(transaction, checked.toJson());
      _requireWrite(mayWrite);
    });
  }

  Future<void> deleteTask(String id) => _tasks.record(id).delete(_db);

  Future<void> clearTasks() => _tasks.delete(_db);

  Future<List<OfflineSkill>> listSkills() async {
    final records = await _skills.find(_db);
    return records.map((r) => OfflineSkill.fromJson(r.value)).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> saveSkill(OfflineSkill skill) async {
    final checked = OfflineSkill.fromJson(skill.toJson());
    await _db.transaction((transaction) async {
      if (!await _skills.record(checked.id).exists(transaction) &&
          await _skills.count(transaction) >= OfflineSkill.maxCount) {
        throw const FormatException('Local skill library is full.');
      }
      await _skills.record(checked.id).put(transaction, checked.toJson());
    });
  }

  Future<void> deleteSkill(String id) => _skills.record(id).delete(_db);

  Future<List<OfflineReminder>> listReminders() async {
    final records = await _reminders.find(_db);
    return records.map((r) => OfflineReminder.fromJson(r.value)).toList()
      ..sort((a, b) => a.scheduledAt.compareTo(b.scheduledAt));
  }

  Future<OfflineReminder?> getReminder(String id) async {
    final record = await _reminders.record(id).get(_db);
    return record == null ? null : OfflineReminder.fromJson(record);
  }

  Future<void> upsertReminder(
    OfflineReminder reminder, {
    bool Function()? mayWrite,
  }) async {
    final checked = OfflineReminder.fromJson(reminder.toJson());
    await _db.transaction((transaction) async {
      _requireWrite(mayWrite);
      if (!await _reminders.record(checked.id).exists(transaction) &&
          await _reminders.count(transaction) >= OfflineReminder.maxCount) {
        throw const FormatException('Local reminder library is full.');
      }
      _requireWrite(mayWrite);
      await _reminders.record(checked.id).put(transaction, checked.toJson());
      _requireWrite(mayWrite);
    });
  }

  /// Cancel the platform request through the reminder service before deletion.
  Future<void> deleteReminder(String id) => _reminders.record(id).delete(_db);

  Future<Map<String, String>> readWorkState(String id) async {
    await _stateWrites[id];
    final value = await _workStates.record(id).get(_db);
    return value == null ? {} : _workState(value);
  }

  Future<void> saveWorkState(String id, Map<String, String> state) {
    try {
      final checked = _workState(state);
      final database = _db;
      final generation = _stateGeneration;
      final workGeneration = _workStateGenerations[id] ?? 0;
      bool current() =>
          generation == _stateGeneration &&
          workGeneration == (_workStateGenerations[id] ?? 0);
      final previous = _stateWrites[id] ?? Future<void>.value();
      final operation = previous.then(
        (_) => database.transaction((transaction) async {
          _requireWrite(current);
          if (!await _works.record(id).exists(transaction)) {
            throw const FormatException('The local work no longer exists.');
          }
          _requireWrite(current);
          await _workStates.record(id).put(transaction, checked);
          _requireWrite(current);
        }),
      );
      // Publish the barrier synchronously so a newly opened player cannot read
      // stale state while its predecessor's callback is still queued.
      final settled = operation.then<void>(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
      _stateWrites[id] = settled;
      settled.then((_) {
        if (identical(_stateWrites[id], settled)) _stateWrites.remove(id);
      });
      return operation;
    } catch (error, stack) {
      return Future<void>.error(error, stack);
    }
  }

  /// Exports only the documented data schema. Session and API keys are omitted.
  Future<String> exportJson() async {
    await _flushStateWrites();
    return _db.transaction((transaction) async {
      final works = await _works.find(transaction);
      final messages = await _messages.find(transaction);
      final states = await _workStates.find(transaction);
      final tasks = await _tasks.find(transaction);
      final reminders = await _reminders.find(transaction);
      final skills = await _skills.find(transaction);
      final data = <String, Object?>{
        'format': 'open-maaso-offline',
        'version': schemaVersion,
        'profile':
            await _meta.record('profile').get(transaction) ??
            const OfflineProfile().toJson(),
        'settings':
            await _meta.record('settings').get(transaction) ??
            const OfflineSettings().toJson(),
        'memories':
            await _meta.record('memories').get(transaction) ?? <String>[],
        'works': works.map((r) => r.value).toList(),
        'messages': messages.map((r) => r.value).toList(),
        'workStates': {for (final record in states) record.key: record.value},
        'tasks': tasks.map((r) => r.value).toList(),
        'reminders': reminders.map((r) => r.value).toList(),
        'skills': skills.map((r) => r.value).toList(),
      };
      final result = jsonEncode(data);
      if (utf8.encode(result).length > maxBackupBytes) {
        throw const FormatException(
          'This backup exceeds the supported file size.',
        );
      }
      return result;
    });
  }

  /// Validates the entire document before entering the atomic write transaction.
  /// Restoring data never logs in, imports keys, or enables model networking.
  Future<void> importJson(String source, {bool replace = false}) async {
    if (source.length > maxBackupBytes ||
        utf8.encode(source).length > maxBackupBytes) {
      throw const FormatException('Backup exceeds the supported file size.');
    }
    final document = _object(jsonDecode(source));
    const keys = {
      'format',
      'version',
      'profile',
      'settings',
      'memories',
      'works',
      'messages',
      'workStates',
      'tasks',
      'reminders',
      'skills',
    };
    if (document.keys.any((key) => !keys.contains(key)) ||
        document['format'] != 'open-maaso-offline' ||
        !const {1, 2, schemaVersion}.contains(document['version']) ||
        document['version'] == 1 && document.containsKey('tasks') ||
        document['version'] != schemaVersion &&
            (document.containsKey('reminders') ||
                document.containsKey('skills'))) {
      throw const FormatException('Unsupported offline backup.');
    }
    final profile = OfflineProfile.fromJson(_object(document['profile']));
    final settings = OfflineSettings.fromJson(
      _object(document['settings']),
    ).copyWith(providerEnabled: false);
    final memories = _memories(document['memories']);
    final works = _list(
      document['works'],
      maxWorks,
    ).map((v) => OfflineWork.fromJson(_object(v))).toList();
    final messages = _list(
      document['messages'],
      maxMessages,
    ).map((v) => OfflineMessage.fromJson(_object(v))).toList();
    final tasks =
        _list(
              document['version'] == 1 ? <Object?>[] : document['tasks'],
              maxTasks,
            )
            .map(
              (v) => _interruptedTask(OfflineCreationTask.fromJson(_object(v))),
            )
            .toList();
    final reminders =
        _list(
              document['version'] == schemaVersion
                  ? document['reminders']
                  : <Object?>[],
              OfflineReminder.maxCount,
            )
            .map(
              (v) => OfflineReminder.fromJson(
                _object(v),
              ).copyWith(status: OfflineReminderStatus.disabled, errorCode: ''),
            )
            .toList();
    final skills = _list(
      document['version'] == schemaVersion ? document['skills'] : <Object?>[],
      OfflineSkill.maxCount,
    ).map((v) => OfflineSkill.fromJson(_object(v))).toList();
    if (works.map((v) => v.id).toSet().length != works.length ||
        messages.map((v) => v.id).toSet().length != messages.length ||
        tasks.map((v) => v.id).toSet().length != tasks.length ||
        reminders.map((v) => v.id).toSet().length != reminders.length ||
        skills.map((v) => v.id).toSet().length != skills.length) {
      throw const FormatException('Backup contains duplicate record IDs.');
    }
    final workIds = works.map((v) => v.id).toSet();
    final rawStates = _object(document['workStates'] ?? <String, Object?>{});
    if (rawStates.length > maxWorks ||
        rawStates.keys.any((id) => !workIds.contains(id))) {
      throw const FormatException(
        'Backup contains state without a matching work.',
      );
    }
    final states = rawStates.map(
      (key, value) => MapEntry(key, _workState(value)),
    );
    await _flushStateWrites();
    _stateGeneration++;
    await _db.transaction((transaction) async {
      if (!replace) {
        final currentWorkIds = (await _works.findKeys(transaction)).toSet();
        final currentMessageIds = (await _messages.findKeys(
          transaction,
        )).toSet();
        final currentTaskIds = (await _tasks.findKeys(transaction)).toSet();
        final currentReminderIds = (await _reminders.findKeys(
          transaction,
        )).toSet();
        final currentSkillIds = (await _skills.findKeys(transaction)).toSet();
        if ({...currentWorkIds, ...workIds}.length > maxWorks ||
            {...currentMessageIds, ...messages.map((m) => m.id)}.length >
                maxMessages ||
            {...currentTaskIds, ...tasks.map((t) => t.id)}.length > maxTasks ||
            {...currentReminderIds, ...reminders.map((v) => v.id)}.length >
                OfflineReminder.maxCount ||
            {...currentSkillIds, ...skills.map((v) => v.id)}.length >
                OfflineSkill.maxCount) {
          throw const FormatException(
            'Merged backup exceeds local record limits.',
          );
        }
      } else {
        await _works.delete(transaction);
        await _messages.delete(transaction);
        await _workStates.delete(transaction);
        await _tasks.delete(transaction);
        await _reminders.delete(transaction);
        await _skills.delete(transaction);
      }
      await _meta.record('profile').put(transaction, profile.toJson());
      await _meta.record('settings').put(transaction, settings.toJson());
      await _meta.record('memories').put(transaction, memories);
      for (final work in works) {
        await _works.record(work.id).put(transaction, work.toJson());
        // A replaced work cannot inherit state from its previous source.
        await _workStates.record(work.id).delete(transaction);
      }
      for (final message in messages) {
        await _messages.record(message.id).put(transaction, message.toJson());
      }
      for (final state in states.entries) {
        await _workStates.record(state.key).put(transaction, state.value);
      }
      for (final task in tasks) {
        await _tasks.record(task.id).put(transaction, task.toJson());
      }
      for (final reminder in reminders) {
        await _reminders
            .record(reminder.id)
            .put(transaction, reminder.toJson());
      }
      for (final skill in skills) {
        await _skills.record(skill.id).put(transaction, skill.toJson());
      }
    });
  }
}

OfflineCreationTask _interruptedTask(OfflineCreationTask task) {
  if (task.status != OfflineTaskStatus.queued &&
      task.status != OfflineTaskStatus.running) {
    return task;
  }
  final now = DateTime.now().toUtc();
  return task.copyWith(
    status: OfflineTaskStatus.failed,
    errorCode: 'interrupted',
    updatedAt: now.isBefore(task.updatedAt) ? task.updatedAt : now,
  );
}

void _requireWrite(bool Function()? mayWrite) {
  if (mayWrite != null && !mayWrite()) {
    throw StateError('The local operation was cancelled.');
  }
}

Map<String, Object?> _object(Object? value) {
  if (value is! Map || value.keys.any((key) => key is! String)) {
    throw const FormatException('Expected a local JSON object.');
  }
  return Map<String, Object?>.from(value);
}

List<Object?> _list(Object? value, int limit) {
  if (value is! List || value.length > limit) {
    throw const FormatException('Invalid or oversized local record list.');
  }
  return List<Object?>.from(value);
}

List<String> _memories(Object? value) {
  final list = _list(value, OfflineStore.maxMemories);
  if (list.any((v) => v is! String || v.trim().isEmpty || v.length > 2000)) {
    throw const FormatException('Invalid local memory.');
  }
  return List<String>.unmodifiable(list.cast<String>());
}

Map<String, String> _workState(Object? value) {
  final map = _object(value);
  if (map.length > OfflineStore.maxWorkStateEntries ||
      map.entries.any(
        (e) =>
            e.key.length > 256 ||
            e.value is! String ||
            (e.value as String).length > 65536,
      ) ||
      utf8.encode(jsonEncode(map)).length > OfflineStore.maxWorkStateBytes) {
    throw const FormatException('Invalid or oversized local app state.');
  }
  return Map<String, String>.from(map);
}

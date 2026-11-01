import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sembast/sembast.dart';
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/models/chat_message.dart';
import 'package:maaso/src/core/models/runtime_chat.dart';
import 'package:maaso/src/features/chat/data/chat_media_service.dart';
import 'account_device_lease_coordinator.dart';
import 'app_environment_service.dart';
import 'db_service.dart';
import 'memory_ledger_service.dart';
import 'memory_governance_store.dart';
import 'live_companion_sync_transport.dart';

/// A newly persisted, validated live message. Replayed records never emit this.
final class LiveCompanionChatMessage {
  const LiveCompanionChatMessage({
    required this.eventId,
    required this.sourcePresenceSessionId,
    required this.sourceInstallationId,
    required this.message,
  });

  final String eventId, sourcePresenceSessionId, sourceInstallationId;
  final ChatMessage message;
}

/// Online-only transfer. Both endpoints keep their own local records; neither
/// disconnected peers nor startup history are uploaded for later cloud replay.
final class LiveCompanionSyncService extends AppService {
  LiveCompanionSyncService({
    required this.environment,
    required this.accountUuid,
    required this.database,
    required this.gateway,
    required this.authority,
    required this.media,
    required this.accountIsCurrent,
    this.memoryLedger,
    DateTime Function()? now,
    String Function()? newId,
  }) : _now = now ?? DateTime.now,
       _newId = newId ?? randomId;
  final MaasoEnvironment environment;
  final String accountUuid;
  final DBService database;
  final LiveCompanionSyncGateway gateway;
  final AccountDeviceLeaseCoordinator authority;
  final ChatMediaService media;
  final bool Function() accountIsCurrent;
  final MemoryLedgerService? memoryLedger;
  final DateTime Function() _now;
  final String Function() _newId;
  final revision = 0.obs;
  final online = false.obs;
  final status = ''.obs;
  final _receivedChats = StreamController<LiveCompanionChatMessage>.broadcast();
  Stream<LiveCompanionChatMessage> get receivedChats => _receivedChats.stream;
  final _origins = intMapStoreFactory.store('live_chat_origins.v1');
  final _chatRows = intMapStoreFactory.store('chat_messages');
  final Map<String, _MediaAssembly> _assemblies = {};
  final Set<String> _acks = {};
  final List<LiveCompanionPeer> _peers = [];
  StreamSubscription? _chatWatcher;
  StreamSubscription? _memoryWatcher;
  Future<void>? _loop, _polling;
  Future<void> _localWork = Future.value();
  int _queuedWork = 0;
  bool _retired = false;
  String _connection = '', _presenceId = '';
  DateTime? _lastPoll;
  final Map<int, String> _seenChat = {};
  bool _seeded = false;
  bool _memorySeeded = false;
  final Set<int> _seenEpisodes = {};
  Future<void> Function(LiveCompanionEvent event)? memoryReceiver;

  bool get isCurrent => !_retired && accountIsCurrent();
  List<LiveCompanionPeer> get peers =>
      isCurrent &&
          online.value &&
          _lastPoll != null &&
          _now().difference(_lastPoll!) < const Duration(seconds: 20)
      ? List.unmodifiable(_peers)
      : const [];
  bool hasPeer(String presenceId) =>
      peers.any((p) => p.presenceSessionId == presenceId);
  void _check() {
    if (!isCurrent) {
      throw const LiveCompanionSyncException('ACCOUNT_UNAVAILABLE');
    }
  }

  Map<String, Object?> _actor() {
    _check();
    final presence = authority.currentPresence;
    if (presence == null ||
        presence.presenceSessionId != _presenceId ||
        _connection.isEmpty) {
      throw const LiveCompanionSyncException('LIVE_SYNC_UNAVAILABLE');
    }
    return {
      'agentId': presence.agentId,
      'installationId': presence.installationId,
      'runtimeInstanceId': presence.runtimeInstanceId,
      'presenceSessionId': presence.presenceSessionId,
      'generation': presence.generation,
      'connectionId': _connection,
    };
  }

  void start() {
    if (!isCurrent || _loop != null) return;
    _chatWatcher = _chatRows
        .query(
          finder: Finder(
            filter: Filter.equals('sessionId', 'self'),
            sortOrders: [SortOrder('timestamp', false)],
            limit: 200,
          ),
        )
        .onSnapshots(database.raw)
        .listen(_observeChats, onError: (Object _) {});
    if (memoryLedger != null) {
      _memoryWatcher = MemoryGovernanceStores.episodes
          .query(
            finder: Finder(
              sortOrders: [SortOrder(Field.key, false)],
              limit: 200,
            ),
          )
          .onSnapshots(database.raw)
          .listen((records) {
            final fresh = records
                .where((r) => !_seenEpisodes.contains(r.key))
                .toList();
            _seenEpisodes
              ..clear()
              ..addAll(records.map((r) => r.key));
            if (!_memorySeeded) {
              _memorySeeded = true;
              return;
            }
            final targets = peers.map((p) => p.presenceSessionId).toList();
            if (targets.isEmpty) return;
            for (final record in fresh) {
              _enqueueLocal(() async {
                _check();
                final payload = await memoryLedger!.exportOnlineMemoryChange(
                  record.key,
                  _newId,
                );
                _check();
                if (payload == null) return;
                if (payload['state'] == 'accepted') {
                  try {
                    authority.requireCurrentRequestAuthority();
                  } catch (_) {
                    return;
                  }
                }
                await publish(
                  payload['state'] == 'accepted'
                      ? 'memory_entry'
                      : 'memory_delete',
                  payload,
                  targets: targets,
                );
              });
            }
          }, onError: (Object _) {});
    }
    _loop = (() async {
      while (isCurrent) {
        var delay = const Duration(milliseconds: 150);
        try {
          await poll();
        } catch (_) {
          delay = const Duration(seconds: 2);
        }
        if (isCurrent) await Future<void>.delayed(delay);
      }
    })();
  }

  Future<void> poll({int waitMs = 10000}) {
    if (!isCurrent) return Future.value();
    return _polling ??= _poll(waitMs).whenComplete(() => _polling = null);
  }

  Future<void> _poll(int waitMs) async {
    final presence = authority.currentPresence;
    if (presence == null) {
      online.value = false;
      return;
    }
    if (_presenceId != presence.presenceSessionId) {
      _connection = _newId();
      _presenceId = presence.presenceSessionId;
      _acks.clear();
      _peers.clear();
      _assemblies.clear();
    }
    final connection = _connection;
    final acknowledged = _acks.take(32).toList();
    try {
      final data = await gateway.request('poll', {
        ..._actor(),
        'acknowledgements': acknowledged,
        'waitMs': waitMs,
      });
      _check();
      if (connection != _connection ||
          presence.presenceSessionId !=
              authority.currentPresence?.presenceSessionId) {
        return;
      }
      if (data['connectionId'] != connection ||
          data['peers'] is! List ||
          (data['peers'] as List).length > 4 ||
          data['events'] is! List ||
          (data['events'] as List).length > 64) {
        throw const FormatException('invalid_live_poll');
      }
      runtimeChatUtc(data['snapshotAt']);
      final peers = (data['peers'] as List)
          .map(LiveCompanionPeer.fromJson)
          .toList();
      if (peers.map((p) => p.presenceSessionId).toSet().length !=
              peers.length ||
          peers.any((p) => p.presenceSessionId == _presenceId)) {
        throw const FormatException('invalid_live_peers');
      }
      _acks.removeAll(acknowledged);
      _peers
        ..clear()
        ..addAll(peers);
      _lastPoll = _now();
      online.value = true;
      status.value = '';
      _assemblies.removeWhere(
        (_, a) =>
            !hasPeer(a.source) ||
            _now().difference(a.created) > const Duration(seconds: 60),
      );
      for (final raw in data['events'] as List) {
        _check();
        if (connection != _connection) return;
        final event = LiveCompanionEvent.fromJson(raw);
        try {
          await _receive(event);
        } on FormatException {
          /* malformed peer data cannot block the bounded queue */
        } on TypeError {
          /* strict dynamic decoding must not poison the transport queue */
        }
        _check();
        _acks.add(event.eventId);
      }
    } catch (error) {
      if (isCurrent) {
        online.value = false;
        _peers.clear();
        _assemblies.clear();
        status.value = error is LiveCompanionSyncException
            ? error.code
            : 'LIVE_SYNC_UNAVAILABLE';
      }
      rethrow;
    }
  }

  Future<List<String>> publish(
    String kind,
    Map<String, Object?> payload, {
    required List<String> targets,
    String? eventId,
  }) async {
    _check();
    if (targets.isEmpty) return const [];
    if (targets.length > 4 || targets.any((id) => !hasPeer(id))) {
      throw const LiveCompanionSyncException('LIVE_SYNC_PEER_OFFLINE');
    }
    final id = eventId ?? _newId();
    final deadline = _now().add(const Duration(seconds: 45));
    while (isCurrent) {
      try {
        final data = await gateway.request('publish', {
          ..._actor(),
          'eventId': id,
          'targetPresenceSessionIds': targets,
          'kind': kind,
          'payload': payload,
        });
        _check();
        if (data['deliveredTo'] is! List) {
          throw const FormatException('invalid_live_publish');
        }
        final delivered = List<String>.from(data['deliveredTo'] as List);
        if (delivered.toSet().length != targets.toSet().length ||
            !delivered.toSet().containsAll(targets)) {
          throw const LiveCompanionSyncException('LIVE_SYNC_PEER_OFFLINE');
        }
        return delivered;
      } on LiveCompanionSyncException catch (e) {
        if (!e.code.contains('FULL') &&
                !e.code.contains('LIMIT') &&
                !e.code.contains('CAPACITY') ||
            !_now().isBefore(deadline)) {
          rethrow;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
    }
    throw const LiveCompanionSyncException('ACCOUNT_UNAVAILABLE');
  }

  Future<void> publishMedia(
    List<ChatAttachment> attachments,
    List<String> targets,
  ) async {
    if (attachments.length > 4 ||
        attachments.fold<int>(0, (n, a) => n + a.byteLength) >
            12 * 1024 * 1024) {
      throw const FormatException('live_media_limit');
    }
    for (final attachment in attachments) {
      final prepared = await media.read(attachment);
      _check();
      if (prepared == null) {
        throw const LiveCompanionSyncException('MEDIA_UNAVAILABLE');
      }
      const size = 96 * 1024;
      final total = (prepared.bytes.length / size).ceil();
      for (var index = 0; index < total; index++) {
        await publish('media_chunk', {
          'id': attachment.id,
          'index': index,
          'total': total,
          if (index == 0) 'attachment': attachment.toJson(),
          if (index == 0) 'mime': prepared.mime,
          'data': base64Encode(
            Uint8List.sublistView(
              prepared.bytes,
              index * size,
              min((index + 1) * size, prepared.bytes.length),
            ),
          ),
        }, targets: targets);
      }
    }
  }

  Future<void> _receive(LiveCompanionEvent event) async {
    _check();
    if (!hasPeer(event.sourcePresenceSessionId)) return;
    switch (event.kind) {
      case 'media_chunk':
        await _receiveMedia(event);
        break;
      case 'chat_message':
        await _receiveChat(event);
        break;
      case 'memory_entry':
      case 'memory_delete':
        if (memoryLedger != null) {
          await memoryLedger!.importOnlineMemoryChange(
            event.payload,
            sourceInstallationId: event.sourceInstallationId,
            sourceIsOwner: peers.any(
              (p) =>
                  p.presenceSessionId == event.sourcePresenceSessionId &&
                  p.canShareReviewedMemory,
            ),
            isCurrent: () =>
                isCurrent && hasPeer(event.sourcePresenceSessionId),
          );
        }
        await memoryReceiver?.call(event);
        break;
    }
    _check();
  }

  Future<void> _receiveMedia(LiveCompanionEvent event) async {
    final body = event.payload;
    if (body.keys.any(
          (key) => !const {
            'id',
            'index',
            'total',
            'attachment',
            'mime',
            'data',
          }.contains(key),
        ) ||
        !runtimeChatContentHash(body['id']) ||
        body['index'] is! int ||
        body['total'] is! int ||
        body['data'] is! String ||
        (body['data'] as String).length > 128 * 1024) {
      throw const FormatException('invalid_live_media');
    }
    final index = body['index'] as int,
        total = body['total'] as int,
        id = body['id'] as String;
    if (total < 1 || total > 128 || index < 0 || index >= total) {
      throw const FormatException('invalid_live_media_index');
    }
    final key = '${event.sourcePresenceSessionId}:$id';
    if (index == 0) {
      if (body['attachment'] is! Map || body['mime'] is! String) {
        throw const FormatException('invalid_live_media_header');
      }
      final attachment = ChatAttachment.fromJson(
        Map<String, Object?>.from(body['attachment'] as Map),
      );
      if (attachment.id != id ||
          total != (attachment.byteLength / (96 * 1024)).ceil() ||
          !const {
            'image/jpeg',
            'video/mp4',
            'video/quicktime',
          }.contains(body['mime']) ||
          (attachment.kind == 'image') != (body['mime'] == 'image/jpeg')) {
        throw const FormatException('invalid_live_media_header');
      }
      if (await media.read(attachment) != null) return;
      _check();
      if (_assemblies.length >= 4 ||
          _assemblies.values.fold<int>(
                    0,
                    (n, a) => n + a.attachment.byteLength,
                  ) +
                  attachment.byteLength >
              24 * 1024 * 1024) {
        throw const FormatException('live_media_capacity');
      }
      _assemblies[key] = _MediaAssembly(
        attachment,
        body['mime'] as String,
        total,
        event.sourcePresenceSessionId,
        _now(),
      );
    }
    final assembly = _assemblies[key];
    if (assembly == null) return;
    if (assembly.total != total) {
      throw const FormatException('live_media_changed');
    }
    final bytes = base64Decode(body['data'] as String);
    if (bytes.length !=
        min(96 * 1024, assembly.attachment.byteLength - index * 96 * 1024)) {
      throw const FormatException('live_media_chunk_size');
    }
    final existing = assembly.chunks[index];
    if (existing != null && base64Encode(existing) != body['data']) {
      throw const FormatException('live_media_changed');
    }
    assembly.chunks[index] = bytes;
    if (assembly.chunks.length == total) {
      _assemblies.remove(key);
      final builder = BytesBuilder(copy: false);
      for (var n = 0; n < total; n++) {
        builder.add(assembly.chunks[n]!);
      }
      final original = builder.takeBytes();
      if (original.length != assembly.attachment.byteLength ||
          sha256.convert(original).toString() != id) {
        throw const FormatException('live_media_integrity');
      }
      await media.persist(
        PreparedChatMedia(assembly.attachment, original, assembly.mime),
      );
    }
  }

  void _observeChats(List<RecordSnapshot<int, Map<String, Object?>>> records) {
    if (!isCurrent) return;
    final changes = <ChatMessage>[];
    for (final record in records) {
      final digest = sha256
          .convert(utf8.encode(jsonEncode(record.value)))
          .toString();
      if (_seeded && _seenChat[record.key] != digest) {
        changes.add(ChatMessage.fromJson(record.value, id: record.key));
      }
      _seenChat[record.key] = digest;
    }
    _seeded = true;
    _seenChat.removeWhere((id, _) => !records.any((r) => r.key == id));
    for (final message in changes) {
      if (!message.isModelContextEligible ||
          message.idempotencyKey?.startsWith('live-sync:') == true ||
          message.idempotencyKey?.startsWith('runtime-chat:') == true) {
        continue;
      }
      final targets = peers.map((p) => p.presenceSessionId).toList();
      if (targets.isEmpty) continue;
      _enqueueLocal(() async {
        _check();
        final record = _origins.record(message.id!);
        var value = await record.get(database.raw);
        _check();
        if (value == null) {
          value = {'id': _newId()};
          await record.put(database.raw, value);
        }
        await publishMedia(message.attachments, targets);
        await publish('chat_message', {
          'id': value['id'],
          'message': message.toJson(),
        }, targets: targets);
      });
    }
  }

  void _enqueueLocal(Future<void> Function() work) {
    // This is a small in-process write serializer, never an offline outbox.
    if (!isCurrent || peers.isEmpty || _queuedWork >= 64) return;
    _queuedWork++;
    _localWork = _localWork
        .then((_) async {
          if (isCurrent && peers.isNotEmpty) await work();
        })
        .catchError((Object _, StackTrace _) {})
        .whenComplete(() => _queuedWork--);
  }

  Future<void> _receiveChat(LiveCompanionEvent event) async {
    final payload = event.payload;
    if (payload.length != 2 || payload['message'] is! Map) {
      throw const FormatException('invalid_live_chat');
    }
    final id = runtimeChatIdentifier(payload['id'] as String);
    final raw = Map<String, Object?>.from(payload['message'] as Map);
    const keys = {
      'sessionId',
      'senderId',
      'receiverId',
      'content',
      'timestamp',
      'isUserMessage',
      'turnOrigin',
      'turnId',
      'utteranceId',
      'sequence',
      'deliveryStatus',
      'attachments',
      'visualContext',
      'idempotencyKey',
      'outreachId',
    };
    if (raw.keys.any((key) => !keys.contains(key)) ||
        raw['content'] is! String ||
        (raw['content'] as String).runes.length > 16000 ||
        raw['isUserMessage'] is! bool ||
        raw['sessionId'] != 'self' ||
        raw['senderId'] != (raw['isUserMessage'] == true ? 'user' : 'self') ||
        raw['receiverId'] != (raw['isUserMessage'] == true ? 'self' : 'user')) {
      throw const FormatException('invalid_live_chat');
    }
    runtimeChatUtc(raw['timestamp']);
    final message = ChatMessage.fromJson(raw)..idempotencyKey = 'live-sync:$id';
    if (!message.isModelContextEligible ||
        message.visualContext != null &&
            message.visualContext!.length > 12000 ||
        message.attachments.fold<int>(0, (n, a) => n + a.byteLength) >
            12 * 1024 * 1024) {
      throw const FormatException('invalid_live_chat');
    }
    for (final attachment in message.attachments) {
      if (await media.read(attachment) == null) {
        throw const FormatException('live_chat_media_missing');
      }
    }
    _check();
    await database.saveOnlineChatMessage(
      message,
      isCurrent: () => isCurrent && hasPeer(event.sourcePresenceSessionId),
      onInserted: () {
        if (isCurrent && hasPeer(event.sourcePresenceSessionId)) {
          revision.value++;
          _receivedChats.add(
            LiveCompanionChatMessage(
              eventId: event.eventId,
              sourcePresenceSessionId: event.sourcePresenceSessionId,
              sourceInstallationId: event.sourceInstallationId,
              message: message,
            ),
          );
        }
      },
    );
  }

  Future<void> shutdown() async {
    if (_retired) return;
    Map<String, Object?>? actor;
    try {
      actor = _actor();
    } catch (_) {}
    _retired = true;
    unawaited(_receivedChats.close());
    online.value = false;
    _peers.clear();
    _assemblies.clear();
    await _chatWatcher?.cancel();
    await _memoryWatcher?.cancel();
    if (actor != null) {
      try {
        await gateway
            .request('close', actor)
            .timeout(const Duration(seconds: 2));
      } catch (_) {}
    }
    gateway.close();
    await Future.wait<void>(
      [
        ?_loop,
        ?_polling,
        _localWork,
      ].map((future) => future.catchError((Object _, StackTrace _) {})),
    );
  }

  @override
  void onClose() {
    unawaited(shutdown());
    super.onClose();
  }

  static String randomId() {
    final random = Random.secure();
    return List.generate(
      24,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }
}

final class _MediaAssembly {
  _MediaAssembly(
    this.attachment,
    this.mime,
    this.total,
    this.source,
    this.created,
  );
  final ChatAttachment attachment;
  final String mime, source;
  final int total;
  final DateTime created;
  final Map<int, Uint8List> chunks = {};
}

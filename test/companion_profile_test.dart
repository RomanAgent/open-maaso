import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:image/image.dart' as image;
import 'package:maaso/src/features/identity/application/companion_profile_service.dart';
import 'package:maaso/src/features/identity/application/companion_setup_controller.dart';
import 'package:maaso/src/features/identity/data/companion_profile_http_client.dart';
import 'package:maaso/src/features/identity/data/companion_profile_store.dart';
import 'package:maaso/src/features/identity/domain/companion_profile.dart';

class _Store implements CompanionProfileStore {
  CompanionProfile? value;
  bool fail = false;
  @override
  Future<CompanionProfile?> read() async => value;
  @override
  Future<void> write(CompanionProfile profile) async {
    if (fail) throw StateError('disk unavailable');
    value = CompanionProfile.fromJson(profile.toJson());
  }
}

class _Gateway implements CompanionProfileGateway {
  @override
  String requestContextKey = 'account-a';
  CompanionProfile value = CompanionProfile();
  Future<CompanionProfile> Function()? fetchOverride;
  Future<CompanionProfile> Function(CompanionProfile)? updateOverride;
  int updates = 0;
  @override
  Future<CompanionProfile> fetch({required String expectedContextKey}) async =>
      fetchOverride == null ? value : await fetchOverride!();
  @override
  Future<CompanionProfile> update({
    required String expectedContextKey,
    required CompanionProfile profile,
  }) async {
    updates++;
    if (updateOverride != null) return updateOverride!(profile);
    if (profile.version != value.version) {
      throw const CompanionProfileException(CompanionProfileFailure.conflict);
    }
    return value = profile.copyWith(version: profile.version + 1);
  }
}

CompanionProfile _complete([int version = 1]) => CompanionProfile(
  version: version,
  avatarPreset: 'orbit',
  agentGender: 'female',
  interests: const ['music'],
  onboardingVersion: 1,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'foreground sync refreshes explicit profile, pauses and retires',
    (tester) async {
      final gateway = _Gateway()..value = _complete();
      final store = _Store();
      var reads = 0, projections = 0;
      gateway.fetchOverride = () async {
        reads++;
        return gateway.value;
      };
      final service = CompanionProfileService(
        gateway: gateway,
        store: store,
        isCurrent: () => true,
        projectProfile: (_) async {
          projections++;
        },
      );
      service.startSync();
      await tester.pump();
      expect(reads, 1);
      expect(projections, 1);
      await tester.pump(const Duration(seconds: 30));
      expect(reads, 2);
      expect(projections, 1);
      service.didChangeAppLifecycleState(AppLifecycleState.paused);
      gateway.value = _complete(2).copyWith(agentGender: 'male');
      await tester.pump(const Duration(seconds: 60));
      expect(reads, 2);
      service.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(service.profile.value!.agentGender, 'male');
      expect(projections, 2);
      await service.shutdown();
      await tester.pump(const Duration(seconds: 60));
      expect(reads, 3);
      expect(service.profile.value, isNull);
    },
  );

  test(
    'HTTP unchanged profile uses account-bound ETag without repeated avatar body',
    () async {
      var calls = 0, account = 'account-a';
      final client = CompanionProfileHttpClient(
        baseUri: () => Uri.parse('https://example.invalid/'),
        accountId: () => account,
        accessToken: () async => 'token',
        client: MockClient((request) async {
          calls++;
          expect(request.followRedirects, isFalse);
          expect(request.headers['Cache-Control'], 'no-store');
          if (calls == 2) {
            expect(request.headers['If-None-Match'], '"maaso-profile-v1"');
            return http.Response(
              '',
              304,
              headers: {'etag': '"maaso-profile-v1"'},
            );
          }
          expect(request.headers['If-None-Match'], isNull);
          return http.Response(
            jsonEncode({'code': 'OK', 'data': _complete().toJson()}),
            200,
          );
        }),
      );
      final first = await client.fetch(
        expectedContextKey: client.requestContextKey,
      );
      final same = await client.fetch(
        expectedContextKey: client.requestContextKey,
      );
      expect(identical(first, same), isTrue);
      account = 'account-b';
      await client.fetch(expectedContextKey: client.requestContextKey);
      expect(calls, 3);
      client.close();
    },
  );

  test(
    'profile only admits explicit setup fields and immutable bounded choices',
    () {
      final profile = _complete();
      expect(CompanionProfile.fromJson(profile.toJson()).completed, isTrue);
      expect(CompanionProfile().completed, isFalse);
      expect(() => profile.interests.add('gaming'), throwsUnsupportedError);
      for (final key in [
        'memory',
        'longTermMemory',
        'agentToken',
        'notes',
        'soul',
        'master',
        'accountUuid',
        'modelUrl',
        'avatarPath',
      ]) {
        expect(
          () => CompanionProfile.fromJson({...profile.toJson(), key: 'secret'}),
          throwsFormatException,
        );
      }
      expect(
        () => CompanionProfile(interests: ['music', 'music']),
        throwsFormatException,
      );
      expect(
        () => CompanionProfile(interests: ['freeform private memory']),
        throwsFormatException,
      );
      expect(
        () => CompanionProfile(agentGender: 'unknown'),
        throwsFormatException,
      );
      expect(
        () => CompanionProfile(onboardingVersion: 1),
        throwsFormatException,
      );
      expect(() => CompanionProfile(version: -1), throwsFormatException);
      expect(
        () => CompanionProfile(version: 9007199254740992),
        throwsFormatException,
      );
    },
  );

  test('uploaded avatar becomes a bounded metadata-free square JPEG', () {
    final source = image.Image(width: 500, height: 320);
    image.fill(source, color: image.ColorRgb8(80, 120, 170));
    source.textData = {'private': 'gps or source path'};
    final normalized = normalizeCompanionAvatar(
      Uint8List.fromList(image.encodePng(source)),
    );
    final bytes = base64Decode(normalized);
    final decoded = image.decodeJpg(bytes)!;
    expect(decoded.width, 256);
    expect(decoded.height, 256);
    expect(bytes.length, lessThanOrEqualTo(CompanionProfile.maxAvatarBytes));
    expect(
      ascii.decode(bytes, allowInvalid: true),
      isNot(contains('source path')),
    );
    expect(CompanionProfile(avatarJpeg: normalized).avatarBytes, bytes);
    expect(
      () => normalizeCompanionAvatar(Uint8List.fromList([1, 2, 3])),
      throwsFormatException,
    );
    expect(
      () => CompanionProfile(avatarJpeg: 'https://photo.invalid/a.jpg'),
      throwsFormatException,
    );
    expect(
      () => CompanionProfile(avatarPreset: 'orbit', avatarJpeg: normalized),
      throwsFormatException,
    );
  });

  test(
    'first profile fetch and save use revisions without uploading memory',
    () async {
      final gateway = _Gateway();
      final store = _Store();
      final projected = <CompanionProfile>[];
      final service = CompanionProfileService(
        gateway: gateway,
        store: store,
        isCurrent: () => true,
        projectProfile: (p) async => projected.add(p),
      );
      await service.restore();
      expect(service.profile.value, isNull);
      await service.refresh();
      expect(service.onboardingCompleted, isFalse);
      final saved = await service.save(_complete(0));
      expect(saved.version, 1);
      expect(service.onboardingCompleted, isTrue);
      expect(store.value!.version, 1);
      expect(projected.last.agentGender, 'female');
      expect(gateway.updates, 1);
      service.onClose();
      expect(service.profile.value, isNull);
    },
  );

  test(
    'same account offline read preserves completed cached choices',
    () async {
      final gateway = _Gateway()
        ..fetchOverride = () async => throw const CompanionProfileException(
          CompanionProfileFailure.unavailable,
        );
      final store = _Store()..value = _complete(5);
      final service = CompanionProfileService(
        gateway: gateway,
        store: store,
        isCurrent: () => true,
      );
      await service.restore();
      await expectLater(
        service.refresh(),
        throwsA(isA<CompanionProfileException>()),
      );
      expect(service.profile.value!.version, 5);
      expect(service.onboardingCompleted, isTrue);
    },
  );

  test('slow refresh cannot overwrite newer saved revision', () async {
    final gateway = _Gateway()..value = _complete(1);
    final service = CompanionProfileService(
      gateway: gateway,
      store: _Store(),
      isCurrent: () => true,
    );
    await service.refresh();
    final save = Completer<CompanionProfile>();
    gateway.updateOverride = (_) => save.future;
    final saving = service.save(_complete(1).copyWith(avatarPreset: 'moon'));
    final read = Completer<CompanionProfile>();
    gateway.fetchOverride = () => read.future;
    final refreshing = service.refresh();
    save.complete(_complete(2).copyWith(avatarPreset: 'moon'));
    await saving;
    read.complete(_complete(1));
    await refreshing;
    expect(service.profile.value!.avatarPreset, 'moon');
    expect(service.profile.value!.version, 2);
  });

  test(
    'same revision changed payload is invalid instead of silent overwrite',
    () async {
      final gateway = _Gateway()..value = _complete();
      final service = CompanionProfileService(
        gateway: gateway,
        store: _Store(),
        isCurrent: () => true,
      );
      await service.refresh();
      gateway.value = _complete().copyWith(avatarPreset: 'moon');
      await expectLater(
        service.refresh(),
        throwsA(isA<CompanionProfileException>()),
      );
      expect(service.profile.value!.avatarPreset, 'orbit');
    },
  );

  test(
    'late response after account retirement cannot publish or write cache',
    () async {
      final gateway = _Gateway();
      final store = _Store();
      final response = Completer<CompanionProfile>();
      gateway.fetchOverride = () => response.future;
      var current = true;
      final service = CompanionProfileService(
        gateway: gateway,
        store: store,
        isCurrent: () => current,
      );
      final pending = service.refresh();
      await Future<void>.delayed(Duration.zero);
      current = false;
      await service.shutdown();
      response.complete(_complete());
      await expectLater(pending, throwsA(isA<CompanionProfileException>()));
      expect(service.profile.value, isNull);
      expect(store.value, isNull);
    },
  );

  test(
    'CAS conflict never retries a write and leaves known profile intact',
    () async {
      final gateway = _Gateway()..value = _complete();
      final service = CompanionProfileService(
        gateway: gateway,
        store: _Store(),
        isCurrent: () => true,
      );
      await service.refresh();
      gateway.value = _complete(2);
      await expectLater(
        service.save(_complete()),
        throwsA(isA<CompanionProfileException>()),
      );
      expect(gateway.updates, 1);
      expect(service.profile.value!.version, 1);
    },
  );

  test(
    'HTTP sends bounded private fields and account from injected token only',
    () async {
      late http.Request sent;
      final client = CompanionProfileHttpClient(
        baseUri: () => Uri.parse('https://maaso.test/'),
        accountId: () => 'account-a',
        accessToken: () async => 'token-a',
        client: MockClient((request) async {
          sent = request;
          return http.Response(
            jsonEncode({'code': 'OK', 'data': _complete(8).toJson()}),
            200,
          );
        }),
      );
      await client.update(
        expectedContextKey: client.requestContextKey,
        profile: _complete(7),
      );
      expect(sent.url.path, '/v1/identity/companion-profile/update');
      expect(sent.headers['Authorization'], 'Bearer token-a');
      final body = jsonDecode(sent.body) as Map;
      expect(body.keys.toSet(), {
        'expectedVersion',
        'avatarPreset',
        'avatarJpeg',
        'agentGender',
        'interests',
        'onboardingVersion',
      });
      expect(body['expectedVersion'], 7);
      expect(sent.body, isNot(contains('account-a')));
    },
  );

  test(
    'HTTP invalidates request if account changes while fetching credentials',
    () async {
      var account = 'a';
      var calls = 0;
      final token = Completer<String>();
      final client = CompanionProfileHttpClient(
        baseUri: () => Uri.parse('https://maaso.test/'),
        accountId: () => account,
        accessToken: () => token.future,
        client: MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      );
      final request = client.fetch(
        expectedContextKey: client.requestContextKey,
      );
      account = 'b';
      token.complete('token-a');
      await expectLater(request, throwsA(isA<CompanionProfileException>()));
      expect(calls, 0);
    },
  );

  test(
    'HTTP rejects malformed or oversized server payload and classifies conflict',
    () async {
      for (final fixture in [
        (200, '{}'),
        (200, 'x' * (193 * 1024)),
        (409, '{}'),
        (503, '{}'),
      ]) {
        final client = CompanionProfileHttpClient(
          baseUri: () => Uri.parse('https://maaso.test/'),
          accountId: () => 'a',
          accessToken: () async => 'token',
          client: MockClient(
            (_) async => http.Response(fixture.$2, fixture.$1),
          ),
        );
        await expectLater(
          client.fetch(expectedContextKey: client.requestContextKey),
          throwsA(isA<CompanionProfileException>()),
        );
      }
    },
  );
}

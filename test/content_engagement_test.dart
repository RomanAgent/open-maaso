import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:maaso/src/features/content_engagement/application/content_consumption_controller.dart';
import 'package:maaso/src/features/content_engagement/data/content_engagement_client.dart';
import 'package:maaso/src/features/content_engagement/domain/content_engagement.dart';

Map<String, Object?> sessionJSON() => {
  'sessionId': 'session',
  'sequence': 0,
  'state': 'active',
  'activeMillis': 0,
  'expiresAt': '2026-09-12T13:00:00Z',
};
http.Response ok(Object data) =>
    http.Response(jsonEncode({'code': 'OK', 'data': data}), 200);

class ContentTestGateway implements ContentEngagementGateway {
  @override
  String contextKey = 'environment|account';
  int starts = 0;
  int finishes = 0;
  bool failPulseOnce = false;
  Completer<ContentConsumptionSession>? startWait;
  final pulses = <({int sequence, String event, int progress})>[];

  ContentConsumptionSession value(int sequence, {String state = 'active'}) =>
      ContentConsumptionSession(
        sessionId: 'session',
        sequence: sequence,
        state: state,
        activeMillis: sequence * 10000,
        expiresAt: DateTime.utc(2026, 9, 12, 13),
      );
  @override
  Future<ContentConsumptionSession> start(
    ContentConsumptionTarget target,
    String requestId,
  ) async {
    starts++;
    return startWait?.future ?? value(0);
  }

  @override
  Future<ContentConsumptionSession> pulse(
    String sessionId,
    int sequence,
    String event,
    int progress,
  ) async {
    pulses.add((sequence: sequence, event: event, progress: progress));
    if (failPulseOnce) {
      failPulseOnce = false;
      throw Exception('timeout');
    }
    return value(sequence);
  }

  @override
  Future<ContentConsumptionSession> finish(
    String sessionId,
    int sequence,
  ) async {
    finishes++;
    return value(sequence, state: 'recorded');
  }
}

void main() {
  const target = ContentConsumptionTarget(ContentConsumptionKind.game, 'game');

  test(
    'game consumption uses the current account and bounded target',
    () async {
      Map<String, dynamic>? posted;
      final client = ContentEngagementClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => 'owner',
        accessToken: () async => 'token',
        client: MockClient((request) async {
          expect(request.url.path, '/v1/content-engagement/consumption/start');
          expect(request.headers['Authorization'], 'Bearer token');
          posted = jsonDecode(request.body) as Map<String, dynamic>;
          return ok(sessionJSON());
        }),
      );
      final session = await client.start(target, 'request');
      expect(session.sessionId, 'session');
      expect(posted, {
        'requestId': 'request',
        'kind': 'game',
        'contentId': 'game',
      });
      client.onClose();
    },
  );

  test(
    'account changes across token refresh never dispatch activity',
    () async {
      var account = 'first';
      var dispatched = 0;
      final token = Completer<String>();
      final client = ContentEngagementClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => account,
        accessToken: () => token.future,
        client: MockClient((_) async {
          dispatched++;
          return ok(sessionJSON());
        }),
      );
      final future = client.start(target, 'request');
      account = 'second';
      token.complete('new-token');
      await expectLater(future, throwsA(isA<ContentEngagementException>()));
      expect(dispatched, 0);
      client.onClose();
    },
  );

  test('invalid activity session data fails parsing', () async {
    for (final invalid in [
      {...sessionJSON(), 'sequence': -1},
      {...sessionJSON(), 'activeMillis': 1800001},
      {...sessionJSON(), 'state': 'unknown'},
    ]) {
      final client = ContentEngagementClient(
        baseUri: () => Uri.parse('https://example.test/'),
        accountId: () => 'owner',
        accessToken: () async => 'token',
        client: MockClient((_) async => ok(invalid)),
      );
      await expectLater(client.start(target, 'request'), throwsFormatException);
      client.onClose();
    }
  });

  test('activity response arriving in another account is discarded', () async {
    var account = 'first';
    final response = Completer<http.Response>();
    final client = ContentEngagementClient(
      baseUri: () => Uri.parse('https://example.test/'),
      accountId: () => account,
      accessToken: () async => 'token',
      client: MockClient((_) => response.future),
    );
    final future = client.start(target, 'request');
    await Future<void>.delayed(Duration.zero);
    account = 'second';
    response.complete(ok(sessionJSON()));
    await expectLater(future, throwsA(isA<ContentEngagementException>()));
    client.onClose();
  });

  test('failed pulse retries the same sequence and exact progress', () async {
    final gateway = ContentTestGateway()..failPulseOnce = true;
    final controller = ContentConsumptionController(
      gateway: gateway,
      target: const ContentConsumptionTarget(
        ContentConsumptionKind.game,
        'game',
      ),
      automaticTicks: false,
    );
    await controller.setVisible(true);
    controller.recordProgress(4000);
    await controller.tick();
    controller.recordProgress(9000);
    await controller.tick();
    expect(gateway.pulses[0], gateway.pulses[1]);
    await controller.tick();
    expect(gateway.pulses.last.progress, 9000);
    await controller.close();
    expect(gateway.finishes, 1);
  });

  test(
    'leaving while start waits finishes only the original session',
    () async {
      final gateway = ContentTestGateway()
        ..startWait = Completer<ContentConsumptionSession>();
      final controller = ContentConsumptionController(
        gateway: gateway,
        target: const ContentConsumptionTarget(
          ContentConsumptionKind.game,
          'game',
        ),
        automaticTicks: false,
      );
      final start = controller.setVisible(true);
      await Future<void>.delayed(Duration.zero);
      final hidden = controller.setVisible(false);
      gateway.startWait!.complete(gateway.value(0));
      await start;
      await hidden;
      expect(gateway.finishes, 1);
      expect(gateway.pulses, isEmpty);
      await controller.close();
    },
  );

  test(
    'retired account never submits a finish with the next account token',
    () async {
      final gateway = ContentTestGateway();
      final controller = ContentConsumptionController(
        gateway: gateway,
        target: const ContentConsumptionTarget(
          ContentConsumptionKind.game,
          'game',
        ),
        automaticTicks: false,
      );
      await controller.setVisible(true);
      gateway.contextKey = 'environment|other';
      await controller.tick();
      await controller.close();
      expect(gateway.pulses, isEmpty);
      expect(gateway.finishes, 0);
    },
  );

  test('passive game heartbeat does not invent play progress', () async {
    final gateway = ContentTestGateway();
    final controller = ContentConsumptionController(
      gateway: gateway,
      target: const ContentConsumptionTarget(
        ContentConsumptionKind.game,
        'game',
      ),
      automaticTicks: false,
    );
    await controller.setVisible(true);
    await controller.tick();
    expect(gateway.pulses.single.event, 'heartbeat');
    controller.recordProgress(1000);
    await controller.tick();
    expect(gateway.pulses.last.event, 'game_progress');
    await controller.close();
  });
}

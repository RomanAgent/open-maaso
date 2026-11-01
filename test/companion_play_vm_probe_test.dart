import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../tool/companion_play/vm_probe.dart';

CompanionProbeCommand command(
  int ordinal, {
  String name = 'inspect',
  Object? value,
}) => CompanionProbeCommand.parse({
  'invocationId': 'play_${ordinal.toRadixString(16).padLeft(32, '0')}',
  'command': name,
  'value': ?value,
});

final class _Vm {
  _Vm(this.host);
  CompanionProbeHost host;
  var submits = 0;
  var copies = 1;
  var truncate = false;
  var truncateAgain = false;
  var lostAck = false;
  Object? last;
  final expressions = <String>[];

  Map<String, dynamic> string(Object? value, {bool full = false}) {
    final encoded = jsonEncode(value);
    return {
      'type': full ? 'Instance' : '@Instance',
      'kind': 'String',
      'id': 'objects/receipt',
      'valueAsString': encoded,
      'length': encoded.length,
      if ((!full && truncate) || (full && truncateAgain))
        'valueAsStringIsTruncated': true,
    };
  }

  Future<Map<String, dynamic>> rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    switch (method) {
      case 'getVM':
        return {
          'isolates': [
            {'id': 'isolates/main'},
          ],
        };
      case 'getIsolate':
        return {
          'libraries': [
            for (var i = 0; i < copies; i++)
              {
                'uri': 'file:///synthetic/tool/companion_play_probe_main.dart',
                'id': 'libraries/$i',
              },
          ],
        };
      case 'getObject':
        expect(params['offset'], 0);
        expect(params['count'], CompanionPlayVmProbe.maximumReceiptBytes + 1);
        return string(last, full: true);
      case 'evaluate':
        final expression = params['expression']! as String;
        expressions.add(expression);
        final args = RegExp(
          "'([^']*)'",
        ).allMatches(expression).map((m) => m[1]!).toList();
        if (expression.startsWith('readCompanionPlayProbeReceipt(')) {
          last = host.read(args[0], args[1]);
          return string(last);
        }
        if (expression.startsWith('submitCompanionPlayProbe(')) {
          submits++;
          host.submit(args[0], args[1]);
          if (lostAck) throw TimeoutException('synthetic_lost_ack');
          return {'type': '@Instance', 'kind': 'Null'};
        }
    }
    throw StateError('unexpected_rpc');
  }
}

void main() {
  test(
    'fixed protocol rejects text, tokens, scripts and undeclared arguments',
    () {
      for (final value in [
        {
          'invocationId': command(1).invocationId,
          'command': 'evaluate',
          'value': 'alert(1)',
        },
        {
          'invocationId': command(1).invocationId,
          'command': 'human',
          'value': 'game.place',
        },
        {
          'invocationId': command(1).invocationId,
          'command': 'open',
          'value': '/tmp/custom.json',
        },
        {
          'invocationId': command(1).invocationId,
          'command': 'inspect',
          'token': 'private',
        },
        {'invocationId': "play_');bad('", 'command': 'inspect'},
        {
          'invocationId': command(1).invocationId,
          'command': 'commentary',
          'value': 'true',
        },
      ]) {
        expect(() => CompanionProbeCommand.parse(value), throwsFormatException);
      }
      for (final action in [
        'first_legal',
        'second_legal',
        'start',
        'collect',
      ]) {
        expect(command(1, name: 'human', value: action).value, action);
      }
      expect(command(1, name: 'start', value: 'spectator').command, 'start');
    },
  );

  test(
    'unique debug library, full bounded strings and loopback are required',
    () async {
      final host = CompanionProbeHost(
        admission: () =>
            () => true,
        execute: (_, _) async => {'phase': 'playing'},
      );
      final vm = _Vm(host)..copies = 2;
      await expectLater(
        CompanionPlayVmProbe(vm.rpc).run(command(1)),
        throwsStateError,
      );
      expect(vm.submits, 0);
      vm
        ..copies = 1
        ..truncate = true;
      expect(
        (await CompanionPlayVmProbe(
          vm.rpc,
          pause: () async {},
        ).run(command(1)))['status'],
        'completed',
      );
      vm.truncateAgain = true;
      await expectLater(
        CompanionPlayVmProbe(vm.rpc).run(command(1)),
        throwsStateError,
      );
      for (final uri in [
        'https://127.0.0.1:123/',
        'http://example.com:123/',
        'http://user@localhost:123/',
        'ws://127.0.0.1:123/?secret=1',
      ]) {
        expect(() => companionLoopbackUri(uri), throwsFormatException);
      }
      expect(
        companionLoopbackUri('http://127.0.0.1:123/private/').path,
        '/private/ws',
      );
    },
  );

  test(
    'lost ACK and replay read original result without a second operation',
    () async {
      var operations = 0, before = 0;
      final host = CompanionProbeHost(
        admission: () =>
            () => true,
        execute: (_, _) async {
          operations++;
          return {'phase': 'playing', 'modelCalls': 1};
        },
      );
      final vm = _Vm(host)..lostAck = true;
      final request = command(1, name: 'start', value: 'partner');
      final result = await CompanionPlayVmProbe(vm.rpc, pause: () async {}).run(
        request,
        beforeDispatch: (_) async {
          expect(vm.submits, 0);
          before++;
        },
      );
      expect(result['status'], 'completed');
      expect(before, 1);
      expect(operations, 1);
      expect(vm.submits, 1);
      final replay = await CompanionPlayVmProbe(
        vm.rpc,
      ).run(request, recoveryOnly: true, expectedHostInstance: host.instance);
      expect(replay['status'], 'completed');
      expect(operations, 1);
      expect(vm.submits, 1);
      expect(
        vm.expressions.every(
          (e) =>
              e.startsWith('readCompanionPlayProbeReceipt(') ||
              e.startsWith('submitCompanionPlayProbe('),
        ),
        isTrue,
      );
    },
  );

  test(
    'body conflict and host restart never dispatch original operation again',
    () async {
      var operations = 0;
      CompanionProbeHost makeHost() => CompanionProbeHost(
        admission: () =>
            () => true,
        execute: (_, _) async {
          operations++;
          return {};
        },
      );
      final original = makeHost(), vm = _Vm(original);
      await CompanionPlayVmProbe(vm.rpc, pause: () async {}).run(command(1));
      final conflict = await CompanionPlayVmProbe(
        vm.rpc,
      ).run(command(1, name: 'pause'));
      expect(conflict['status'], 'invocation_conflict');
      expect(conflict.containsKey('snapshot'), isFalse);
      vm.host = makeHost();
      final recovered = await CompanionPlayVmProbe(vm.rpc).run(
        command(1),
        recoveryOnly: true,
        expectedHostInstance: original.instance,
      );
      expect(recovered['status'], 'host_restarted_unknown');
      expect(operations, 1);
      expect(vm.submits, 1);
    },
  );

  test(
    'one in flight, scope retirement and public-only output are enforced',
    () async {
      var current = true, operations = 0;
      final gate = Completer<Map<String, Object?>>();
      final host = CompanionProbeHost(
        admission: () =>
            () => current,
        execute: (_, guard) {
          expect(guard(), isTrue);
          operations++;
          return gate.future;
        },
      );
      final first = command(1), second = command(2);
      host.submit(first.encoded, host.instance);
      host.submit(second.encoded, host.instance);
      expect(host.read(second.invocationId, second.digest)['status'], 'busy');
      current = false;
      gate.complete({
        'phase': 'playing',
        'privateCards': [1, 2],
        'apiKey': 'secret',
      });
      await Future<void>.delayed(Duration.zero);
      expect(host.read(first.invocationId, first.digest)['status'], 'retired');
      expect(
        host.read(first.invocationId, first.digest).containsKey('snapshot'),
        isFalse,
      );
      expect(operations, 1);
      final snapshot = companionPublicSnapshot({
        'phase': 'playing',
        'view': {
          'cards': [1],
        },
        'comment': 'private provider text',
        'modelCalls': -1,
        'agentStatus': 'secret URL https://bad',
      });
      expect(snapshot, {
        'phase': 'playing',
        'modelCalls': null,
        'modelCallsKnown': false,
      });
    },
  );

  test(
    'pending recovery performs reads only and does not claim zero model calls',
    () async {
      final gate = Completer<Map<String, Object?>>();
      final host = CompanionProbeHost(
        admission: () =>
            () => true,
        execute: (_, _) => gate.future,
      );
      final vm = _Vm(host);
      final result = await CompanionPlayVmProbe(
        vm.rpc,
        pause: () async {},
      ).run(command(1));
      expect(result['status'], 'pending');
      final recovered = await CompanionPlayVmProbe(vm.rpc, pause: () async {})
          .run(
            command(1),
            recoveryOnly: true,
            expectedHostInstance: host.instance,
          );
      expect(recovered['status'], 'pending');
      expect(vm.submits, 1);
      gate.complete({});
      await Future<void>.delayed(Duration.zero);
      expect(
        (host.read(command(1).invocationId, command(1).digest)['snapshot']
            as Map)['modelCalls'],
        isNull,
      );
    },
  );
}

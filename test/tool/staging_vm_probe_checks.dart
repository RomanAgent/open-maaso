import 'dart:convert';
import 'dart:io';
import '../../tool/response_latency/staging_vm_probe.dart';

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

Future<void> rejects(Future<void> Function() call, String label) async {
  try {
    await call();
  } catch (_) {
    return;
  }
  throw StateError(label);
}

class FakeVm {
  bool ready = true;
  int targetCount = 1, polls = 0, invokes = 0;
  bool truncate = false, uncertainInvoke = false;
  final expressions = <String>[];
  Map<String, dynamic> stringValue(Object value) => {
    'type': '@Instance',
    'kind': 'String',
    'id': 'objects/sanitizedReceipt',
    'valueAsString': jsonEncode(value),
  };

  Future<Map<String, dynamic>> rpc(
    String method,
    Map<String, dynamic> p,
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
          'libraries': List.generate(
            targetCount,
            (i) => {
              'uri':
                  'file:///workspace/tool/conversation_proxy_probe_main.dart',
              'id': 'libraries/$i',
            },
          ),
        };
      case 'getObject':
        check(p['objectId'] == 'objects/sanitizedReceipt', 'receipt only');
        return stringValue({'status': 'completed', 'synthetic': true});
      case 'evaluate':
        check(p['targetId'] == 'libraries/0', 'selected library');
        final expression = p['expression'] as String;
        expressions.add(expression);
        if (expression == 'readConversationProxyReadiness()') {
          return stringValue({'canRunSingleProbe': ready});
        }
        if (expression == 'runConversationProxyCheck()') {
          invokes++;
          if (uncertainInvoke) throw StateError('uncertain dispatch');
          return {'type': '@Instance', 'kind': 'PlainInstance'};
        }
        if (expression == 'conversationProxyCheckReceipt') {
          if (polls++ == 0) return {'kind': 'Null', 'type': '@Instance'};
          return {
            ...stringValue({'status': 'completed', 'synthetic': true}),
            if (truncate) 'valueAsStringIsTruncated': true,
          };
        }
    }
    throw StateError('Unexpected RPC/expression');
  }
}

Future<void> main() async {
  check(
    loopbackWebSocketUri('http://127.0.0.1:8181/key=/').toString() ==
        'ws://127.0.0.1:8181/key=/ws',
    'VM URI conversion',
  );
  check(
    loopbackWebSocketUri('ws://localhost:8181/key=/ws').path == '/key=/ws',
    'no duplicate ws',
  );
  for (final uri in [
    'https://api-test.futurpals.com.cn',
    'http://127.0.0.1.evil:8181/',
    'http://127.0.0.1:8181/?expression=unsafe',
    'http://user:pass@127.0.0.1:8181/',
    'http://127.0.0.1/',
  ]) {
    await rejects(() async {
      loopbackWebSocketUri(uri);
    }, 'remote URI rejected');
  }
  final read = FakeVm();
  final only = await StagingVmProbe(read.rpc).inspect();
  check(
    only['status'] == 'readiness_only' && read.invokes == 0,
    'default never invokes',
  );
  final blocked = FakeVm()..ready = false;
  final notReady = await StagingVmProbe(blocked.rpc).inspect(runOnce: true);
  check(
    notReady['status'] == 'not_ready' && blocked.invokes == 0,
    'blocked never invokes',
  );
  for (final count in [0, 2]) {
    final wrong = FakeVm()..targetCount = count;
    await rejects(() async {
      await StagingVmProbe(wrong.rpc).inspect(runOnce: true);
    }, 'unique target');
    check(wrong.expressions.isEmpty, 'no wrong-target evaluate');
  }
  for (final truncated in [false, true]) {
    final vm = FakeVm()..truncate = truncated;
    final result = await StagingVmProbe(
      vm.rpc,
      pause: () async {},
    ).inspect(runOnce: true);
    check(
      result['status'] == 'completed' && vm.invokes == 1 && vm.polls == 2,
      'one invocation, receipt-only polling',
    );
  }
  final uncertain = FakeVm()..uncertainInvoke = true;
  final driver = StagingVmProbe(uncertain.rpc);
  await rejects(() async {
    await driver.inspect(runOnce: true);
  }, 'uncertain RPC');
  check(
    driver.invocationAttempted &&
        uncertain.invokes == 1 &&
        uncertain.polls == 0,
    'uncertain invocation never retried',
  );
  stdout.writeln(
    'Staging VM driver offline checks passed; no App or provider called.',
  );
}

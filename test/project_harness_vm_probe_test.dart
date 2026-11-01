import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import '../tool/project_harness/model_probe_host.dart';
import '../tool/project_harness/vm_probe.dart';

String input(
  int id, {
  String content = 'synthetic',
  bool reverse = false,
}) => base64Encode(
  utf8.encode(
    jsonEncode(
      reverse
          ? {
              'messages': [
                {'content': content, 'role': 'user'},
              ],
              'invocationId': 'eval_${id.toRadixString(16).padLeft(32, '0')}',
            }
          : {
              'invocationId': 'eval_${id.toRadixString(16).padLeft(32, '0')}',
              'messages': [
                {'role': 'user', 'content': content},
              ],
            },
    ),
  ),
);

class Vm {
  Vm(this.host);
  final ProjectModelProbeHost host;
  int invokes = 0, objectReads = 0, receiptReads = 0;
  bool truncate = false,
      truncateAgain = false,
      wrongLength = false,
      missingDigest = false;
  int? requestedCount;
  int buildReads = 0, buildRefreshes = 0;
  Map<String, Object?> buildReadiness = {
    'schemaVersion': 1,
    'check': 'project_build_v2',
    'status': 'blocked',
    'productionOnly': true,
    'creationReady': false,
    'modelCalls': 0,
    'modelExecutionInvoked': false,
    'credentialsExported': false,
  };
  Map<String, dynamic> string(Object? value, {bool full = false}) {
    final text = jsonEncode(value);
    return {
      'type': full ? 'Instance' : '@Instance',
      'kind': 'String',
      'id': 'objects/receipt',
      'length': text.length + (wrongLength ? 1 : 0),
      'valueAsString': text,
      if (truncate && !full || truncateAgain && full)
        'valueAsStringIsTruncated': true,
    };
  }

  Object? lastReceipt;
  Future<Map<String, dynamic>> rpc(
    String method,
    Map<String, dynamic> params,
  ) async {
    if (method == 'getVM') {
      return {
        'isolates': [
          {'id': 'isolates/main'},
        ],
      };
    }
    if (method == 'getIsolate') {
      return {
        'libraries': [
          {
            'uri': 'file:///fixture/tool/project_harness_probe_main.dart',
            'id': 'libraries/probe',
          },
        ],
      };
    }
    if (method == 'getObject') {
      objectReads++;
      requestedCount = params['count'] as int?;
      return string(lastReceipt, full: true);
    }
    final expression = params['expression']! as String;
    if (expression == 'refreshProjectBuildReadiness()') {
      buildRefreshes++;
      return {'type': '@Instance', 'kind': 'Null'};
    }
    if (expression == 'readProjectBuildReadiness()') {
      buildReads++;
      lastReceipt = buildReadiness;
      return string(lastReceipt);
    }
    if (expression == 'readProjectHarnessReadiness()') {
      lastReceipt = host.readReadiness();
      return string(lastReceipt);
    }
    if (expression.startsWith('readProjectHarnessModelReceipt(')) {
      receiptReads++;
      final id = expression.split("'")[1];
      final value = {...host.readReceipt(id)};
      if (missingDigest) value.remove('requestDigest');
      lastReceipt = value;
      return string(value);
    }
    if (expression.startsWith('runProjectHarnessModel(')) {
      invokes++;
      await host.run(expression.split("'")[1]);
      return {'type': '@Instance', 'kind': 'PlainInstance'};
    }
    throw StateError('unexpected_fixed_expression');
  }
}

void main() {
  test('default readiness remains model-only and never dispatches', () async {
    final host = ProjectModelProbeHost(
      admission: () => ProjectProbeAdmission(
        ready: true,
        isCurrent: () => true,
        generate: (_) => throw StateError('model_must_not_run'),
      ),
    );
    final vm = Vm(host);
    final result = await ProjectHarnessVmProbe(vm.rpc).inspect();
    expect(result['status'], 'readiness_only');
    expect(vm.buildRefreshes, 0);
    expect(vm.buildReads, 0);
    expect(vm.invokes, 0);
    expect(host.readReadiness()['invocationsAdmitted'], 0);
  });
  test(
    'explicit project readiness is read-only with no model admission',
    () async {
      final host = ProjectModelProbeHost(
        admission: () => ProjectProbeAdmission(
          ready: true,
          isCurrent: () => true,
          generate: (_) => throw StateError('model_must_not_run'),
        ),
      );
      final vm = Vm(host);
      final probe = ProjectHarnessVmProbe(vm.rpc);
      final result = await probe.inspect(projectBuildReadiness: true);
      expect(result['status'], 'project_build_readiness_only');
      expect(result['executionInvoked'], isFalse);
      expect(vm.buildRefreshes, 1);
      expect(vm.buildReads, 1);
      expect(vm.invokes, 0);
      expect(vm.receiptReads, 0);
      expect(probe.executionMayHaveStarted, isFalse);
      expect(host.readReadiness()['invocationsAdmitted'], 0);
    },
  );
  test(
    'read-only mode rejects model body and unsupported old receipts',
    () async {
      final host = ProjectModelProbeHost(
        admission: () => ProjectProbeAdmission(
          ready: true,
          isCurrent: () => true,
          generate: (_) => throw StateError('model_must_not_run'),
        ),
      );
      final vm = Vm(host);
      final probe = ProjectHarnessVmProbe(vm.rpc);
      await expectLater(
        probe.inspect(projectBuildReadiness: true, requestBase64: input(1)),
        throwsArgumentError,
      );
      expect(vm.buildRefreshes, 0);
      vm.buildReadiness = {'status': 'not_started'};
      await expectLater(
        probe.inspect(projectBuildReadiness: true),
        throwsStateError,
      );
      expect(vm.invokes, 0);
      expect(probe.executionMayHaveStarted, isFalse);
    },
  );
  test(
    'changed body with old invocation ID cannot claim its old completed response',
    () async {
      var calls = 0;
      final host = ProjectModelProbeHost(
        admission: () => ProjectProbeAdmission(
          ready: true,
          isCurrent: () => true,
          generate: (_) async {
            calls++;
            return 'old-source';
          },
        ),
      );
      await host.run(input(1));
      final vm = Vm(host);
      final probe = ProjectHarnessVmProbe(vm.rpc, pause: () async {});
      final result = await probe.inspect(
        requestBase64: input(1, content: 'different'),
      );
      expect(result['status'], 'invocation_conflict');
      expect(result.containsKey('response'), isFalse);
      expect(vm.invokes, 0);
      expect(calls, 1);
      expect(probe.existingInvocationObserved, isTrue);
    },
  );
  test(
    'canonical key ordering replays exact body and exhausted host stays readable without dispatch',
    () async {
      var calls = 0;
      final host = ProjectModelProbeHost(
        admission: () => ProjectProbeAdmission(
          ready: true,
          isCurrent: () => true,
          generate: (_) async {
            calls++;
            return 'source';
          },
        ),
      );
      for (var i = 0; i < 12; i++) {
        await host.run(input(i));
      }
      final vm = Vm(host);
      final result = await ProjectHarnessVmProbe(
        vm.rpc,
        pause: () async {},
      ).inspect(requestBase64: input(11, reverse: true));
      expect(result['status'], 'completed');
      expect(result['generationVerified'], isFalse);
      expect(vm.invokes, 0);
      expect(calls, 12);
      expect(host.readReadiness()['ready'], isFalse);
    },
  );
  test('busy admitted invocation is polled without another run', () async {
    final response = Completer<String>();
    var calls = 0;
    final host = ProjectModelProbeHost(
      admission: () => ProjectProbeAdmission(
        ready: true,
        isCurrent: () => true,
        generate: (_) {
          calls++;
          return response.future;
        },
      ),
    );
    final pending = host.run(input(1));
    final vm = Vm(host);
    final result = await ProjectHarnessVmProbe(
      vm.rpc,
      pause: () async {
        if (!response.isCompleted) response.complete('source');
        await Future<void>.delayed(Duration.zero);
      },
    ).inspect(requestBase64: input(1));
    expect(result['status'], 'completed');
    expect(calls, 1);
    expect(vm.invokes, 0);
    await pending;
  });
  test(
    'VM full object read is bounded, repeated truncation and length mismatch fail closed',
    () async {
      final host = ProjectModelProbeHost(
        admission: () => ProjectProbeAdmission(
          ready: true,
          isCurrent: () => true,
          generate: (_) async => 'x' * 20000,
        ),
      );
      await host.run(input(1));
      final vm = Vm(host)..truncate = true;
      final result = await ProjectHarnessVmProbe(
        vm.rpc,
        pause: () async {},
      ).inspect(requestBase64: input(1));
      expect((result['response']! as String).length, 20000);
      expect(
        vm.requestedCount,
        ProjectHarnessVmProbe.maximumReceiptCharacters + 1,
      );
      expect(vm.objectReads, 1);
      vm.truncateAgain = true;
      await expectLater(
        ProjectHarnessVmProbe(vm.rpc).inspect(requestBase64: input(1)),
        throwsStateError,
      );
      vm.truncate = false;
      vm.truncateAgain = false;
      vm.wrongLength = true;
      await expectLater(
        ProjectHarnessVmProbe(vm.rpc).inspect(requestBase64: input(1)),
        throwsStateError,
      );
      expect(vm.invokes, 0);
    },
  );
  test(
    'old host missing body digest is unknown rather than a false zero-call claim',
    () async {
      final host = ProjectModelProbeHost(
        admission: () => ProjectProbeAdmission(
          ready: true,
          isCurrent: () => true,
          generate: (_) async => 'source',
        ),
      );
      await host.run(input(1));
      final vm = Vm(host)..missingDigest = true;
      final probe = ProjectHarnessVmProbe(vm.rpc);
      await expectLater(
        probe.inspect(requestBase64: input(1)),
        throwsStateError,
      );
      expect(probe.executionMayHaveStarted, isTrue);
      expect(probe.invocationAttempted, isFalse);
    },
  );
  test(
    'oversized model output is a failed output with unknown cost and retained invocation',
    () async {
      var calls = 0;
      final host = ProjectModelProbeHost(
        admission: () => ProjectProbeAdmission(
          ready: true,
          isCurrent: () => true,
          generate: (_) async {
            calls++;
            return 'x' * (512 * 1024 + 1);
          },
        ),
      );
      final result = await host.run(input(1));
      expect(result['status'], 'output_too_large');
      expect(result.containsKey('response'), isFalse);
      expect(result['cost'], isNull);
      expect(result['usage'], isNull);
      expect(result['dispatchMayHaveStarted'], isTrue);
      expect((await host.run(input(1)))['status'], 'output_too_large');
      expect(calls, 1);
    },
  );
}

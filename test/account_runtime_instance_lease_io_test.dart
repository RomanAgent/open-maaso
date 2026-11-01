@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/account_runtime_instance_lease.dart';
import 'package:maaso/src/core/services/account_runtime_instance_lease_io.dart';

void main() {
  test('native lease is non-blocking across gate instances', () async {
    final support = await Directory.systemTemp.createTemp(
      'maaso-runtime-instance-',
    );
    addTearDown(() => support.delete(recursive: true));
    final firstGate = FileAccountRuntimeInstanceLeaseGate(
      supportDirectory: () async => support,
    );
    final secondGate = FileAccountRuntimeInstanceLeaseGate(
      supportDirectory: () async => support,
    );
    final first = await firstGate.acquire();
    addTearDown(first.release);

    await expectLater(
      secondGate.acquire(),
      throwsA(isA<AccountRuntimeInstanceUnavailable>()),
    );
    await first.release();

    final second = await secondGate.acquire();
    await second.release();
  });

  test('native lease rejects a symbolic-link lock leaf', () async {
    if (Platform.isWindows) return;
    final support = await Directory.systemTemp.createTemp(
      'maaso-runtime-instance-link-',
    );
    addTearDown(() => support.delete(recursive: true));
    final runtimeDirectory = Directory(
      '${support.path}${Platform.pathSeparator}maaso'
      '${Platform.pathSeparator}runtime',
    );
    await runtimeDirectory.create(recursive: true);
    final target = File(
      '${support.path}${Platform.pathSeparator}outside-runtime.lock',
    );
    await target.writeAsString('outside');
    final lockLink = Link(
      '${runtimeDirectory.path}${Platform.pathSeparator}'
      'account_runtime_instance.lock',
    );
    await lockLink.create(target.path);
    final gate = FileAccountRuntimeInstanceLeaseGate(
      supportDirectory: () async => support,
    );

    await expectLater(
      gate.acquire(),
      throwsA(isA<AccountRuntimeInstanceLockFailure>()),
    );
  });

  test('native lock is recovered after a competing process crashes', () async {
    final support = await Directory.systemTemp.createTemp(
      'maaso-runtime-instance-process-',
    );
    addTearDown(() => support.delete(recursive: true));
    final runtimeDirectory = Directory(
      '${support.path}${Platform.pathSeparator}maaso'
      '${Platform.pathSeparator}runtime',
    );
    await runtimeDirectory.create(recursive: true);
    final lockPath =
        '${runtimeDirectory.path}${Platform.pathSeparator}'
        'account_runtime_instance.lock';
    final holder = await Process.start(_findDartExecutable(), <String>[
      File(
        'test/helpers/account_runtime_instance_lock_holder.dart',
      ).absolute.path,
      lockPath,
    ], workingDirectory: Directory.current.path);
    addTearDown(() async {
      holder.kill();
      try {
        await holder.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {}
    });
    final firstOutput = await holder.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    expect(firstOutput, 'locked');

    final gate = FileAccountRuntimeInstanceLeaseGate(
      supportDirectory: () async => support,
    );
    await expectLater(
      gate.acquire(),
      throwsA(isA<AccountRuntimeInstanceUnavailable>()),
    );

    expect(holder.kill(), isTrue);
    await holder.exitCode.timeout(const Duration(seconds: 10));

    final recovered = await gate.acquire();
    await recovered.release();
  });
}

String _findDartExecutable() {
  final candidates = <String>[];
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null && flutterRoot.isNotEmpty) {
    candidates.add(
      '$flutterRoot${Platform.pathSeparator}bin${Platform.pathSeparator}cache'
      '${Platform.pathSeparator}dart-sdk${Platform.pathSeparator}bin'
      '${Platform.pathSeparator}dart',
    );
  }

  var directory = File(Platform.resolvedExecutable).parent;
  for (var depth = 0; depth < 8; depth++) {
    candidates
      ..add(
        '${directory.path}${Platform.pathSeparator}dart-sdk'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}dart',
      )
      ..add(
        '${directory.path}${Platform.pathSeparator}bin'
        '${Platform.pathSeparator}cache${Platform.pathSeparator}dart-sdk'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}dart',
      );
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }

  final path = Platform.environment['PATH'];
  if (path != null) {
    for (final entry in path.split(Platform.isWindows ? ';' : ':')) {
      candidates.add(
        '$entry${Platform.pathSeparator}${Platform.isWindows ? 'dart.exe' : 'dart'}',
      );
    }
  }

  return candidates.firstWhere(
    (candidate) => File(candidate).existsSync(),
    orElse: () => throw StateError('Unable to locate the Dart executable.'),
  );
}

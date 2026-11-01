import 'dart:io';

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    stderr.writeln('Expected the lock-file path.');
    exitCode = 64;
    return;
  }

  final handle = await File(arguments.single).open(mode: FileMode.append);
  await handle.lock(FileLock.exclusive);
  stdout.writeln('locked');
  await stdout.flush();

  // The parent test terminates this process without an explicit unlock. The
  // OS must release the lifetime file lock when the process exits.
  await stdin.first;
}

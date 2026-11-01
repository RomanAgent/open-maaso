import 'dart:async';

typedef AccountRuntimeDrainError = ({
  String stage,
  Object error,
  StackTrace stackTrace,
});

/// Runs independent account teardown stages without letting one failure keep
/// another privacy- or runtime-sensitive producer alive.
class AccountRuntimeDrainBarrier {
  final List<AccountRuntimeDrainError> _errors = <AccountRuntimeDrainError>[];

  List<AccountRuntimeDrainError> get errors =>
      List<AccountRuntimeDrainError>.unmodifiable(_errors);

  Future<void> run(String stage, FutureOr<void> Function() operation) async {
    try {
      await Future<void>.sync(operation);
    } catch (error, stackTrace) {
      _errors.add((stage: stage, error: error, stackTrace: stackTrace));
    }
  }

  Never throwFirst() {
    final first = _errors.first;
    Error.throwWithStackTrace(first.error, first.stackTrace);
  }
}

/// Standardized Execution Result Model
/// Whether it's plain text generation from an LLM or code execution
/// within the QuickJS sandbox, the final output is encapsulated
/// in this object and returned to the caller.
class ExecutionResult {
  /// Indicates whether the execution was successful
  final bool isSuccess;

  /// Standard output (corresponds to console.log in JS or the final returned data)
  final String stdout;

  /// Standard error (corresponds to exception stacks or syntax error messages in JS)
  final String stderr;

  /// Optional application-owned public category, separate from diagnostic
  /// prose. Consumers must allowlist it before using it in product UI.
  final String? failureCode;

  /// Execution duration (in milliseconds), useful for performance monitoring
  final int? executionTimeMs;

  ExecutionResult({
    required this.isSuccess,
    this.stdout = '',
    this.stderr = '',
    this.failureCode,
    this.executionTimeMs,
  });

  /// Factory method to quickly construct a successful result
  factory ExecutionResult.success(String output, {int? timeMs}) {
    return ExecutionResult(
      isSuccess: true,
      stdout: output,
      executionTimeMs: timeMs,
    );
  }

  /// Factory method to quickly construct a failure/error result
  factory ExecutionResult.error(
    String errorMsg, {
    int? timeMs,
    String? failureCode,
  }) {
    return ExecutionResult(
      isSuccess: false,
      stderr: errorMsg,
      failureCode: failureCode,
      executionTimeMs: timeMs,
    );
  }

  /// Converts to JSON format for convenient logging or network transmission
  Map<String, dynamic> toJson() {
    return {
      'isSuccess': isSuccess,
      'stdout': stdout,
      'stderr': stderr,
      if (executionTimeMs != null) 'executionTimeMs': executionTimeMs,
    };
  }

  @override
  String toString() {
    if (isSuccess) {
      return 'ExecutionResult[SUCCESS]:\n$stdout';
    } else {
      return 'ExecutionResult[ERROR]:\n$stderr';
    }
  }
}

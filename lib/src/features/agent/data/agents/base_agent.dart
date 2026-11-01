import 'dart:async';
import '../models/message.dart';
import '../models/execution_result.dart';
import '../llm/llm_client.dart';
import '../utils/logger.dart';

/// Enum representing the Agent's operational status
enum AgentStatus {
  idle, // Idle state
  thinking, // Thinking (Requesting LLM)
  executing, // Executing (Running code or calling tools)
  waitingForHuman, // Awaiting human intervention/approval (e.g., before sending bulk emails)
  error, // Operational error
  completed, // Task successfully finished
}

/// Abstract Base Agent Class
/// All operational Agents (whether for data analysis or content generation) should inherit from this class.
abstract class BaseAgent {
  /// Each Agent must have a name to identify itself (e.g., "Data Analyst Agent")
  final String name;

  /// The domain/role this Agent belongs to (e.g., "data_ops")
  final String roleDescription;

  /// The "Brain" driving this Agent's reasoning (LLM Client)
  final LLMClient llmClient;

  /// Current state of the Agent (for the UI layer to listen and display to users)
  AgentStatus _status = AgentStatus.idle;

  /// The Agent's long-term memory/conversation history (used to maintain multi-turn dialogue context)
  final List<Message> _memory = [];

  /// Status change stream (for external listeners like Flutter Bloc/Provider to implement real-time UI updates)
  final StreamController<AgentStatus> _statusController =
      StreamController<AgentStatus>.broadcast();

  BaseAgent({
    required this.name,
    required this.roleDescription,
    required this.llmClient,
  });

  // ==========================================
  // Core Abstract Methods: Must be implemented by subclasses
  // ==========================================

  /// Core processing logic: Defines exactly how the Agent works after receiving a task.
  Future<ExecutionResult> processTask(String instruction);

  /// Subclasses must implement this to build the Agent's unique System Prompt (persona and capability definition).
  String buildSystemPrompt();

  // ==========================================
  // Public Functionality: Reused by subclasses
  // ==========================================

  /// Gets the current status
  AgentStatus get status => _status;

  /// Listens to status changes (for UI layer use)
  Stream<AgentStatus> get statusStream => _statusController.stream;

  /// Updates status during execution (used by subclasses)
  void updateStatus(AgentStatus newStatus) {
    if (_status != newStatus) {
      _status = newStatus;
      _statusController.add(_status);
      Log.i('🤖 [$name] Status changed to: ${newStatus.name}');
    }
  }

  /// Adds dialogue context to the Agent's memory pool
  void addMemory(Message message) {
    _memory.add(message);
    // TODO(Optimization): Implement a sliding window mechanism here to prevent memory from exceeding Token limits.
    // e.g., If _memory exceeds 20 items, force-trim the earliest dialogues.
  }

  /// Retrieves the full conversation history (with System Prompt injected)
  List<Message> getFullContext() {
    return [Message(role: 'system', content: buildSystemPrompt()), ..._memory];
  }

  /// Clears the Agent's short-term memory
  void clearMemory() {
    _memory.clear();
    updateStatus(AgentStatus.idle);
    Log.i('🧹 [$name] Memory cleared, reset to idle state.');
  }

  /// Disposes of the Agent (releases Stream resources)
  void dispose() {
    _statusController.close();
  }

  // ==========================================
  // Generic LLM Interaction Wrapper: With retry mechanism and state transition
  // ==========================================

  /// Initiates a dialogue request (automatically handles 'thinking' state and error capturing)
  Future<String?> thinkAndRespond(
    List<Message> context, {
    int retries = 2,
  }) async {
    updateStatus(AgentStatus.thinking);
    int attempts = 0;

    while (attempts < retries) {
      attempts++;
      try {
        final response = await llmClient.chat(context);
        updateStatus(AgentStatus.idle);
        return response;
      } catch (e) {
        Log.e('⚠️ [$name] LLM request failed (Attempt $attempts/$retries): $e');
        if (attempts >= retries) {
          updateStatus(AgentStatus.error);
          return null; // Terminal failure
        }
        // Basic exponential backoff (simple 2-second delay)
        await Future.delayed(const Duration(seconds: 2));
      }
    }
    return null;
  }
}

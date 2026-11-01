import 'package:maaso/src/features/creator/domain/creator_image_task.dart';

const taskId = '11111111-1111-4111-8111-111111111111';
const attemptId = '22222222-2222-4222-8222-222222222222';
const nextAttemptId = '33333333-3333-4333-8333-333333333333';
const createRequestId = '44444444-4444-4444-8444-444444444444';
const testCreatorScope = 'test|owner';
const testAppletScope = 'https://example.invalid|owner';
const taskImageInput = CreatorTaskImageInput(
  prompt: 'blue ocean',
  aspectRatio: '1:1',
  style: 'natural',
);

CreatorTaskReceipt taskReceipt({
  String request = createRequestId,
  int attempt = 1,
  int sequence = 1,
}) => CreatorTaskReceipt(
  requestId: request,
  taskId: taskId,
  attemptId: attempt == 1 ? attemptId : nextAttemptId,
  attempt: attempt,
  sequence: sequence,
);
CreatorTaskSnapshot taskSnapshot(
  int sequence,
  CreatorTaskStatus status, {
  int attempt = 1,
}) => CreatorTaskSnapshot(
  taskId: taskId,
  agentId: 'self',
  attemptId: attempt == 1 ? attemptId : nextAttemptId,
  attempt: attempt,
  status: status,
  sequence: sequence,
  createdAt: DateTime.utc(2026, 9, 23),
  updatedAt: DateTime.utc(2026, 9, 23).add(Duration(seconds: sequence)),
  artifact: status == CreatorTaskStatus.completed
      ? CreatorTaskArtifact(
          assetId: 'img_test',
          sha256: List.filled(64, 'a').join(),
          contentType: 'image/png',
          bytes: 100,
          width: 2,
          height: 2,
        )
      : null,
);
CreatorImageTaskBinding taskBinding() => CreatorImageTaskBinding(
  creatorScopeKey: testCreatorScope,
  draftId: 'draft-1',
  draftFingerprint: List.filled(64, 'b').join(),
  createRequestId: createRequestId,
  input: taskImageInput,
  pendingCommand: const CreatorTaskCommand(
    operation: CreatorTaskOperation.create,
    requestId: createRequestId,
  ),
);

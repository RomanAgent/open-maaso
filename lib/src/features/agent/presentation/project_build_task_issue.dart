/// Public task hints are selected from fixed keys. Never render an exception,
/// provider response, request ID, URL or unknown server code as UI prose.
String? projectBuildV2TaskIssueMessageKey({
  required String syncIssue,
  String snapshotErrorCode = '',
}) {
  final code = syncIssue.startsWith('rejected:')
      ? syncIssue.substring('rejected:'.length)
      : syncIssue;
  switch (code) {
    case 'reference_input_missing':
    case 'project_reference_local_media_missing':
      return 'project_build.task.reference_input_missing';
    case 'reference_upload_unavailable':
    case 'project_reference_media_unavailable':
      return 'project_build.task.reference_upload_unavailable';
    case 'vision_unsupported':
      return 'project_build.task.vision_unsupported';
    case 'needs_authorization':
      return 'project_build.task.authorization_required';
  }
  if (snapshotErrorCode == 'vision_unsupported') {
    return 'project_build.task.vision_unsupported';
  }
  if (syncIssue.isEmpty) return null;
  return syncIssue.startsWith('rejected:')
      ? 'project_build.task.request_rejected'
      : 'project_build.task.sync_pending';
}

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:maaso/src/core/services/server_request_failure_log.dart';

void main() {
  test('formats structured server failures without URI query values', () {
    final message = ServerRequestFailureLog.describeResponse(
      source: 'AgentWorld',
      method: 'POST',
      uri: Uri.parse(
        'https://api-test.futurpals.com.cn/v1/world/match?access_token=secret',
      ),
      statusCode: 502,
      responseBody:
          '{"code":"UPSTREAM_UNAVAILABLE","message":"World is restarting","traceId":"trace-123"}',
    );

    expect(message, contains('[AgentWorld] POST /v1/world/match failed'));
    expect(message, contains('HTTP 502'));
    expect(message, contains('code=UPSTREAM_UNAVAILABLE'));
    expect(message, contains('message=World is restarting'));
    expect(message, contains('traceId=trace-123'));
    expect(message, isNot(contains('access_token')));
    expect(message, isNot(contains('secret')));
  });

  test('includes a concise plain-text server failure body', () {
    final message = ServerRequestFailureLog.describeResponse(
      source: 'SkillMarketplace',
      method: 'GET',
      uri: Uri.parse('https://api-test.futurpals.com.cn/v1/skills/catalog'),
      statusCode: 404,
      responseBody: '404 page not found',
    );

    expect(message, contains('HTTP 404'));
    expect(message, contains('body=404 page not found'));
  });

  test(
    'redacts live credentials, prompt text, account ids, and local paths',
    () {
      const accountUuid = '123e4567-e89b-12d3-a456-426614174000';
      const bearer = 'eyJhbGciOiJIUzI1NiJ9.secret.signature';
      const rtcToken = 'rtc-token-secret';
      const prompt = '展示我的私有推理提示词';
      const modelPath = '/Users/owner/private/avatar.bundle';
      final message = ServerRequestFailureLog.describeResponse(
        source: 'AgentLive',
        method: 'POST',
        uri: Uri.parse(
          'https://api-test.futurpals.com.cn/v1/accounts/'
          '$accountUuid/live?OSSAccessKeyId=key&Signature=signed-secret',
        ),
        statusCode: 500,
        responseBody:
            '{"code":"LIVE_FAILED","message":"Authorization: Bearer $bearer; '
            'rtcToken=$rtcToken; account_uuid=$accountUuid; prompt=$prompt; '
            'modelPath=$modelPath","traceId":"trace-live"}',
      );

      expect(message, contains('[REDACTED]'));
      for (final secret in [
        accountUuid,
        bearer,
        rtcToken,
        prompt,
        modelPath,
        'signed-secret',
      ]) {
        expect(message, isNot(contains(secret)));
      }
      expect(message, contains('HTTP 500'));
      expect(message, contains('code=LIVE_FAILED'));
      expect(message, contains('traceId=trace-live'));
    },
  );

  test('redacts secrets from transport errors without logging URI queries', () {
    const token = 'transport-bearer-secret';
    const localPath = '/var/mobile/private/avatar.bundle';
    final message = ServerRequestFailureLog.describeTransport(
      source: 'AgentLiveSSE',
      method: 'GET',
      uri: Uri.parse(
        'https://api-test.futurpals.com.cn/v1/live/rooms/room-1/events'
        '?token=query-secret&Signature=oss-secret',
      ),
      error: StateError('Authorization=Bearer $token modelPath=$localPath'),
    );

    expect(message, contains('[AgentLiveSSE] GET'));
    expect(message, contains('[REDACTED]'));
    expect(message, isNot(contains(token)));
    expect(message, isNot(contains(localPath)));
    expect(message, isNot(contains('query-secret')));
    expect(message, isNot(contains('oss-secret')));
  });

  test('redacts resource locations and complete prompt values in errors', () {
    const resourceUrl =
        'https://assets.example/private/account-a/avatar-model.glb';
    const rootPath = '/root/private/account-a/avatar-model.glb';
    const applicationPath = '/Applications/Maaso Private/avatar-model.bundle';
    const promptRemainder = 'private remainder after comma';
    const promptPipeTail = 'private remainder after pipe';
    const promptBraceTail = 'private remainder after brace';
    final message = ServerRequestFailureLog.describeTransport(
      source: 'AvatarCatalog',
      method: 'GET',
      uri: Uri.parse('https://api-test.futurpals.com.cn/v1/avatar-models'),
      error: StateError(
        'download $resourceUrl failed at $rootPath; '
        'localPath="$applicationPath"; '
        'prompt=private first; $promptRemainder | $promptPipeTail } '
        '$promptBraceTail',
      ),
    );

    expect(message, contains('[REDACTED]'));
    expect(message, contains('GET /v1/avatar-models'));
    for (final secret in <String>[
      resourceUrl,
      rootPath,
      applicationPath,
      'private first',
      promptRemainder,
      promptPipeTail,
      promptBraceTail,
    ]) {
      expect(message, isNot(contains(secret)));
    }
  });

  test('redacts assigned paths and complete query-bearing resource URIs', () {
    const assignedRootPath = '/root/private/account-a/avatar-model.glb';
    const prefixedServicePath = '/srv/private/account-a/avatar-model.glb';
    const resourcePath = 'private/account-a/avatar-model.glb';
    const signature = 'signature-secret';
    const commaTail = 'private-comma-tail';
    const semicolonTail = 'private-semicolon-tail';
    const pipeTail = 'private-pipe-tail';
    final message = ServerRequestFailureLog.describeTransport(
      source: 'AvatarCatalog',
      method: 'GET',
      uri: Uri.parse('https://api-test.futurpals.com.cn/v1/avatar-models'),
      error: StateError(
        'cache=$assignedRootPath path:$prefixedServicePath '
        'download=https://assets.example/$resourcePath?'
        'X-Amz-Signature=$signature,$commaTail;$semicolonTail|$pipeTail',
      ),
    );

    expect(message, contains('[REDACTED]'));
    expect(message, contains('cache=[REDACTED]'));
    expect(message, contains('path:[REDACTED]'));
    for (final secret in <String>[
      assignedRootPath,
      prefixedServicePath,
      resourcePath,
      signature,
      commaTail,
      semicolonTail,
      pipeTail,
    ]) {
      expect(message, isNot(contains(secret)));
    }
  });

  test('redacts resource locations and prompt tails in response messages', () {
    const resourceUrl = 'file:///srv/private/account-a/avatar-model.glb';
    const localPath = '/mnt/private/account-a/avatar-model.glb';
    const promptRemainder = 'second private clause';
    const instructionPipeTail = 'private instruction after pipe';
    const instructionBraceTail = 'private instruction after brace';
    final message = ServerRequestFailureLog.describeResponse(
      source: 'AvatarCatalog',
      method: 'POST',
      uri: Uri.parse('https://api-test.futurpals.com.cn/v1/avatar-models'),
      statusCode: 500,
      responseBody: jsonEncode(<String, Object>{
        'code': 'UPLOAD_FAILED',
        'message':
            'resource=$resourceUrl; modelPath=$localPath; '
            'instruction_text=first private clause; $promptRemainder | '
            '$instructionPipeTail } $instructionBraceTail',
        'traceId': 'trace-safe',
      }),
    );

    expect(message, contains('POST /v1/avatar-models'));
    expect(message, contains('code=UPLOAD_FAILED'));
    expect(message, contains('traceId=trace-safe'));
    for (final secret in <String>[
      resourceUrl,
      localPath,
      'first private clause',
      promptRemainder,
      instructionPipeTail,
      instructionBraceTail,
    ]) {
      expect(message, isNot(contains(secret)));
    }
  });

  test('redacts the complete target of presigned and queryless PUTs', () {
    const objectKey = 'private/account-a/avatar-model.glb';
    final presigned = ServerRequestFailureLog.describeResponse(
      source: 'AvatarCatalog',
      method: 'PUT',
      uri: Uri.parse(
        'https://bucket.example/$objectKey?X-Amz-Credential=credential-secret'
        '&X-Amz-Signature=signature-secret',
      ),
      statusCode: 503,
      responseBody: 'upload unavailable',
    );
    final queryless = ServerRequestFailureLog.describeTransport(
      source: 'AvatarCatalog',
      method: 'PUT',
      uri: Uri.parse('https://bucket.example/$objectKey'),
      error: StateError('connection closed'),
    );

    for (final message in <String>[presigned, queryless]) {
      expect(message, contains('PUT [REDACTED]'));
      expect(message, isNot(contains(objectKey)));
      expect(message, isNot(contains('account-a')));
      expect(message, isNot(contains('avatar-model.glb')));
    }
  });

  test('never passes an unsanitized exception object to the shared logger', () {
    final source = File(
      'lib/src/core/services/server_request_failure_log.dart',
    ).readAsStringSync();

    expect('error: _redactedError(error)'.allMatches(source), hasLength(2));
    expect(
      'stackTrace: redactedStackTrace(stackTrace)'.allMatches(source),
      hasLength(2),
    );
    expect(
      RegExp(r'^\s+error:\s*error,\s*$', multiLine: true).hasMatch(source),
      isFalse,
    );
    expect(
      RegExp(
        r'^\s+stackTrace:\s*stackTrace,\s*$',
        multiLine: true,
      ).hasMatch(source),
      isFalse,
    );
  });

  test('redacts and bounds stack traces before logging', () {
    const accountUuid = '123e4567-e89b-12d3-a456-426614174000';
    const operationKey = 'operation-secret';
    const compensationKey = 'compensation-secret';
    const localPath = '/Users/owner/private/avatar_selection.dart:42:7';
    const linuxPath = '/home/runner/maaso/avatar_selection.dart:18:3';
    const rootPath = '/root/private/avatar_selection.dart:19:3';
    const mountPath = '/mnt/work/private/avatar_selection.dart:20:3';
    const servicePath = '/srv/maaso/private/avatar_selection.dart:21:3';
    const applicationPath =
        '/Applications/Maaso.app/private/avatar_selection.dart:22:3';
    const temporaryPath = '/tmp/maaso/private-selection.json';
    const windowsPath = r'C:\Users\owner\maaso\avatar_selection.dart:9:2';
    const resourceUrl = 'https://assets.example/private/avatar.glb';
    const fileUri = 'file:///root/private/avatar_selection.dart';
    const spacedPath =
        '/Users/John Doe/private,folder/avatar_selection.dart:42:7';
    final isolatedCases = <(String, String)>[
      ('account_uuid=$accountUuid', accountUuid),
      ('operationKey=$operationKey', operationKey),
      ('compensation_key=$compensationKey', compensationKey),
      (localPath, localPath),
      (linuxPath, linuxPath),
      (rootPath, rootPath),
      (mountPath, mountPath),
      (servicePath, servicePath),
      (applicationPath, applicationPath),
      (temporaryPath, temporaryPath),
      (windowsPath, windowsPath),
      (resourceUrl, resourceUrl),
      (fileUri, fileUri),
      (spacedPath, spacedPath),
      ('Signature=secret', 'secret'),
    ];
    final raw = StackTrace.fromString(
      '#0 commit ($localPath)\n'
      '#1 request (operationKey=$operationKey; '
      'compensation_key=$compensationKey; account_uuid=$accountUuid)\n'
      '#2 signed (https://assets.example/avatar.glb?Signature=secret)\n'
      '#3 linux ($linuxPath)\n'
      '#4 root ($rootPath)\n'
      '#5 mount ($mountPath)\n'
      '#6 service ($servicePath)\n'
      '#7 application ($applicationPath)\n'
      '#8 temp ($temporaryPath)\n'
      '#9 windows ($windowsPath)\n'
      '#10 resource ($resourceUrl)\n'
      '#11 file ($fileUri)',
    );

    final safe = ServerRequestFailureLog.redactedStackTrace(raw).toString();

    expect(safe, contains('[REDACTED]'));
    expect(safe.length, lessThanOrEqualTo(320));
    for (final (context, secret) in isolatedCases) {
      expect(safe, isNot(contains(secret)));
      final isolated = ServerRequestFailureLog.redactedStackTrace(
        StackTrace.fromString('#0 frame ($context)'),
      ).toString();
      expect(isolated, contains('[REDACTED]'));
      expect(isolated, isNot(contains(secret)));
      expect(isolated, isNot(contains('Doe/private')));
      expect(isolated, isNot(contains('private,folder')));
    }
  });
}

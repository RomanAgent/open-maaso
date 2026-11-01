import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as image;
import 'package:maaso/src/core/foundation/app_framework.dart';
import 'package:maaso/src/core/security/trusted_media_asset_policy.dart';
import 'package:maaso/src/core/services/app_environment_service.dart';
import 'package:maaso/src/core/services/auth_session_service.dart';
import 'package:maaso/src/features/creator/data/creator_draft_repository.dart';
import 'package:maaso/src/features/creator/domain/creator_draft.dart';
import 'package:maaso/src/features/creator/domain/creator_image_task.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class CreatorImageRequestException extends StateError {
  CreatorImageRequestException(this.statusCode, this.code, String message)
    : super(message);

  final int statusCode;
  final String code;
}

abstract interface class ImageGenerationGateway {
  bool get isAvailable;

  String get requestContextKey;

  Future<CreatorAssetRef> generate({
    required String prompt,
    required String aspectRatio,
    required String style,
    required String idempotencyKey,
    required String expectedContextKey,
  });

  Future<void> deleteLocalAsset(CreatorAssetRef asset);
}

abstract interface class CreatorTaskAssetDownloader {
  void cancelPendingTaskDownloads();
  Future<CreatorAssetRef> downloadTaskAsset({
    required CreatorTaskArtifact artifact,
    required Uri assetUrl,
    required String expectedContextKey,
    required bool Function() canContinue,
  });
  Future<bool> validateTaskAsset(
    CreatorAssetRef asset,
    CreatorTaskArtifact artifact, {
    required String expectedContextKey,
    required bool Function() canContinue,
  });
}

class HttpImageGenerationGateway extends AppService
    implements ImageGenerationGateway, CreatorTaskAssetDownloader {
  HttpImageGenerationGateway({
    http.Client? httpClient,
    AppEnvironmentService? environment,
    AuthSessionService? auth,
    TrustedMediaAssetPolicy? assetPolicy,
    Future<Directory> Function()? supportDirectory,
    bool? available,
    Duration requestTimeout = const Duration(seconds: 20),
    Duration downloadTimeout = const Duration(seconds: 30),
  }) : _http = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _environment = environment ?? appServices.find<AppEnvironmentService>(),
       _auth = auth ?? appServices.find<AuthSessionService>(),
       _assetPolicyOverride = assetPolicy,
       _supportDirectory = supportDirectory ?? getApplicationSupportDirectory,
       _available = available ?? _enabledAtBuildTime,
       _requestTimeout = requestTimeout,
       _downloadTimeout = downloadTimeout;

  static const int maximumEnvelopeBytes = 512 * 1024;
  static const int maximumAssetBytes = 12 * 1024 * 1024;
  static const int maximumDimension = 4096;
  static const int maximumPixels = 12_000_000;
  static const bool _enabledAtBuildTime = bool.fromEnvironment(
    'MAASO_CREATOR_IMAGE_GENERATION_ENABLED',
    defaultValue: false,
  );

  final http.Client _http;
  final bool _ownsClient;
  final AppEnvironmentService _environment;
  final AuthSessionService _auth;
  final TrustedMediaAssetPolicy? _assetPolicyOverride;
  final Future<Directory> Function() _supportDirectory;
  final bool _available;
  final Duration _requestTimeout;
  final Duration _downloadTimeout;
  bool _taskDownloadsSealed = false;

  TrustedMediaAssetPolicy get _assetPolicy =>
      _assetPolicyOverride ??
      TrustedMediaAssetPolicy.forEnvironment(_environment.environment.value);

  @override
  bool get isAvailable => _available;

  @override
  String get requestContextKey {
    final account = _auth.session.value?.accountUuid.trim() ?? '';
    return '${_environment.environment.value.key}|$account';
  }

  @override
  Future<CreatorAssetRef> generate({
    required String prompt,
    required String aspectRatio,
    required String style,
    required String idempotencyKey,
    required String expectedContextKey,
  }) async {
    if (!isAvailable) {
      throw CreatorImageRequestException(
        0,
        'backend_not_ready',
        'Creator image generation is not available',
      );
    }
    final session = _auth.session.value;
    if (session == null || session.accountUuid.trim().isEmpty) {
      throw CreatorImageRequestException(401, 'unauthorized', 'Sign in first');
    }
    _guard(expectedContextKey);
    final normalizedPrompt = prompt.trim();
    if (normalizedPrompt.isEmpty || normalizedPrompt.length > 1200) {
      throw CreatorImageRequestException(0, 'invalid_prompt', 'Invalid prompt');
    }
    if (!const <String>{'1:1', '4:5', '9:16', '16:9'}.contains(aspectRatio) ||
        !RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(style) ||
        !RegExp(r'^[A-Za-z0-9_-]{8,96}$').hasMatch(idempotencyKey)) {
      throw CreatorImageRequestException(
        0,
        'invalid_request',
        'Invalid request',
      );
    }
    final generationRequest =
        http.Request(
            'POST',
            _environment.baseUri.resolve('v1/creator/images/generations'),
          )
          ..followRedirects = false
          ..maxRedirects = 0
          ..headers.addAll(<String, String>{
            'authorization': 'Bearer ${session.accessToken}',
            'content-type': 'application/json',
            'accept': 'application/json',
          })
          ..body = jsonEncode(<String, Object>{
            'prompt': normalizedPrompt,
            'aspectRatio': aspectRatio,
            'style': style,
            'idempotencyKey': idempotencyKey,
          });
    final generationStream = await _send(
      generationRequest,
      timeout: _requestTimeout,
      timeoutCode: 'generation_timeout',
    );
    final generationBytes = await _readBounded(
      generationStream.stream,
      maximumEnvelopeBytes,
      _requestTimeout,
      tooLargeCode: 'invalid_envelope',
      timeoutCode: 'generation_timeout',
    );
    final response = http.Response.bytes(
      generationBytes,
      generationStream.statusCode,
      headers: generationStream.headers,
      request: generationRequest,
    );
    _guard(expectedContextKey);
    final data = _decodeEnvelope(response);
    return _downloadAsset(data, expectedContextKey: expectedContextKey);
  }

  @override
  Future<CreatorAssetRef> downloadTaskAsset({
    required CreatorTaskArtifact artifact,
    required Uri assetUrl,
    required String expectedContextKey,
    required bool Function() canContinue,
  }) {
    if (_taskDownloadsSealed) throw const CreatorScopeChangedException();
    CreatorTaskArtifact.fromJson(artifact.toJson());
    return _downloadAsset(
      {
        'assetId': artifact.assetId,
        'assetUrl': assetUrl.toString(),
        'contentType': artifact.contentType,
        'bytes': artifact.bytes,
        'sha256': artifact.sha256,
        'width': artifact.width,
        'height': artifact.height,
      },
      expectedContextKey: expectedContextKey,
      canContinue: () => !_taskDownloadsSealed && canContinue(),
      scoped: true,
    );
  }

  Future<CreatorAssetRef> _downloadAsset(
    Map<String, dynamic> data, {
    required String expectedContextKey,
    bool Function()? canContinue,
    bool scoped = false,
  }) async {
    void guard() {
      _guard(expectedContextKey);
      if (canContinue?.call() == false) {
        throw const CreatorScopeChangedException();
      }
    }

    guard();
    final assetId = _boundedId(data['assetId']);
    final assetUrl = Uri.tryParse(data['assetUrl'] as String);
    final contentType = data['contentType'] as String;
    final expectedBytes = _positiveInt(data['bytes']);
    final expectedSha = data['sha256'] as String;
    final expectedWidth = _positiveInt(data['width']);
    final expectedHeight = _positiveInt(data['height']);
    if (assetUrl == null ||
        !_assetPolicy.allows(assetUrl) ||
        !const <String>{'image/png', 'image/jpeg'}.contains(contentType) ||
        expectedBytes <= 0 ||
        expectedBytes > maximumAssetBytes ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(expectedSha) ||
        !_validDimensions(expectedWidth, expectedHeight)) {
      throw CreatorImageRequestException(
        502,
        'invalid_asset',
        'Generated asset is invalid',
      );
    }
    final assetRequest = http.Request('GET', assetUrl)
      ..followRedirects = false
      ..maxRedirects = 0
      ..headers['accept'] = 'image/png,image/jpeg';
    final assetResponse = await _send(
      assetRequest,
      timeout: _requestTimeout,
      timeoutCode: 'asset_download_timeout',
    );
    guard();
    if (assetResponse.statusCode < 200 || assetResponse.statusCode >= 300) {
      throw CreatorImageRequestException(
        assetResponse.statusCode,
        'asset_download_failed',
        'Generated asset download failed',
      );
    }
    final responseLength = int.tryParse(
      assetResponse.headers['content-length'] ?? '',
    );
    if (responseLength != null && responseLength > maximumAssetBytes) {
      throw CreatorImageRequestException(
        502,
        'asset_too_large',
        'Generated asset exceeds its size limit',
      );
    }
    final responseContentType =
        assetResponse.headers['content-type']
            ?.split(';')
            .first
            .trim()
            .toLowerCase() ??
        '';
    if (responseContentType != contentType) {
      throw CreatorImageRequestException(
        502,
        'asset_content_type_mismatch',
        'Generated asset content type does not match',
      );
    }
    final bytes = await _readBounded(
      assetResponse.stream,
      maximumAssetBytes,
      _downloadTimeout,
      tooLargeCode: 'asset_too_large',
      timeoutCode: 'asset_download_timeout',
    );
    if (bytes.isEmpty ||
        bytes.length != expectedBytes ||
        bytes.length > maximumAssetBytes ||
        sha256.convert(bytes).toString() != expectedSha) {
      throw CreatorImageRequestException(
        502,
        'asset_integrity_failed',
        'Generated asset integrity check failed',
      );
    }
    final decoder = image.findDecoderForData(bytes);
    final decodeInfo = decoder?.startDecode(bytes);
    if (decoder == null ||
        decodeInfo == null ||
        decodeInfo.numFrames != 1 ||
        !_contentTypeMatches(contentType, decoder.format) ||
        decodeInfo.width != expectedWidth ||
        decodeInfo.height != expectedHeight ||
        !_validDimensions(decodeInfo.width, decodeInfo.height)) {
      throw CreatorImageRequestException(
        502,
        'asset_dimensions_mismatch',
        'Generated asset dimensions do not match',
      );
    }
    final decoded = decoder.decodeFrame(0);
    if (decoded == null ||
        decoded.width != expectedWidth ||
        decoded.height != expectedHeight) {
      throw CreatorImageRequestException(
        502,
        'asset_decode_failed',
        'Generated asset could not be decoded safely',
      );
    }
    final support = await _supportDirectory();
    guard();
    final directory = Directory(
      path.joinAll([
        support.path,
        'creator',
        'assets',
        if (scoped) sha256.convert(utf8.encode(expectedContextKey)).toString(),
      ]),
    );
    await directory.create(recursive: true);
    guard();
    final extension = switch (contentType) {
      'image/png' => '.png',
      'image/jpeg' => '.jpg',
      _ => throw StateError('unreachable'),
    };
    final output = File(path.join(directory.path, '$assetId$extension'));
    if (scoped) {
      final temporary = File('${output.path}.${const Uuid().v4()}.part');
      try {
        await temporary.writeAsBytes(bytes, flush: true);
        guard();
        await temporary.rename(output.path);
        // A retired callback must not delete a replacement mount's cache.
        // This account-namespaced immutable file is never made visible until
        // the current tracker accepts and persists the returned reference.
        guard();
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
      return CreatorAssetRef(
        id: assetId,
        localPath: output.path,
        contentType: contentType,
        sha256: expectedSha,
        bytes: bytes.length,
        width: decoded.width,
        height: decoded.height,
      );
    }
    await output.writeAsBytes(bytes, flush: true);
    try {
      guard();
    } catch (_) {
      if (await output.exists()) await output.delete();
      rethrow;
    }
    return CreatorAssetRef(
      id: assetId,
      localPath: output.path,
      contentType: contentType,
      sha256: expectedSha,
      bytes: bytes.length,
      width: decoded.width,
      height: decoded.height,
    );
  }

  @override
  Future<bool> validateTaskAsset(
    CreatorAssetRef asset,
    CreatorTaskArtifact artifact, {
    required String expectedContextKey,
    required bool Function() canContinue,
  }) async {
    if (_taskDownloadsSealed ||
        !canContinue() ||
        !artifact.matchesAsset(asset)) {
      return false;
    }
    _guard(expectedContextKey);
    final support = await _supportDirectory();
    final directory = Directory(
      path.join(
        support.path,
        'creator',
        'assets',
        sha256.convert(utf8.encode(expectedContextKey)).toString(),
      ),
    );
    final file = File(asset.localPath);
    if (!await directory.exists() || !await file.exists() || !canContinue()) {
      return false;
    }
    final root = await directory.resolveSymbolicLinks();
    final actual = await file.resolveSymbolicLinks();
    if (!path.isWithin(root, actual) || await file.length() != artifact.bytes) {
      return false;
    }
    final bytes = await file.readAsBytes();
    _guard(expectedContextKey);
    return !_taskDownloadsSealed &&
        canContinue() &&
        bytes.length == artifact.bytes &&
        sha256.convert(bytes).toString() == artifact.sha256;
  }

  @override
  void cancelPendingTaskDownloads() {
    _taskDownloadsSealed = true;
    if (_ownsClient) _http.close();
  }

  @override
  Future<void> deleteLocalAsset(CreatorAssetRef asset) async {
    final support = await _supportDirectory();
    final directory = Directory(path.join(support.path, 'creator', 'assets'));
    await directory.create(recursive: true);
    final file = File(asset.localPath);
    if (!await file.exists()) return;
    final rootPath = await directory.resolveSymbolicLinks();
    final resolvedFile = await file.resolveSymbolicLinks();
    if (!path.isWithin(rootPath, resolvedFile)) {
      throw CreatorImageRequestException(
        0,
        'invalid_asset_path',
        'Creator asset path is outside the managed directory',
      );
    }
    await file.delete();
  }

  Future<http.StreamedResponse> _send(
    http.BaseRequest request, {
    required Duration timeout,
    required String timeoutCode,
  }) async {
    try {
      return await _http.send(request).timeout(timeout);
    } on TimeoutException {
      throw CreatorImageRequestException(0, timeoutCode, 'Request timed out');
    } on http.ClientException {
      throw CreatorImageRequestException(
        0,
        'network_error',
        'Network request failed',
      );
    }
  }

  Future<Uint8List> _readBounded(
    Stream<List<int>> stream,
    int maximumBytes,
    Duration timeout, {
    required String tooLargeCode,
    required String timeoutCode,
  }) async {
    try {
      return await () async {
        final output = BytesBuilder(copy: false);
        var total = 0;
        await for (final chunk in stream) {
          total += chunk.length;
          if (total > maximumBytes) {
            throw CreatorImageRequestException(
              502,
              tooLargeCode,
              'Response exceeds its size limit',
            );
          }
          output.add(chunk);
        }
        return output.takeBytes();
      }().timeout(timeout);
    } on TimeoutException {
      throw CreatorImageRequestException(0, timeoutCode, 'Request timed out');
    }
  }

  Map<String, dynamic> _decodeEnvelope(http.Response response) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      decoded = null;
    }
    final envelope = decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw CreatorImageRequestException(
        response.statusCode,
        envelope?['code']?.toString() ?? '',
        envelope?['message']?.toString() ?? 'Image generation failed',
      );
    }
    const envelopeKeys = <String>{'code', 'message', 'traceId', 'data'};
    final exactEnvelope =
        envelope != null &&
        envelope.length == envelopeKeys.length &&
        envelopeKeys.every(envelope.containsKey);
    if (!exactEnvelope ||
        envelope['code'] != 'OK' ||
        envelope['message'] is! String ||
        (envelope['message'] as String).trim().isEmpty ||
        envelope['traceId'] is! String ||
        (envelope['traceId'] as String).trim().isEmpty ||
        envelope['data'] is! Map) {
      throw CreatorImageRequestException(
        response.statusCode,
        'invalid_envelope',
        'Image generation response is invalid',
      );
    }
    final data = Map<String, dynamic>.from(envelope['data'] as Map);
    const dataKeys = <String>{
      'assetId',
      'assetUrl',
      'contentType',
      'sha256',
      'bytes',
      'width',
      'height',
    };
    if (data.length != dataKeys.length ||
        !dataKeys.every(data.containsKey) ||
        data['assetId'] is! String ||
        data['assetUrl'] is! String ||
        data['contentType'] is! String ||
        data['sha256'] is! String ||
        data['bytes'] is! int ||
        data['width'] is! int ||
        data['height'] is! int) {
      throw CreatorImageRequestException(
        response.statusCode,
        'invalid_envelope',
        'Image generation response is invalid',
      );
    }
    return data;
  }

  bool _validDimensions(int width, int height) =>
      width > 0 &&
      height > 0 &&
      width <= maximumDimension &&
      height <= maximumDimension &&
      width * height <= maximumPixels;

  bool _contentTypeMatches(String contentType, image.ImageFormat format) =>
      switch (contentType) {
        'image/png' => format == image.ImageFormat.png,
        'image/jpeg' => format == image.ImageFormat.jpg,
        _ => false,
      };

  String _boundedId(Object? value) {
    final id = value is String ? value : '';
    if (!RegExp(r'^[A-Za-z0-9_-]{1,96}$').hasMatch(id)) {
      throw CreatorImageRequestException(
        502,
        'invalid_asset',
        'Invalid asset id',
      );
    }
    return id;
  }

  void _guard(String expectedContextKey) {
    if (requestContextKey != expectedContextKey) {
      throw const CreatorScopeChangedException();
    }
  }

  @override
  void onClose() {
    if (_ownsClient) _http.close();
    super.onClose();
  }
}

int _positiveInt(Object? value) => switch (value) {
  final int number when number > 0 => number,
  _ => 0,
};

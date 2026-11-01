import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import '../domain/persona_package_manifest.dart';

final class PersonaPackageImportLimits {
  const PersonaPackageImportLimits({
    this.maxArchiveBytes = 16 * 1024 * 1024,
    this.maxManifestBytes = 256 * 1024,
    this.maxEntryCount = 256,
    this.maxEntryBytes = 8 * 1024 * 1024,
    this.maxUncompressedBytes = 64 * 1024 * 1024,
    this.maxCompressionRatio = 100,
    this.maxJsonDepth = 12,
    this.maxJsonNodes = 8192,
    this.maxJsonStringLength = 1024,
    this.maxJsonStringCodeUnits = 64 * 1024,
  });

  final int maxArchiveBytes;
  final int maxManifestBytes;
  final int maxEntryCount;
  final int maxEntryBytes;
  final int maxUncompressedBytes;
  final int maxCompressionRatio;
  final int maxJsonDepth;
  final int maxJsonNodes;
  final int maxJsonStringLength;
  final int maxJsonStringCodeUnits;

  bool get isValid =>
      maxArchiveBytes > 0 &&
      maxManifestBytes > 0 &&
      maxEntryCount > 0 &&
      maxEntryBytes > 0 &&
      maxUncompressedBytes > 0 &&
      maxCompressionRatio > 0 &&
      maxJsonDepth > 0 &&
      maxJsonNodes > 0 &&
      maxJsonStringLength > 0 &&
      maxJsonStringCodeUnits > 0;
}

/// The only caller-provided package representation is the original ZIP.
/// Manifest and package resources are decoded from these exact bytes.
final class PersonaPackageImportRequest {
  PersonaPackageImportRequest({
    required List<int> archiveBytes,
    required this.scope,
    required this.importedAt,
  }) : archiveBytes = Uint8List.fromList(archiveBytes);

  final Uint8List archiveBytes;
  final PersonaPackageScope scope;
  final DateTime importedAt;
}

/// A typed request for immutable resources owned by the host. Package
/// resources never use this seam and must exist in the same ZIP.
final class PersonaHostResourceRequest {
  const PersonaHostResourceRequest._({
    required this.ref,
    required this.kind,
    required this.expectedSha256,
    required this.scope,
  });

  final String ref;
  final PersonaResourceKind kind;
  final String expectedSha256;
  final PersonaPackageScope scope;
}

abstract interface class PersonaHostResourceResolver {
  Uint8List? resolve(PersonaHostResourceRequest request);
}

enum _DecodedEntryKind { file, directory, symbolicLink, nonRegular }

final class _DecodedEntry {
  const _DecodedEntry({
    required this.path,
    required this.bytes,
    required this.compressedSize,
    required this.kind,
  });

  final String path;
  final Uint8List bytes;
  final int compressedSize;
  final _DecodedEntryKind kind;
}

final class _DecodedArchive {
  const _DecodedArchive({required this.manifestBytes, required this.entries});

  final Uint8List manifestBytes;
  final List<_DecodedEntry> entries;
}

final class _ArchiveDecodeResult {
  const _ArchiveDecodeResult.accepted(this.archive) : reason = null;
  const _ArchiveDecodeResult.rejected(this.reason) : archive = null;

  final _DecodedArchive? archive;
  final String? reason;
}

final class _ArchiveExpansionLimit implements Exception {
  const _ArchiveExpansionLimit();
}

/// Archive's decoder writes decompressed chunks into this sink. Capacity is
/// checked before each chunk is retained, so a forged central-directory size
/// cannot make the decoder allocate an attacker-selected output buffer first.
final class _BoundedArchiveOutput extends OutputStream {
  _BoundedArchiveOutput(this.limit) : super(byteOrder: ByteOrder.littleEndian);

  final int limit;
  final BytesBuilder _bytes = BytesBuilder(copy: false);

  @override
  int get length => _bytes.length;

  void _reserve(int count) {
    if (count < 0 || length + count > limit) {
      throw const _ArchiveExpansionLimit();
    }
  }

  @override
  void writeByte(int value) {
    _reserve(1);
    _bytes.addByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    final count = length ?? bytes.length;
    if (count < 0 || count > bytes.length) {
      throw const _ArchiveExpansionLimit();
    }
    _reserve(count);
    _bytes.add(count == bytes.length ? bytes : bytes.sublist(0, count));
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      final count = math.min(stream.length, 64 * 1024);
      if (count <= 0) break;
      writeBytes(stream.readBytes(count).toUint8List());
    }
  }

  Uint8List takeBytes() => _bytes.takeBytes();

  @override
  Uint8List subset(int start, [int? end]) {
    final bytes = _bytes.toBytes();
    return Uint8List.fromList(bytes.sublist(start, end));
  }

  @override
  void clear() => _bytes.clear();

  @override
  void flush() {}
}

final class PersonaVerifiedResourceReceipt {
  const PersonaVerifiedResourceReceipt._({
    required this.resourceId,
    required this.ref,
    required this.kind,
    required this.sha256,
    required this.byteLength,
    required this.manifestDigest,
    required this.verifiedAt,
  });

  final String resourceId;
  final String ref;
  final PersonaResourceKind kind;
  final String sha256;
  final int byteLength;
  final String manifestDigest;
  final DateTime verifiedAt;
}

/// Capability object created only after strict parse, semantic validation,
/// path containment checks, and verification of every declared resource.
final class PersonaVerifiedPackage {
  PersonaVerifiedPackage._({
    required this.manifest,
    required this.archiveDigest,
    required Map<String, PersonaVerifiedResourceReceipt> resourceReceipts,
    required this.verifiedAt,
  }) : resourceReceipts =
           Map<String, PersonaVerifiedResourceReceipt>.unmodifiable(
             resourceReceipts,
           );

  final PersonaPackageManifest manifest;
  final String archiveDigest;
  final Map<String, PersonaVerifiedResourceReceipt> resourceReceipts;
  final DateTime verifiedAt;

  String get manifestDigest => manifest.canonicalDigest;
}

enum PersonaPackageImportStatus { accepted, rejected }

final class PersonaPackageImportResult {
  const PersonaPackageImportResult._({
    required this.status,
    this.package,
    this.reason,
  });

  const PersonaPackageImportResult.accepted(PersonaVerifiedPackage package)
    : this._(status: PersonaPackageImportStatus.accepted, package: package);

  const PersonaPackageImportResult.rejected(String reason)
    : this._(status: PersonaPackageImportStatus.rejected, reason: reason);

  final PersonaPackageImportStatus status;
  final PersonaVerifiedPackage? package;
  final String? reason;
}

final class PersonaPackageImporter {
  const PersonaPackageImporter({
    required this.hostResourceResolver,
    this.limits = const PersonaPackageImportLimits(),
  });

  static const String manifestEntryPath = 'persona-manifest.json';

  final PersonaHostResourceResolver hostResourceResolver;
  final PersonaPackageImportLimits limits;

  PersonaPackageImportResult import(PersonaPackageImportRequest request) {
    if (!limits.isValid) {
      return const PersonaPackageImportResult.rejected('invalid_limits');
    }
    if (request.archiveBytes.length > limits.maxArchiveBytes) {
      return const PersonaPackageImportResult.rejected('archive_too_large');
    }
    final decodedResult = _decodeArchive(request.archiveBytes);
    final decoded = decodedResult.archive;
    if (decoded == null) {
      return PersonaPackageImportResult.rejected(decodedResult.reason!);
    }
    if (decoded.manifestBytes.length > limits.maxManifestBytes) {
      return const PersonaPackageImportResult.rejected('manifest_too_large');
    }
    if (decoded.entries.length + 1 > limits.maxEntryCount) {
      return const PersonaPackageImportResult.rejected('too_many_entries');
    }

    final Object? rawManifest;
    try {
      final manifestJson = utf8.decode(
        decoded.manifestBytes,
        allowMalformed: false,
      );
      rawManifest = jsonDecode(manifestJson);
      final budget = _JsonBudget(limits);
      if (!budget.accepts(rawManifest)) {
        return PersonaPackageImportResult.rejected(budget.reason!);
      }
    } on FormatException {
      return const PersonaPackageImportResult.rejected('invalid_json');
    }

    final parsed = PersonaPackageManifestParser.parsePortable(
      rawManifest,
      scope: request.scope,
    );
    final manifest = parsed.manifest;
    if (manifest == null) {
      final issue = parsed.issue!;
      return PersonaPackageImportResult.rejected(
        'manifest:${issue.code}:${issue.path}',
      );
    }
    final semanticIssue = validatePersonaManifestSemantics(manifest);
    if (semanticIssue != null) {
      return PersonaPackageImportResult.rejected(semanticIssue);
    }

    final entriesByPath = <String, _DecodedEntry>{};
    var compressedTotal = 0;
    var uncompressedTotal = decoded.manifestBytes.length;
    for (final entry in decoded.entries) {
      final entryIssue = _validateEntry(entry);
      if (entryIssue != null) {
        return PersonaPackageImportResult.rejected(entryIssue);
      }
      if (entriesByPath[entry.path] != null) {
        return const PersonaPackageImportResult.rejected(
          'duplicate_entry_path',
        );
      }
      entriesByPath[entry.path] = entry;
      compressedTotal += entry.compressedSize;
      uncompressedTotal += entry.bytes.length;
      if (compressedTotal > limits.maxArchiveBytes) {
        return const PersonaPackageImportResult.rejected(
          'compressed_entries_too_large',
        );
      }
      if (uncompressedTotal > limits.maxUncompressedBytes) {
        return const PersonaPackageImportResult.rejected(
          'uncompressed_package_too_large',
        );
      }
    }
    if (request.archiveBytes.isEmpty ||
        compressedTotal > request.archiveBytes.length) {
      return const PersonaPackageImportResult.rejected(
        'compressed_size_inconsistent',
      );
    }
    if (uncompressedTotal >
        request.archiveBytes.length * limits.maxCompressionRatio) {
      return const PersonaPackageImportResult.rejected(
        'compression_ratio_exceeded',
      );
    }

    final receipts = <String, PersonaVerifiedResourceReceipt>{};
    for (var index = 0; index < manifest.resources.length; index += 1) {
      final resource = manifest.resources[index];
      final expectedPath = entryPathForRef(resource.ref);
      final uri = Uri.parse(resource.ref);
      final Uint8List? bytes;
      if (uri.scheme == 'package') {
        final entry = entriesByPath.remove(expectedPath);
        if (entry == null) {
          return PersonaPackageImportResult.rejected(
            'resource_entry_missing:$index',
          );
        }
        bytes = entry.bytes;
      } else {
        if (entriesByPath.containsKey(expectedPath)) {
          return PersonaPackageImportResult.rejected(
            'host_resource_in_archive:$index',
          );
        }
        try {
          bytes = hostResourceResolver.resolve(
            PersonaHostResourceRequest._(
              ref: resource.ref,
              kind: resource.kind,
              expectedSha256: resource.sha256,
              scope: request.scope,
            ),
          );
        } on Object {
          return PersonaPackageImportResult.rejected(
            'resource_resolver_failed:$index',
          );
        }
      }
      if (bytes == null) {
        return PersonaPackageImportResult.rejected(
          'resource_unavailable:$index',
        );
      }
      if (bytes.length > limits.maxEntryBytes) {
        return PersonaPackageImportResult.rejected('entry_too_large:$index');
      }
      if (uri.scheme != 'package') {
        uncompressedTotal += bytes.length;
        if (uncompressedTotal > limits.maxUncompressedBytes) {
          return const PersonaPackageImportResult.rejected(
            'uncompressed_package_too_large',
          );
        }
      }
      final actualDigest = sha256.convert(bytes).toString();
      if (actualDigest != resource.sha256) {
        return PersonaPackageImportResult.rejected(
          'resource_digest_mismatch:$index',
        );
      }
      receipts[resource.ref] = PersonaVerifiedResourceReceipt._(
        resourceId: resource.id,
        ref: resource.ref,
        kind: resource.kind,
        sha256: actualDigest,
        byteLength: bytes.length,
        manifestDigest: manifest.canonicalDigest,
        verifiedAt: request.importedAt,
      );
    }
    if (entriesByPath.isNotEmpty) {
      return const PersonaPackageImportResult.rejected('undeclared_entry');
    }

    return PersonaPackageImportResult.accepted(
      PersonaVerifiedPackage._(
        manifest: manifest,
        archiveDigest: sha256.convert(request.archiveBytes).toString(),
        resourceReceipts: receipts,
        verifiedAt: request.importedAt,
      ),
    );
  }

  _ArchiveDecodeResult _decodeArchive(Uint8List archiveBytes) {
    final ZipDirectory directory;
    try {
      directory = ZipDirectory()..read(InputMemoryStream(archiveBytes));
    } on Object {
      return const _ArchiveDecodeResult.rejected('invalid_zip');
    }

    if (directory.filePosition < 0 ||
        directory.numberOfThisDisk != 0 ||
        directory.diskWithTheStartOfTheCentralDirectory != 0 ||
        directory.totalCentralDirectoryEntriesOnThisDisk !=
            directory.totalCentralDirectoryEntries ||
        directory.fileHeaders.length !=
            directory.totalCentralDirectoryEntries ||
        directory.centralDirectoryOffset < 0 ||
        directory.centralDirectorySize < 0 ||
        directory.centralDirectoryOffset + directory.centralDirectorySize >
            directory.filePosition ||
        directory.filePosition + 22 > archiveBytes.length) {
      return const _ArchiveDecodeResult.rejected('invalid_zip_metadata');
    }

    final headers = directory.fileHeaders;
    if (headers.length > limits.maxEntryCount) {
      return const _ArchiveDecodeResult.rejected('too_many_entries');
    }
    final seenPaths = <String>{};
    final entries = <_DecodedEntry>[];
    Uint8List? manifestBytes;
    var compressedTotal = 0;
    var uncompressedTotal = 0;
    for (final header in headers) {
      final path = header.filename;
      if (!seenPaths.add(path)) {
        return const _ArchiveDecodeResult.rejected('duplicate_entry_path');
      }
      if (!_isSafeRelativePath(path)) {
        return const _ArchiveDecodeResult.rejected('unsafe_entry_path');
      }
      if ((header.generalPurposeBitFlag & 0x1) != 0) {
        return const _ArchiveDecodeResult.rejected('encrypted_entry_forbidden');
      }
      final localHeaderIssue = _validateLocalHeader(
        archiveBytes,
        header,
        centralDirectoryOffset: directory.centralDirectoryOffset,
      );
      if (localHeaderIssue != null) {
        return _ArchiveDecodeResult.rejected(localHeaderIssue);
      }
      final unixMode = header.externalFileAttributes >> 16;
      final fileType = unixMode & 0xf000;
      final kind = fileType == 0xa000
          ? _DecodedEntryKind.symbolicLink
          : path.endsWith('/') || fileType == 0x4000
          ? _DecodedEntryKind.directory
          : fileType != 0 && fileType != 0x8000
          ? _DecodedEntryKind.nonRegular
          : _DecodedEntryKind.file;
      if (kind == _DecodedEntryKind.symbolicLink) {
        return const _ArchiveDecodeResult.rejected('symbolic_link_forbidden');
      }
      if (kind == _DecodedEntryKind.nonRegular) {
        // ZIP has no portable hard-link entry type. Rejecting all Unix file
        // types other than regular/unspecified also rejects link-like entries.
        return const _ArchiveDecodeResult.rejected(
          'non_regular_entry_forbidden',
        );
      }
      if (kind != _DecodedEntryKind.file) {
        return const _ArchiveDecodeResult.rejected('non_file_entry_forbidden');
      }
      if (header.localHeaderOffset < 0 ||
          header.localHeaderOffset >= archiveBytes.length ||
          header.compressedSize < 0 ||
          header.uncompressedSize < 0) {
        return const _ArchiveDecodeResult.rejected('invalid_entry_metadata');
      }
      if (header.uncompressedSize > limits.maxEntryBytes) {
        return const _ArchiveDecodeResult.rejected('entry_too_large');
      }
      if (path == manifestEntryPath &&
          header.uncompressedSize > limits.maxManifestBytes) {
        return const _ArchiveDecodeResult.rejected('manifest_too_large');
      }
      if (header.uncompressedSize > 0 && header.compressedSize == 0) {
        return const _ArchiveDecodeResult.rejected('invalid_compressed_size');
      }
      if (header.compressedSize > 0 &&
          header.uncompressedSize >
              header.compressedSize * limits.maxCompressionRatio) {
        return const _ArchiveDecodeResult.rejected(
          'compression_ratio_exceeded',
        );
      }
      compressedTotal += header.compressedSize;
      uncompressedTotal += header.uncompressedSize;
      if (compressedTotal > limits.maxArchiveBytes) {
        return const _ArchiveDecodeResult.rejected(
          'compressed_entries_too_large',
        );
      }
      if (uncompressedTotal > limits.maxUncompressedBytes) {
        return const _ArchiveDecodeResult.rejected(
          'uncompressed_package_too_large',
        );
      }

      final Uint8List bytes;
      try {
        final entryLimit = path == manifestEntryPath
            ? math.min(limits.maxManifestBytes, limits.maxEntryBytes)
            : limits.maxEntryBytes;
        final totalRemaining =
            limits.maxUncompressedBytes -
            (uncompressedTotal - header.uncompressedSize);
        if (totalRemaining < 0) {
          return const _ArchiveDecodeResult.rejected(
            'uncompressed_package_too_large',
          );
        }
        final output = _BoundedArchiveOutput(
          math.min(entryLimit, totalRemaining),
        );
        final file = header.file;
        if (file == null) {
          return const _ArchiveDecodeResult.rejected('invalid_zip_metadata');
        }
        file.decompress(output);
        final decoded = output.takeBytes();
        if (decoded.length != header.uncompressedSize) {
          return const _ArchiveDecodeResult.rejected('archive_size_mismatch');
        }
        if (getCrc32(decoded) != header.crc32) {
          return const _ArchiveDecodeResult.rejected('archive_crc_mismatch');
        }
        bytes = decoded;
      } on _ArchiveExpansionLimit {
        return const _ArchiveDecodeResult.rejected(
          'archive_expansion_limit_exceeded',
        );
      } on Object {
        return const _ArchiveDecodeResult.rejected('archive_decode_failed');
      }
      if (path == manifestEntryPath) {
        manifestBytes = bytes;
      } else {
        entries.add(
          _DecodedEntry(
            path: path,
            bytes: bytes,
            compressedSize: header.compressedSize,
            kind: kind,
          ),
        );
      }
    }
    if (manifestBytes == null) {
      return const _ArchiveDecodeResult.rejected('manifest_missing');
    }
    return _ArchiveDecodeResult.accepted(
      _DecodedArchive(manifestBytes: manifestBytes, entries: entries),
    );
  }

  String? _validateLocalHeader(
    Uint8List archiveBytes,
    ZipFileHeader central, {
    required int centralDirectoryOffset,
  }) {
    try {
      if (central.localHeaderOffset < 0 ||
          central.localHeaderOffset + 30 > archiveBytes.length) {
        return 'invalid_entry_metadata';
      }
      final input = InputMemoryStream(
        archiveBytes,
        offset: central.localHeaderOffset,
      );
      if (input.readUint32() != ZipFile.zipSignature) {
        return 'archive_header_mismatch';
      }
      input.readUint16();
      final flags = input.readUint16();
      final compressionMethod = input.readUint16();
      input.readUint16();
      input.readUint16();
      final crc32 = input.readUint32();
      final compressedSize = input.readUint32();
      final uncompressedSize = input.readUint32();
      final filenameLength = input.readUint16();
      final extraLength = input.readUint16();
      if ((flags & 0x08) != 0) {
        // Data descriptors make local/central size and CRC agreement
        // ambiguous. Persona packages deliberately fail closed instead.
        return 'zip_data_descriptor_forbidden';
      }
      if (flags != central.generalPurposeBitFlag ||
          compressionMethod != central.compressionMethod ||
          !const <int>{0, 8, 12}.contains(compressionMethod) ||
          crc32 != central.crc32 ||
          compressedSize != central.compressedSize ||
          uncompressedSize != central.uncompressedSize ||
          filenameLength <= 0 ||
          filenameLength > 768 ||
          extraLength > 64 * 1024 ||
          input.length < filenameLength + extraLength) {
        return 'archive_header_mismatch';
      }
      final filename = input.readString(size: filenameLength);
      input.skip(extraLength);
      if (filename != central.filename ||
          central.localHeaderOffset + input.position + compressedSize >
              centralDirectoryOffset) {
        return 'archive_header_mismatch';
      }
      return null;
    } on Object {
      return 'archive_header_mismatch';
    }
  }

  String? _validateEntry(_DecodedEntry entry) {
    if (entry.kind == _DecodedEntryKind.symbolicLink) {
      return 'symbolic_link_forbidden';
    }
    if (entry.kind == _DecodedEntryKind.nonRegular) {
      return 'non_regular_entry_forbidden';
    }
    if (entry.kind != _DecodedEntryKind.file) {
      return 'non_file_entry_forbidden';
    }
    if (!_isSafeRelativePath(entry.path)) {
      return 'unsafe_entry_path';
    }
    if (entry.bytes.length > limits.maxEntryBytes) {
      return 'entry_too_large';
    }
    if (entry.bytes.isNotEmpty && entry.compressedSize == 0) {
      return 'invalid_compressed_size';
    }
    if (entry.compressedSize > 0 &&
        entry.bytes.length >
            entry.compressedSize * limits.maxCompressionRatio) {
      return 'compression_ratio_exceeded';
    }
    return null;
  }

  static String entryPathForRef(String ref) {
    final uri = Uri.parse(ref);
    return <String>[uri.scheme, uri.host, ...uri.pathSegments].join('/');
  }

  static bool _isSafeRelativePath(String path) {
    if (path.isEmpty ||
        path.length > 768 ||
        path.startsWith('/') ||
        path.endsWith('/') ||
        path.contains('\\') ||
        path.contains('%') ||
        path.contains(':')) {
      return false;
    }
    final segments = path.split('/');
    return segments.every(
      (segment) =>
          segment.isNotEmpty &&
          segment != '.' &&
          segment != '..' &&
          RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(segment),
    );
  }
}

final class _JsonBudget {
  _JsonBudget(this.limits);

  final PersonaPackageImportLimits limits;
  int _nodes = 0;
  int _stringCodeUnits = 0;
  String? reason;

  bool accepts(Object? value) {
    _visit(value, 1);
    return reason == null;
  }

  void _visit(Object? value, int depth) {
    if (reason != null) return;
    _nodes += 1;
    if (_nodes > limits.maxJsonNodes) {
      reason = 'json_node_budget_exceeded';
      return;
    }
    if (depth > limits.maxJsonDepth) {
      reason = 'json_depth_exceeded';
      return;
    }
    if (value is String) {
      _addString(value);
      return;
    }
    if (value is List) {
      for (final item in value) {
        _visit(item, depth + 1);
      }
      return;
    }
    if (value is Map) {
      for (final entry in value.entries) {
        if (entry.key is! String) {
          reason = 'json_non_string_key';
          return;
        }
        _addString(entry.key as String);
        _visit(entry.value, depth + 1);
      }
    }
  }

  void _addString(String value) {
    if (value.length > limits.maxJsonStringLength) {
      reason = 'json_string_too_long';
      return;
    }
    _stringCodeUnits += value.length;
    if (_stringCodeUnits > limits.maxJsonStringCodeUnits) {
      reason = 'json_string_budget_exceeded';
    }
  }
}

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'account_storage_scope_service.dart';
import 'markdown_document_store_base.dart';
import 'scoped_storage_directory_io.dart';

Future<MarkdownDocumentStore> openMarkdownDocumentStore(String fileName) async {
  final dir = await getApplicationDocumentsDirectory();
  return _FileMarkdownDocumentStore(File(p.join(dir.path, fileName)));
}

Future<MarkdownDocumentStore> openAccountMarkdownDocumentStore(
  AccountStorageScope scope,
  AccountMarkdownDocumentKind document,
) {
  return _openScopedMarkdownDocumentStore(
    relativeDirectorySegments: scope.accountDirectorySegments,
    fileName: document.fileName,
  );
}

Future<MarkdownDocumentStore> openAgentMarkdownDocumentStore(
  AgentStorageScope scope,
  AgentMarkdownDocumentKind document,
) {
  return _openScopedMarkdownDocumentStore(
    relativeDirectorySegments: scope.agentDirectorySegments,
    fileName: document.fileName,
  );
}

Future<MarkdownDocumentStore> _openScopedMarkdownDocumentStore({
  required List<String> relativeDirectorySegments,
  required String fileName,
}) async {
  final supportRoot = await getApplicationSupportDirectory();
  final file = await resolveScopedStorageFile(
    applicationSupportRoot: Directory(supportRoot.path),
    relativeDirectorySegments: relativeDirectorySegments,
    fileName: fileName,
  );
  return _FileMarkdownDocumentStore(file);
}

final class _FileMarkdownDocumentStore implements MarkdownDocumentStore {
  _FileMarkdownDocumentStore(this._file);

  final File _file;

  @override
  Future<String?> read() async {
    if (!await _file.exists()) return null;
    return _file.readAsString();
  }

  @override
  Future<void> write(String contents) {
    return _file.writeAsString(contents);
  }
}

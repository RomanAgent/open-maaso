import 'account_storage_scope_service.dart';
import 'markdown_document_store_base.dart';
import 'markdown_document_store_stub.dart'
    if (dart.library.io) 'markdown_document_store_io.dart'
    if (dart.library.js_interop) 'markdown_document_store_web.dart'
    as implementation;

export 'markdown_document_store_base.dart';

Future<MarkdownDocumentStore> openMarkdownDocumentStore(String fileName) {
  return implementation.openMarkdownDocumentStore(fileName);
}

/// Opens a fixed account-owned document without consulting legacy storage.
Future<MarkdownDocumentStore> openAccountMarkdownDocumentStore(
  AccountStorageScope scope,
  AccountMarkdownDocumentKind document,
) {
  return implementation.openAccountMarkdownDocumentStore(scope, document);
}

/// Opens a fixed agent-owned document without consulting legacy storage.
Future<MarkdownDocumentStore> openAgentMarkdownDocumentStore(
  AgentStorageScope scope,
  AgentMarkdownDocumentKind document,
) {
  return implementation.openAgentMarkdownDocumentStore(scope, document);
}

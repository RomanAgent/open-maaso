import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';

import 'account_storage_scope_service.dart';
import 'scoped_storage_directory_io.dart';

Future<Database> openDefaultAppDatabase() async {
  final dir = await getApplicationDocumentsDirectory();
  final dbPath = p.join(dir.path, 'maaso.db');
  return databaseFactoryIo.openDatabase(dbPath);
}

Future<Database> openScopedAppDatabase(AccountStorageScope scope) async {
  final supportRoot = await getApplicationSupportDirectory();
  final databaseFile = await resolveScopedStorageFile(
    applicationSupportRoot: Directory(supportRoot.path),
    relativeDirectorySegments: scope.accountDirectorySegments,
    fileName: AccountStorageScope.nativeDatabaseFileName,
  );
  return databaseFactoryIo.openDatabase(databaseFile.path);
}

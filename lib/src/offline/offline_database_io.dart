import 'package:path_provider/path_provider.dart';
import 'package:sembast/sembast_io.dart';

import '../core/services/persistence/scoped_storage_directory_io.dart';

Future<Database> openOfflineDatabase() async {
  final root = await getApplicationSupportDirectory();
  final file = await resolveScopedStorageFile(
    applicationSupportRoot: root,
    relativeDirectorySegments: const ['open-maaso', 'offline-v1'],
    fileName: 'state.db',
  );
  return databaseFactoryIo.openDatabase(file.path);
}

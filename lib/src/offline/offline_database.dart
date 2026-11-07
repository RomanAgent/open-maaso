import 'package:sembast/sembast.dart';

import 'offline_database_stub.dart'
    if (dart.library.io) 'offline_database_io.dart'
    if (dart.library.js_interop) 'offline_database_web.dart'
    as platform;

Future<Database> openOfflineDatabase() => platform.openOfflineDatabase();

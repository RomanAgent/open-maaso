import 'package:sembast_web/sembast_web.dart';

Future<Database> openOfflineDatabase() =>
    databaseFactoryWeb.openDatabase('open-maaso.offline-v1');

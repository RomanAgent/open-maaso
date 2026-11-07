import 'package:sembast/sembast.dart';

Future<Database> openOfflineDatabase() => Future.error(
  UnsupportedError('Local persistence is unavailable on this host.'),
);

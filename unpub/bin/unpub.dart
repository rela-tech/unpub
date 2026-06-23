import 'dart:io';
import 'package:path/path.dart' as path;
import 'package:args/args.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:unpub/unpub.dart' as unpub;

main(List<String> args) async {
  var parser = ArgParser();
  parser.addOption('host', abbr: 'h', defaultsTo: '0.0.0.0');
  parser.addOption('port', abbr: 'p', defaultsTo: '4000');
  parser.addOption('database-type',
      abbr: 't',
      defaultsTo: 'sqlite',
      allowedHelp: {
        'sqlite': 'Use SQLite as metadata store (default)',
        'mongo': 'Use MongoDB as metadata store',
      });
  parser.addOption('database',
      abbr: 'd', defaultsTo: 'unpub.db');
  parser.addOption('proxy-origin', abbr: 'o', defaultsTo: '');
  parser.addOption('uploader-email',
      abbr: 'u',
      defaultsTo: '',
      help: 'Override uploader email. When set, Google OAuth is skipped.');

  var results = parser.parse(args);

  var host = results['host'] as String;
  var port = int.parse(results['port'] as String);
  var databaseType = results['database-type'] as String;
  var databaseUri = results['database'] as String;
  var proxyOrigin = results['proxy-origin'] as String;
  var uploaderEmail = results['uploader-email'] as String;

  if (results.rest.isNotEmpty) {
    print('Got unexpected arguments: "${results.rest.join(' ')}".\n\nUsage:\n');
    print(parser.usage);
    exit(1);
  }

  unpub.MetaStore metaStore;
  if (databaseType == 'mongo') {
    final db = Db(databaseUri);
    await db.open();
    metaStore = unpub.MongoStore(db);
  } else {
    metaStore = await unpub.SqliteStore.open(databaseUri);
  }

  var baseDir = path.absolute('unpub-packages');

  var app = unpub.App(
    metaStore: metaStore,
    packageStore: unpub.FileStore(baseDir),
    proxy_origin: proxyOrigin.trim().isEmpty ? null : Uri.parse(proxyOrigin),
    overrideUploaderEmail: uploaderEmail.trim().isEmpty ? null : uploaderEmail.trim(),
  );

  var server = await app.serve(host, port);
  print('Serving at http://${server.address.host}:${server.port}');
}

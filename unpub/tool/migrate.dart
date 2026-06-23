/// MongoDB to SQLite migration tool.
///
/// Usage:
///   dart run tool/migrate.dart --mongo mongodb://localhost:27017/dart_pub --sqlite unpub.db
///
/// This reads all packages from MongoDB and writes them to a new SQLite database.
/// The original MongoDB database is left untouched.

import 'package:args/args.dart';
import 'package:mongo_dart/mongo_dart.dart';
import 'package:unpub/unpub.dart';

final packageCollection = 'packages';

Future<void> main(List<String> args) async {
  final parser = ArgParser()
    ..addOption('mongo',
        abbr: 'm',
        defaultsTo: 'mongodb://localhost:27017/dart_pub',
        help: 'MongoDB connection URI')
    ..addOption('sqlite',
        abbr: 's',
        defaultsTo: 'unpub.db',
        help: 'SQLite database path');

  final results = parser.parse(args);
  final mongoUri = results['mongo'] as String;
  final sqlitePath = results['sqlite'] as String;

  print('Connecting to MongoDB: $mongoUri ...');
  final mongoDb = Db(mongoUri);
  await mongoDb.open();

  print('Opening SQLite: $sqlitePath ...');
  final sqliteStore = await SqliteStore.open(sqlitePath);

  final packages =
      await mongoDb.collection(packageCollection).find().toList();
  print('Found ${packages.length} packages in MongoDB.');

  for (final pkg in packages) {
    final name = pkg['name'] as String;
    final versions = pkg['versions'] as List;
    print('  Migrating $name (${versions.length} versions)...');

    for (final ver in versions) {
      final uploader = ver['uploader'] as String?;
      final createdAt = ver['createdAt'] as DateTime? ?? DateTime.now();

      final version = UnpubVersion(
        ver['version'] as String,
        (ver['pubspec'] as Map).cast<String, dynamic>(),
        ver['pubspecYaml'] as String?,
        uploader,
        ver['readme'] as String?,
        ver['changelog'] as String?,
        createdAt,
      );
      await sqliteStore.addVersion(name, version);
    }

    // Migrate uploaders
    final uploaders = (pkg['uploaders'] as List?)?.cast<String>() ?? [];
    for (final email in uploaders) {
      await sqliteStore.addUploader(name, email);
    }

    // Migrate download count
    final download = (pkg['download'] as int?) ?? 0;
    if (download > 0) {
      for (var i = 0; i < download; i++) {
        // Use last version as the referenced version for stats
        final lastVer = versions.last['version'] as String;
        sqliteStore.increaseDownloads(name, lastVer);
      }
    }
  }

  await sqliteStore.db.close();
  await mongoDb.close();
  print('');
  print('Migration complete! SQLite database saved to: $sqlitePath');
  print('');
  print(
      'You can now start unpub with: unpub --database-type sqlite --database $sqlitePath');
}

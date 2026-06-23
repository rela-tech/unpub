import 'dart:convert';

import 'package:intl/intl.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:unpub/src/models.dart';
import 'meta_store.dart';

class SqliteStore extends MetaStore {
  final Database db;

  SqliteStore._(this.db);

  static Future<SqliteStore> open(String path) async {
    sqfliteFfiInit();
    final databaseFactory = databaseFactoryFfi;

    final db = await databaseFactory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 1,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE packages (
              name TEXT PRIMARY KEY,
              private INTEGER NOT NULL DEFAULT 1,
              download INTEGER NOT NULL DEFAULT 0,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE versions (
              package_name TEXT NOT NULL,
              version TEXT NOT NULL,
              pubspec TEXT NOT NULL,
              pubspec_yaml TEXT,
              uploader TEXT,
              readme TEXT,
              changelog TEXT,
              created_at TEXT NOT NULL,
              PRIMARY KEY (package_name, version),
              FOREIGN KEY (package_name) REFERENCES packages(name)
            )
          ''');
          await db.execute('''
            CREATE TABLE uploaders (
              package_name TEXT NOT NULL,
              email TEXT NOT NULL,
              PRIMARY KEY (package_name, email),
              FOREIGN KEY (package_name) REFERENCES packages(name)
            )
          ''');
          await db.execute('''
            CREATE TABLE stats (
              package_name TEXT NOT NULL,
              date TEXT NOT NULL,
              downloads INTEGER NOT NULL DEFAULT 1,
              PRIMARY KEY (package_name, date),
              FOREIGN KEY (package_name) REFERENCES packages(name)
            )
          ''');
        },
      ),
    );

    await db.execute('PRAGMA journal_mode=WAL');
    return SqliteStore._(db);
  }

  @override
  Future<UnpubPackage?> queryPackage(String name) async {
    final pkgRows = await db.query(
      'packages',
      where: 'name = ?',
      whereArgs: [name],
    );
    if (pkgRows.isEmpty) return null;

    final versionRows = await db.query(
      'versions',
      where: 'package_name = ?',
      whereArgs: [name],
      orderBy: 'created_at',
    );

    final uploaderRows = await db.query(
      'uploaders',
      columns: ['email'],
      where: 'package_name = ?',
      whereArgs: [name],
    );

    return _assemblePackage(pkgRows.first, versionRows, uploaderRows);
  }

  @override
  Future<void> addVersion(String name, UnpubVersion version) async {
    await db.transaction((txn) async {
      // Upsert package
      final existing = await txn.query(
        'packages',
        where: 'name = ?',
        whereArgs: [name],
      );

      final nowStr = version.createdAt.toIso8601String();
      if (existing.isEmpty) {
        await txn.insert('packages', {
          'name': name,
          'private': 1,
          'download': 0,
          'created_at': nowStr,
          'updated_at': nowStr,
        });
      } else {
        await txn.update(
          'packages',
          {'updated_at': nowStr},
          where: 'name = ?',
          whereArgs: [name],
        );
      }

      // Insert version
      await txn.insert('versions', {
        'package_name': name,
        'version': version.version,
        'pubspec': json.encode(version.pubspec),
        'pubspec_yaml': version.pubspecYaml,
        'uploader': version.uploader,
        'readme': version.readme,
        'changelog': version.changelog,
        'created_at': nowStr,
      });

      // Insert uploader (ignore if already exists)
      if (version.uploader != null) {
        await txn.rawInsert(
          'INSERT OR IGNORE INTO uploaders (package_name, email) VALUES (?, ?)',
          [name, version.uploader],
        );
      }
    });
  }

  @override
  Future<void> addUploader(String name, String email) async {
    await db.rawInsert(
      'INSERT OR IGNORE INTO uploaders (package_name, email) VALUES (?, ?)',
      [name, email],
    );
  }

  @override
  Future<void> removeUploader(String name, String email) async {
    await db.delete(
      'uploaders',
      where: 'package_name = ? AND email = ?',
      whereArgs: [name, email],
    );
  }

  @override
  void increaseDownloads(String name, String version) {
    final today = DateFormat('yyyyMMdd').format(DateTime.now());

    // Increment package download count
    db.rawUpdate(
      'UPDATE packages SET download = download + 1 WHERE name = ?',
      [name],
    );

    // Increment daily stats
    db.rawUpdate(
      'INSERT INTO stats (package_name, date, downloads) VALUES (?, ?, 1) '
      'ON CONFLICT(package_name, date) DO UPDATE SET downloads = downloads + 1',
      [name, today],
    );
  }

  @override
  Future<UnpubQueryResult> queryPackages({
    required int size,
    required int page,
    required String sort,
    String? keyword,
    String? uploader,
    String? dependency,
  }) async {
    // Whitelist sort field to prevent SQL injection
    const allowedSorts = {'download', 'updatedAt', 'createdAt', 'name'};
    final sortField = allowedSorts.contains(sort) ? sort : 'download';

    // Build WHERE clauses
    final whereClauses = <String>[];
    final whereArgs = <dynamic>[];

    if (keyword != null) {
      whereClauses.add('p.name LIKE ?');
      whereArgs.add('%$keyword%');
    }

    if (uploader != null) {
      whereClauses.add(
          'EXISTS (SELECT 1 FROM uploaders u WHERE u.package_name = p.name AND u.email = ?)');
      whereArgs.add(uploader);
    }

    if (dependency != null) {
      whereClauses.add(
          'EXISTS (SELECT 1 FROM versions vd WHERE vd.package_name = p.name AND vd.pubspec LIKE ?) '
          'AND p.name != ?');
      whereArgs.add('%$dependency%');
      whereArgs.add(dependency);
    }

    final whereSql =
        whereClauses.isNotEmpty ? 'WHERE ${whereClauses.join(' AND ')}' : '';

    // Count
    final countResult = await db.rawQuery(
      'SELECT COUNT(*) as cnt FROM packages p $whereSql',
      whereArgs,
    );
    final count = countResult.first['cnt'] as int;

    // Query with sort and pagination
    final rows = await db.rawQuery(
      'SELECT p.* FROM packages p $whereSql '
      'ORDER BY p.$sortField DESC '
      'LIMIT ? OFFSET ?',
      [...whereArgs, size, page * size],
    );

    // Assemble packages with versions and uploaders
    final packages = <UnpubPackage>[];
    for (final row in rows) {
      final name = row['name'] as String;
      final versionRows = await db.query(
        'versions',
        where: 'package_name = ?',
        whereArgs: [name],
        orderBy: 'created_at',
      );
      final uploaderRows = await db.query(
        'uploaders',
        columns: ['email'],
        where: 'package_name = ?',
        whereArgs: [name],
      );
      packages.add(_assemblePackage(row, versionRows, uploaderRows));
    }

    return UnpubQueryResult(count, packages);
  }

  /// Assemble an [UnpubPackage] from raw table rows.
  UnpubPackage _assemblePackage(
    Map<String, dynamic> pkgRow,
    List<Map<String, dynamic>> versionRows,
    List<Map<String, dynamic>> uploaderRows,
  ) {
    return UnpubPackage(
      pkgRow['name'] as String,
      versionRows.map((v) {
        return UnpubVersion(
          v['version'] as String,
          json.decode(v['pubspec'] as String) as Map<String, dynamic>,
          v['pubspec_yaml'] as String?,
          v['uploader'] as String?,
          v['readme'] as String?,
          v['changelog'] as String?,
          DateTime.parse(v['created_at'] as String),
        );
      }).toList(),
      (pkgRow['private'] as int?) == 1,
      uploaderRows.map((u) => u['email'] as String).toList(),
      DateTime.parse(pkgRow['created_at'] as String),
      DateTime.parse(pkgRow['updated_at'] as String),
      pkgRow['download'] as int?,
    );
  }
}

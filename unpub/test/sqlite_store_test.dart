import 'dart:io';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:test/test.dart';
import 'package:unpub/unpub.dart';

/// Helper to create an in-memory SQLite store for testing.
Future<SqliteStore> createTestStore() async {
  final store = await SqliteStore.open(':memory:');
  return store;
}

/// Read raw package data from the SQLite database for verification.
Future<Map<String, dynamic>?> readPackageFromDb(Database db, String name) async {
  final rows = await db.rawQuery(
    'SELECT * FROM packages WHERE name = ?',
    [name],
  );
  if (rows.isEmpty) return null;
  return rows.first;
}

/// Read all versions for a package from the SQLite database.
Future<List<Map<String, dynamic>>> readVersionsFromDb(
    Database db, String packageName) async {
  return await db.rawQuery(
    'SELECT * FROM versions WHERE package_name = ? ORDER BY created_at',
    [packageName],
  );
}

/// Read all uploaders for a package from the SQLite database.
Future<List<String>> readUploadersFromDb(Database db, String packageName) async {
  final rows = await db.rawQuery(
    'SELECT email FROM uploaders WHERE package_name = ?',
    [packageName],
  );
  return rows.map((r) => r['email'] as String).toList();
}

/// Read stats for a package from the SQLite database.
Future<Map<String, int>> readStatsFromDb(Database db, String packageName) async {
  final rows = await db.rawQuery(
    'SELECT date, downloads FROM stats WHERE package_name = ?',
    [packageName],
  );
  return {for (var r in rows) r['date'] as String: r['downloads'] as int};
}

void main() {
  group('SqliteStore', () {
    late SqliteStore store;

    setUp(() async {
      store = await createTestStore();
    });

    tearDown(() async {
      await store.db.close();
    });

    group('queryPackage', () {
      test('returns null for non-existent package', () async {
        final result = await store.queryPackage('non_existent');
        expect(result, isNull);
      });

      test('returns UnpubPackage with versions and uploaders', () async {
        final now = DateTime.now();
        await store.addVersion(
          'my_package',
          UnpubVersion(
            '1.0.0',
            {'name': 'my_package', 'version': '1.0.0'},
            'name: my_package\nversion: 1.0.0',
            'dev@example.com',
            '# Readme',
            '# Changelog',
            now,
          ),
        );

        final result = await store.queryPackage('my_package');
        expect(result, isNotNull);
        expect(result!.name, 'my_package');
        expect(result.private, true);
        expect(result.download, 0);
        expect(result.uploaders, ['dev@example.com']);
        expect(result.versions, hasLength(1));
        expect(result.versions.first.version, '1.0.0');
        expect(result.versions.first.pubspec['name'], 'my_package');
        expect(result.versions.first.uploader, 'dev@example.com');
        expect(result.versions.first.readme, '# Readme');
        expect(result.versions.first.changelog, '# Changelog');
      });
    });

    group('addVersion', () {
      test('creates new package with version and uploader on first publish',
          () async {
        final now = DateTime.now();
        await store.addVersion(
          'new_pkg',
          UnpubVersion(
            '0.1.0',
            {'name': 'new_pkg', 'version': '0.1.0'},
            'name: new_pkg\nversion: 0.1.0',
            'author@example.com',
            null,
            null,
            now,
          ),
        );

        // Verify in DB directly
        final pkg = await readPackageFromDb(store.db, 'new_pkg');
        expect(pkg, isNotNull);
        expect(pkg!['name'], 'new_pkg');
        expect(pkg['private'], 1);
        expect(pkg['download'], 0);
        expect(pkg['created_at'], isNotNull);
        expect(pkg['updated_at'], isNotNull);

        final versions = await readVersionsFromDb(store.db, 'new_pkg');
        expect(versions, hasLength(1));
        expect(versions.first['version'], '0.1.0');
        expect(versions.first['pubspec_yaml'], 'name: new_pkg\nversion: 0.1.0');

        final uploaders = await readUploadersFromDb(store.db, 'new_pkg');
        expect(uploaders, ['author@example.com']);
      });

      test('adds version to existing package without duplicating uploaders',
          () async {
        final now = DateTime.now();
        await store.addVersion(
          'my_pkg',
          UnpubVersion(
            '0.1.0',
            {'name': 'my_pkg', 'version': '0.1.0'},
            null,
            'dev@example.com',
            null,
            null,
            now,
          ),
        );

        // Add second version by same uploader
        await store.addVersion(
          'my_pkg',
          UnpubVersion(
            '0.2.0',
            {'name': 'my_pkg', 'version': '0.2.0'},
            null,
            'dev@example.com',
            null,
            null,
            now,
          ),
        );

        final versions = await readVersionsFromDb(store.db, 'my_pkg');
        expect(versions, hasLength(2));

        final uploaders = await readUploadersFromDb(store.db, 'my_pkg');
        expect(uploaders, hasLength(1)); // not duplicated
        expect(uploaders, ['dev@example.com']);
      });

      test('updates updated_at on new version', () async {
        final t1 = DateTime(2024, 1, 1, 10, 0, 0);
        final t2 = DateTime(2024, 6, 15, 12, 0, 0);

        await store.addVersion(
          'pkg',
          UnpubVersion(
            '1.0.0',
            {'name': 'pkg', 'version': '1.0.0'},
            null,
            'a@b.com',
            null,
            null,
            t1,
          ),
        );

        var pkg = await readPackageFromDb(store.db, 'pkg');
        expect(pkg!['updated_at'], t1.toIso8601String());

        await store.addVersion(
          'pkg',
          UnpubVersion(
            '2.0.0',
            {'name': 'pkg', 'version': '2.0.0'},
            null,
            'a@b.com',
            null,
            null,
            t2,
          ),
        );

        pkg = await readPackageFromDb(store.db, 'pkg');
        expect(pkg!['updated_at'], t2.toIso8601String());
        expect(pkg['created_at'], t1.toIso8601String()); // unchanged
      });

      test('sets initial download count to 0', () async {
        await store.addVersion(
          'pkg',
          UnpubVersion(
            '1.0.0',
            {'name': 'pkg', 'version': '1.0.0'},
            null,
            'x@y.com',
            null,
            null,
            DateTime.now(),
          ),
        );

        final pkg = await readPackageFromDb(store.db, 'pkg');
        expect(pkg!['download'], 0);
      });
    });

    group('addUploader', () {
      setUp(() async {
        await store.addVersion(
          'pkg',
          UnpubVersion(
            '1.0.0',
            {'name': 'pkg', 'version': '1.0.0'},
            null,
            'owner@example.com',
            null,
            null,
            DateTime.now(),
          ),
        );
      });

      test('adds new uploader to package', () async {
        await store.addUploader('pkg', 'collaborator@example.com');

        final uploaders = await readUploadersFromDb(store.db, 'pkg');
        expect(uploaders, contains('collaborator@example.com'));
        expect(uploaders, contains('owner@example.com'));
      });

      test('does not duplicate existing uploader', () async {
        await store.addUploader('pkg', 'owner@example.com');

        final uploaders = await readUploadersFromDb(store.db, 'pkg');
        expect(uploaders, hasLength(1));
      });
    });

    group('removeUploader', () {
      setUp(() async {
        await store.addVersion(
          'pkg',
          UnpubVersion(
            '1.0.0',
            {'name': 'pkg', 'version': '1.0.0'},
            null,
            'owner@example.com',
            null,
            null,
            DateTime.now(),
          ),
        );
      });

      test('removes uploader from package', () async {
        await store.addUploader('pkg', 'temp@example.com');
        await store.removeUploader('pkg', 'temp@example.com');

        final uploaders = await readUploadersFromDb(store.db, 'pkg');
        expect(uploaders, isNot(contains('temp@example.com')));
        expect(uploaders, contains('owner@example.com'));
      });

      test('does nothing if uploader not present', () async {
        await store.removeUploader('pkg', 'nonexistent@example.com');

        final uploaders = await readUploadersFromDb(store.db, 'pkg');
        expect(uploaders, ['owner@example.com']);
      });
    });

    group('increaseDownloads', () {
      setUp(() async {
        await store.addVersion(
          'pkg',
          UnpubVersion(
            '1.0.0',
            {'name': 'pkg', 'version': '1.0.0'},
            null,
            'a@b.com',
            null,
            null,
            DateTime.now(),
          ),
        );
      });

      test('increments package download count', () async {
        store.increaseDownloads('pkg', '1.0.0');
        store.increaseDownloads('pkg', '1.0.0');
        // increaseDownloads is sync (returns void), but the DB write may be
        // async. We need to wait a bit for the writes to complete.
        await Future.delayed(Duration(milliseconds: 100));

        final pkg = await readPackageFromDb(store.db, 'pkg');
        expect(pkg!['download'], 2);
      });

      test('records daily download stats', () async {
        store.increaseDownloads('pkg', '1.0.0');
        await Future.delayed(Duration(milliseconds: 100));

        final stats = await readStatsFromDb(store.db, 'pkg');
        expect(stats, isNotEmpty);
        final todayKey = stats.keys.first;
        expect(stats[todayKey], 1);

        // Second download today
        store.increaseDownloads('pkg', '1.0.0');
        await Future.delayed(Duration(milliseconds: 100));

        final stats2 = await readStatsFromDb(store.db, 'pkg');
        expect(stats2[todayKey], 2);
      });
    });

    group('queryPackages', () {
      late DateTime now;

      setUp(() async {
        now = DateTime.now();
        // Create multiple packages for search/pagination testing
        await store.addVersion(
          'alpha_pkg',
          UnpubVersion(
            '1.0.0',
            {'name': 'alpha_pkg', 'version': '1.0.0', 'dependencies': {'http': '^0.13.0'}},
            null,
            'dev1@example.com',
            null,
            null,
            now,
          ),
        );
        await store.addVersion(
          'beta_lib',
          UnpubVersion(
            '2.0.0',
            {'name': 'beta_lib', 'version': '2.0.0', 'dependencies': {'alpha_pkg': '^1.0.0'}},
            null,
            'dev2@example.com',
            null,
            null,
            now,
          ),
        );
        await store.addVersion(
          'gamma_util',
          UnpubVersion(
            '0.5.0',
            {'name': 'gamma_util', 'version': '0.5.0'},
            null,
            'dev1@example.com',
            null,
            null,
            now,
          ),
        );

        // Add downloads to make sorting meaningful
        store.increaseDownloads('beta_lib', '2.0.0');
        store.increaseDownloads('beta_lib', '2.0.0');
        store.increaseDownloads('alpha_pkg', '1.0.0');
        await Future.delayed(Duration(milliseconds: 100));
      });

      test('returns paginated results sorted by download desc', () async {
        final result = await store.queryPackages(
          size: 10,
          page: 0,
          sort: 'download',
        );

        expect(result.count, 3);
        expect(result.packages, hasLength(3));
        // beta_lib has 2 downloads, should be first
        expect(result.packages[0].name, 'beta_lib');
        expect(result.packages[1].name, 'alpha_pkg');
        expect(result.packages[2].name, 'gamma_util');
      });

      test('respects pagination (size and page)', () async {
        final result = await store.queryPackages(
          size: 2,
          page: 0,
          sort: 'download',
        );

        expect(result.count, 3);
        expect(result.packages, hasLength(2));
      });

      test('filters by keyword (name LIKE match)', () async {
        final result = await store.queryPackages(
          size: 10,
          page: 0,
          sort: 'download',
          keyword: 'beta',
        );

        expect(result.count, 1);
        expect(result.packages.first.name, 'beta_lib');
      });

      test('filters by uploader email', () async {
        final result = await store.queryPackages(
          size: 10,
          page: 0,
          sort: 'download',
          uploader: 'dev1@example.com',
        );

        expect(result.count, 2);
        final names = result.packages.map((p) => p.name).toSet();
        expect(names, contains('alpha_pkg'));
        expect(names, contains('gamma_util'));
      });

      test('filters by dependency name', () async {
        final result = await store.queryPackages(
          size: 10,
          page: 0,
          sort: 'download',
          dependency: 'alpha_pkg',
        );

        expect(result.count, 1);
        expect(result.packages.first.name, 'beta_lib');
      });

      test('returns empty list when no packages match', () async {
        final result = await store.queryPackages(
          size: 10,
          page: 0,
          sort: 'download',
          keyword: 'nonexistent',
        );

        expect(result.count, 0);
        expect(result.packages, isEmpty);
      });
    });
  });
}

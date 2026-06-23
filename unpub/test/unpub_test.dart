import 'dart:io';
import 'dart:convert';
import 'package:collection/collection.dart';
import 'package:unpub/src/utils.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'utils.dart';
import 'package:unpub/unpub.dart';

main() {
  late HttpServer _server;
  late SqliteStore _store;

  Future<Map<String, dynamic>> _readMeta(String name) async {
    final result = await _store.db.rawQuery(
      'SELECT * FROM packages WHERE name = ?',
      [name],
    );
    if (result.isEmpty) throw 'package $name not found';

    final pkg = result.first;
    final versions = await _store.db.rawQuery(
      'SELECT * FROM versions WHERE package_name = ? ORDER BY created_at',
      [name],
    );
    final uploaders = await _store.db.rawQuery(
      'SELECT email FROM uploaders WHERE package_name = ?',
      [name],
    );

    return {
      'name': pkg['name'],
      'private': pkg['private'] == 1,
      'download': pkg['download'],
      'createdAt': DateTime.parse(pkg['created_at'] as String),
      'updatedAt': DateTime.parse(pkg['updated_at'] as String),
      'uploaders': uploaders.map((u) => u['email']).toList(),
      'versions': versions.map((v) {
        var item = <String, dynamic>{
          'version': v['version'],
          'pubspecYaml': v['pubspec_yaml'],
          'pubspec': json.decode(v['pubspec'] as String),
          'uploader': v['uploader'],
          'createdAt': DateTime.parse(v['created_at'] as String),
        };
        // Only include optional fields if present (matching old MongoDB behavior)
        if (v['readme'] != null) item['readme'] = v['readme'];
        if (v['changelog'] != null) item['changelog'] = v['changelog'];
        return item;
      }).toList(),
    };
  }

  Map<String, String> _pubspecCache = {};

  Future<String?> _readFile(
      String package, String version, String filename) async {
    var key = package + version + filename;
    if (_pubspecCache[key] == null) {
      var filePath = path.absolute('test/fixtures', package, version, filename);
      _pubspecCache[key] = await File(filePath).readAsString();
    }
    return _pubspecCache[key];
  }

  group('publish', () {
    setUpAll(() async {
      var result = await createServer(email0);
      _server = result.$1;
      _store = result.$2;
    });

    tearDownAll(() async {
      await _server.close();
      await _store.db.close();
    });

    test('fresh', () async {
      var version = '0.0.1';

      var result = await pubPublish(package0, version);
      expect(result.stderr, '');

      var meta = await _readMeta(package0);

      expect(meta['name'], package0);
      expect(meta['uploaders'], [email0]);
      expect(meta['private'], true);
      expect(meta['createdAt'], isA<DateTime>());
      expect(meta['updatedAt'], isA<DateTime>());
      expect(meta['versions'], isList);
      expect(meta['versions'], hasLength(1));

      var item = meta['versions'][0];
      expect(item['createdAt'], isA<DateTime>());
      item.remove('createdAt');
      expect(
        DeepCollectionEquality().equals(item, {
          'version': version,
          'pubspecYaml': await _readFile(package0, version, 'pubspec.yaml'),
          'pubspec':
              loadYamlAsMap(await _readFile(package0, version, 'pubspec.yaml')),
          'readme': await _readFile(package0, version, 'README.md'),
          'changelog': await _readFile(package0, version, 'CHANGELOG.md'),
          'uploader': email0,
        }),
        true,
      );
    });

    test('existing package', () async {
      var version = '0.0.3';

      var result = await pubPublish(package0, version);
      expect(result.stderr, '');

      var meta = await _readMeta(package0);

      expect(meta['name'], package0);
      expect(meta['uploaders'], [email0]);
      expect(meta['versions'], isList);
      expect(meta['versions'], hasLength(2));
      expect(meta['versions'][0]['version'], '0.0.1');
      expect(meta['versions'][1]['version'], version);
    });

    test('duplicated version', () async {
      var result = await pubPublish(package0, '0.0.3');
      expect(result.stderr, contains('version invalid'));
    });

    test('no readme and changelog', () async {
      var version = '1.0.0-noreadme';
      var result = await pubPublish(package0, version);
      // expect(result.stderr, ''); // Suggestions:

      var meta = await _readMeta(package0);

      expect(meta['name'], package0);
      expect(meta['uploaders'], [email0]);
      expect(meta['versions'], isList);
      expect(meta['versions'], hasLength(3));
      expect(meta['versions'][0]['version'], '0.0.1');
      expect(meta['versions'][1]['version'], '0.0.3');

      var item = meta['versions'][2];
      expect(item['createdAt'], isA<DateTime>());
      item.remove('createdAt');
      expect(
        DeepCollectionEquality().equals(item, {
          'version': version,
          'pubspecYaml': await _readFile(package0, version, 'pubspec.yaml'),
          'pubspec':
              loadYamlAsMap(await _readFile(package0, version, 'pubspec.yaml')),
          'uploader': email0,
        }),
        true,
      );
    });
  });

  group('get versions', () {
    setUpAll(() async {
      var result = await createServer(email0);
      _server = result.$1;
      _store = result.$2;
      await pubPublish(package0, '0.0.1');
      await pubPublish(package0, '0.0.2');
    });

    tearDownAll(() async {
      await _server.close();
      await _store.db.close();
    });

    test('existing at local', () async {
      var res = await getVersions(package0);
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      expect(
        DeepCollectionEquality().equals(body, {
          "name": "package_0",
          "latest": {
            "archive_url":
                "$pubHostedUrl/packages/package_0/versions/0.0.2.tar.gz",
            "pubspec": loadYamlAsMap(
                await _readFile('package_0', '0.0.2', 'pubspec.yaml')),
            "version": "0.0.2"
          },
          "versions": [
            {
              "archive_url":
                  "$pubHostedUrl/packages/package_0/versions/0.0.1.tar.gz",
              "pubspec": loadYamlAsMap(
                  await _readFile('package_0', '0.0.1', 'pubspec.yaml')),
              "version": "0.0.1"
            },
            {
              "archive_url":
                  "$pubHostedUrl/packages/package_0/versions/0.0.2.tar.gz",
              "pubspec": loadYamlAsMap(
                  await _readFile('package_0', '0.0.2', 'pubspec.yaml')),
              "version": "0.0.2"
            }
          ]
        }),
        true,
      );
    });

    test('existing at remote', () async {
      var name = 'http';
      var res = await getVersions(name);
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      expect(body['name'], name);
    });

    test('not existing', () async {
      var res = await getVersions(notExistingPacakge);
      expect(res.statusCode, HttpStatus.notFound);
    });
  });

  group('get specific version', () {
    setUpAll(() async {
      var result = await createServer(email0);
      _server = result.$1;
      _store = result.$2;
      await pubPublish(package0, '0.0.1');
      await pubPublish(package0, '0.0.3+1');
    });

    tearDownAll(() async {
      await _server.close();
      await _store.db.close();
    });

    test('existing at local', () async {
      var res = await getSpecificVersion(package0, '0.0.1');
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      expect(
        DeepCollectionEquality().equals(body, {
          "archive_url":
              "$pubHostedUrl/packages/package_0/versions/0.0.1.tar.gz",
          "pubspec": loadYamlAsMap(
              await _readFile('package_0', '0.0.1', 'pubspec.yaml')),
          "version": '0.0.1'
        }),
        true,
      );
    });

    test('decode version correctly', () async {
      var res = await getSpecificVersion(package0, '0.0.3+1');
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      expect(
        DeepCollectionEquality().equals(body, {
          "archive_url":
              "$pubHostedUrl/packages/package_0/versions/0.0.3+1.tar.gz",
          "pubspec": loadYamlAsMap(
              await _readFile('package_0', '0.0.3+1', 'pubspec.yaml')),
          "version": '0.0.3+1'
        }),
        true,
      );
    });

    test('not existing version at local', () async {
      var res = await getSpecificVersion(package0, '0.0.2');
      expect(res.statusCode, HttpStatus.notFound);
    });

    test('existing at remote', () async {
      var res = await getSpecificVersion('http', '0.12.0+2');
      expect(res.statusCode, HttpStatus.ok);

      var body = json.decode(res.body);
      expect(body['version'], '0.12.0+2');
    });

    test('not existing', () async {
      var res = await getSpecificVersion(notExistingPacakge, '0.0.1');
      expect(res.statusCode, HttpStatus.notFound);
    });
  });

  group('uploader', () {
    setUpAll(() async {
      var result = await createServer(email0);
      _server = result.$1;
      _store = result.$2;
      await pubPublish(package0, '0.0.1');
    });

    tearDownAll(() async {
      await _server.close();
      await _store.db.close();
    });

    group('add', () {
      test('already exists', () async {
        var res = await addUploaderHttp(package0, email0);
        expect(res.statusCode, HttpStatus.badRequest);
        expect(res.body, contains('email already exists'));

        var meta = await _readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0]));
      });

      test('success', () async {
        var res = await addUploaderHttp(package0, email1);
        expect(res.statusCode, HttpStatus.ok);

        var meta = await _readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0, email1]));

        res = await addUploaderHttp(package0, email2);
        expect(res.statusCode, HttpStatus.ok);

        meta = await _readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0, email1, email2]));
      });
    });

    group('remove', () {
      test('not in uploader', () async {
        // First add email1, email2
        await _store.addUploader(package0, email1);
        await _store.addUploader(package0, email2);

        var res = await removeUploaderHttp(package0, email3);
        expect(res.statusCode, HttpStatus.badRequest);
        expect(res.body, contains('email not uploader'));

        var meta = await _readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0, email1, email2]));
      });

      test('success', () async {
        var res = await removeUploaderHttp(package0, email2);
        expect(res.statusCode, HttpStatus.ok);

        var meta = await _readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0, email1]));

        res = await removeUploaderHttp(package0, email1);
        expect(res.statusCode, HttpStatus.ok);

        meta = await _readMeta(package0);
        expect(meta['uploaders'], unorderedEquals([email0]));
      });
    });

    group('permission', () {
      setUpAll(() async {
        await _server.close();
        await _store.db.close();
        var result = await createServer(email1);
        _server = result.$1;
        _store = result.$2;
        // Manually insert the package with email0 as uploader
        // (so email1 operator is NOT an uploader → permission denied)
        await _store.addVersion(
          package0,
          UnpubVersion(
            '0.0.1',
            {'name': package0, 'version': '0.0.1'},
            null,
            email0,
            null,
            null,
            DateTime.now(),
          ),
        );
      });

      tearDownAll(() async {
        await _server.close();
        await _store.db.close();
      });

      test('add', () async {
        var res = await addUploaderHttp(package0, email0);
        expect(res.statusCode, HttpStatus.forbidden);
      });

      test('remove', () async {
        var res = await removeUploaderHttp(package0, email0);
        expect(res.statusCode, HttpStatus.forbidden);
      });
    });
  });

  group('badge', () {
    setUpAll(() async {
      var result = await createServer(email0);
      _server = result.$1;
      _store = result.$2;
      await pubPublish(package0, '0.0.1');
    });

    tearDownAll(() async {
      await _server.close();
      await _store.db.close();
    });

    group('v', () {
      test('<1.0.0', () async {
        var res = await http.Client().send(
            http.Request('GET', baseUri.resolve('/badge/v/$package0'))
              ..followRedirects = false);
        expect(res.statusCode, HttpStatus.found);
        expect(res.headers[HttpHeaders.locationHeader],
            'https://img.shields.io/static/v1?label=unpub&message=0.0.1&color=orange');
      });

      test('>=1.0.0', () async {
        await pubPublish(package0, '1.0.0');

        var res = await http.Client().send(
            http.Request('GET', baseUri.resolve('/badge/v/$package0'))
              ..followRedirects = false);
        expect(res.statusCode, HttpStatus.found);
        expect(res.headers[HttpHeaders.locationHeader],
            'https://img.shields.io/static/v1?label=unpub&message=1.0.0&color=blue');
      });

      test('package not exists', () async {
        var res =
            await http.get(baseUri.resolve('/badge/v/$notExistingPacakge'));
        expect(res.statusCode, HttpStatus.notFound);
      });
    });

    group('d', () {
      test('correct download count', () async {
        var res = await http.Client().send(
            http.Request('GET', baseUri.resolve('/badge/d/$package0'))
              ..followRedirects = false);
        expect(res.statusCode, HttpStatus.found);
        expect(res.headers[HttpHeaders.locationHeader],
            'https://img.shields.io/static/v1?label=downloads&message=0&color=blue');
      });

      test('package not exists', () async {
        var res =
            await http.get(baseUri.resolve('/badge/d/$notExistingPacakge'));
        expect(res.statusCode, HttpStatus.notFound);
      });
    });
  });
}

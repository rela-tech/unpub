import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:http/http.dart' as http;
import 'package:unpub/unpub.dart' as unpub;

final notExistingPacakge = 'not_existing_package';
final baseDir = path.absolute('unpub-packages');
final pubHostedUrl = 'http://localhost:4000';
final baseUri = Uri.parse(pubHostedUrl);

final package0 = 'package_0';
final package1 = 'package_1';
final email0 = 'email0@example.com';
final email1 = 'email1@example.com';
final email2 = 'email2@example.com';
final email3 = 'email3@example.com';

Future<(HttpServer, unpub.SqliteStore)> createServer(String opEmail) async {
  var sqliteStore = await unpub.SqliteStore.open(':memory:');

  var app = unpub.App(
    metaStore: sqliteStore,
    packageStore: unpub.FileStore(baseDir),
    overrideUploaderEmail: opEmail,
  );

  var server = await app.serve('0.0.0.0', 4000);
  return (server, sqliteStore);
}

/// Create a server with upload token authentication.
Future<(HttpServer, unpub.SqliteStore)> createServerWithToken(
    String opEmail, String token) async {
  var sqliteStore = await unpub.SqliteStore.open(':memory:');

  var app = unpub.App(
    metaStore: sqliteStore,
    packageStore: unpub.FileStore(baseDir),
    overrideUploaderEmail: opEmail,
    uploadToken: token,
  );

  var server = await app.serve('0.0.0.0', 4000);
  return (server, sqliteStore);
}

Future<http.Response> getVersions(String package) {
  package = Uri.encodeComponent(package);
  return http.get(baseUri.resolve('/api/packages/$package'));
}

Future<http.Response> getSpecificVersion(String package, String version) {
  package = Uri.encodeComponent(package);
  version = Uri.encodeComponent(version);
  return http.get(baseUri.resolve('/api/packages/$package/versions/$version'));
}

Future<ProcessResult> pubPublish(String name, String version) {
  return Process.run('dart', ['pub', 'publish', '--force'],
      workingDirectory: path.absolute('test/fixtures', name, version),
      environment: {'PUB_HOSTED_URL': pubHostedUrl});
}

/// Add an uploader via the HTTP API directly.
Future<http.Response> addUploaderHttp(String name, String email,
    {String? token}) {
  final headers = <String, String>{};
  if (token != null) headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
  return http.post(
    baseUri.resolve('/api/packages/$name/uploaders'),
    body: 'email=$email',
    headers: headers,
  );
}

/// Remove an uploader via the HTTP API directly.
Future<http.Response> removeUploaderHttp(String name, String email,
    {String? token}) {
  final headers = <String, String>{};
  if (token != null) headers[HttpHeaders.authorizationHeader] = 'Bearer $token';
  return http.delete(
    baseUri.resolve(
        '/api/packages/$name/uploaders/${Uri.encodeComponent(email)}'),
    headers: headers,
  );
}

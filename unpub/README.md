# Unpub

[![pub](https://img.shields.io/pub/v/unpub.svg)](https://pub.dev/packages/unpub)

Unpub is a self-hosted private Dart Pub server for Enterprise, with a simple web interface to search and view packages information.

## Screenshots

![Screenshot](https://raw.githubusercontent.com/bytedance/unpub/master/assets/screenshot.png)

## Quick Start

### Prerequisites

- Dart SDK >= 3.0.0

### Installation

```sh
dart pub global activate unpub
```

### Run

Unpub now uses **SQLite** as the default metadata store — no external database required.

```sh
# Start with SQLite (default)
unpub
```

That's it! Unpub will create an `unpub.db` SQLite database and an `unpub-packages` directory for package tarballs.

### Options

```
--host, -h               Listen address (default: 0.0.0.0)
--port, -p               Listen port (default: 4000)
--database-type, -t      Database type: sqlite (default) or mongo
--database, -d           SQLite file path or MongoDB connection URI
                         (default: unpub.db)
--uploader-email, -u     Uploader email (skips Google OAuth)
--upload-token, -k       Token required for publish/uploader operations
                         Clients must send `Authorization: Bearer <token>`
--proxy-origin, -o       Reverse proxy origin URL
```

**Examples:**

```sh
# Start with defaults (SQLite on port 4000)
unpub

# Custom SQLite path and port
unpub --database /data/unpub.db --port 8080

# With uploader email and token (recommended for public deployment)
unpub --uploader-email "you@example.com" --upload-token "secret123"

# Use MongoDB instead (backward compatible)
unpub --database-type mongo --database mongodb://localhost:27017/dart_pub

# Behind a reverse proxy
unpub --proxy-origin https://pub.example.com
```

### Authentication

For public deployments, configure an upload token to protect write operations:

```sh
# Server side
unpub --uploader-email "you@example.com" --upload-token "supersecret"
```

On each client that needs to publish:

```sh
# Client side — store the token (publish will use it automatically)
dart pub token add http://your-unpub-host:4000
# Paste: supersecret

# Then publish as usual
dart pub publish
```

How it works:
- Read operations (dependency resolution, downloads) — **no token required**
- Write operations (publish, add/remove uploader) — `Authorization: Bearer <token>` required
- `dart pub token add` configures the Dart client to auto-send this header
- With `--upload-token` set, Google OAuth is fully bypassed

### Without token (local development)

```sh
unpub --uploader-email "dev@localhost"
```

No token required — all writes are accepted from any client. Use only in trusted environments.

## Database

### SQLite (Default)

No external database required. Unpub creates a single-file SQLite database.

```sh
unpub --database unpub.db
```

### MongoDB (Legacy)

Still supported via `--database-type mongo`:

```sh
unpub --database-type mongo --database mongodb://localhost:27017/dart_pub
```

### Migrating from MongoDB to SQLite

If you have an existing MongoDB deployment and want to switch to SQLite:

```sh
# Run the migration tool
dart run tool/migrate.dart \
  --mongo mongodb://localhost:27017/dart_pub \
  --sqlite unpub.db

# Then start unpub with the migrated database
unpub --database unpub.db
```

The migration tool reads all packages, versions, uploaders and download counts from MongoDB and writes them to a new SQLite database. The original MongoDB data is **not** modified.

You can also run it from source:

```sh
cd unpub
dart pub get
dart run tool/migrate.dart --mongo mongodb://localhost:27017/dart_pub --sqlite /path/to/unpub.db
```

#### Production-safe migration (no port exposure)

To avoid exposing your production MongoDB port, use `mongodump`/`mongorestore`:

1. On your production server, dump MongoDB data **inside the container**:
   ```sh
   docker exec unpub-mongo mongodump --db dart_pub --out /dump
   docker cp unpub-mongo:/dump ./mongo-dump
   tar -czf mongo-dump.tar.gz mongo-dump
   ```

2. On your local machine, restore into a temporary MongoDB container:
   ```sh
   docker run -d -p 27017:27017 --name temp-mongo mongo:6.0 mongod --bind_ip_all
   docker cp ./mongo-dump temp-mongo:/dump
   docker exec temp-mongo mongorestore /dump
   ```

3. Run the migration tool against the local temp MongoDB:
   ```sh
   dart run tool/migrate.dart --mongo mongodb://localhost:27017/dart_pub --sqlite unpub.db
   ```

4. Build and deploy your new SQLite-based Docker image (see below).

## Deployment

### Docker Compose

A ready-to-use `docker-compose.yml` is provided in the root of this repo:

```yaml
version: '3.8'

services:
  unpub:
    image: unpub:latest
    restart: unless-stopped
    ports:
      - "4000:4000"
    volumes:
      - ./unpub.db:/data/unpub.db
      - ./unpub-packages:/data/unpub-packages
    environment:
      - PUB_HOSTED_URL=http://unpub:4000
    command: >
      --database /data/unpub.db
      --uploader-email admin@company.com
      --upload-token prod-secret
      --host 0.0.0.0
      --port 4000
```

Then run:

```sh
docker compose up -d
```

Your unpub instance will be available at `http://localhost:4000`.

For production, add nginx reverse proxy (HTTPS, rate limiting) — see `nginx.conf.example`.

## Configuring Dart Pub Client

Set the `PUB_HOSTED_URL` environment variable in your shell profile (`.bashrc`, `.zshrc`, or `config.fish`):

```sh
export PUB_HOSTED_URL=http://localhost:4000
```

Then use `dart pub publish` as usual:

```sh
cd my_package
dart pub publish
```

## Dart API

```dart
import 'package:unpub/unpub.dart' as unpub;

Future<void> main(List<String> args) async {
  // Use SQLite
  final metaStore = await unpub.SqliteStore.open('unpub.db');

  // Or use MongoDB
  // final db = Db('mongodb://localhost:27017/dart_pub');
  // await db.open();
  // final metaStore = unpub.MongoStore(db);

  final app = unpub.App(
    metaStore: metaStore,
    packageStore: unpub.FileStore('./unpub-packages'),
  );

  final server = await app.serve('0.0.0.0', 4000);
  print('Serving at http://${server.address.host}:${server.port}');
}
```

### Options

| Option | Description | Default |
| --- | --- | --- |
| `metaStore` (Required) | Meta information store | - |
| `packageStore` (Required) | Package(tarball) store | - |
| `upstream` | Upstream url | https://pub.dev |
| `googleapisProxy` | Http(s) proxy to call googleapis (to get uploader email) | - |
| `uploadValidator` | See [Package validator](#package-validator) | - |

### Usage behind reverse-proxy

Using unpub behind reverse proxy(nginx or another), ensure you have necessary headers
```sh
proxy_set_header X-Forwarded-Host $host;
proxy_set_header X-Forwarded-Server $host;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;

# Workaround for: 
# Asynchronous error HttpException: 
# Trying to set 'Transfer-Encoding: Chunked' on HTTP 1.0 headers
proxy_http_version 1.1;
```

### Package validator

Naming conflicts is a common issue for private registry. A reasonable solution is to add prefix to reduce conflict probability.

With `uploadValidator` you could check if uploaded package is valid.

```dart
var app = unpub.App(
  // ...
  uploadValidator: (Map<String, dynamic> pubspec, String uploaderEmail) {
    // Only allow packages with some specified prefixes to be uploaded
    var prefix = 'my_awesome_prefix_';
    var name = pubspec['name'] as String;
    if (!name.startsWith(prefix)) {
      throw 'Package name should starts with $prefix';
    }

    // Also, you can check if uploader email is valid
    if (!uploaderEmail.endsWith('@your-company.com')) {
      throw 'Uploader email invalid';
    }
  }
);
```

### Customize meta and package store

Unpub is designed to be extensible. It is quite easy to customize your own meta store and package store.

```dart
import 'package:unpub/unpub.dart' as unpub;

class MyAwesomeMetaStore extends unpub.MetaStore {
  // Implement methods of MetaStore abstract class
  // ...
}

class MyAwesomePackageStore extends unpub.PackageStore {
  // Implement methods of PackageStore abstract class
  // ...
}

// Then use it
var app = unpub.App(
  metaStore: MyAwesomeMetaStore(),
  packageStore: MyAwesomePackageStore(),
);
```

#### Available Package Stores

1. [unpub_aws](https://github.com/bytedance/unpub/tree/master/unpub_aws): AWS S3 package store, maintained by [@CleanCode](https://github.com/Clean-Cole).

## Badges

| URL | Badge |
| --- | --- |
| `/badge/v/{package_name}` | ![badge example](https://img.shields.io/static/v1?label=unpub&message=0.1.0&color=orange) ![badge example](https://img.shields.io/static/v1?label=unpub&message=1.0.0&color=blue) |
| `/badge/d/{package_name}` | ![badge example](https://img.shields.io/static/v1?label=downloads&message=123&color=blue) |

## Development

```sh
# Run tests (no external dependencies required)
cd unpub
dart pub get
dart test

# Start locally for manual testing
dart run bin/unpub.dart

# In another terminal, set PUB_HOSTED_URL and publish a test package
export PUB_HOSTED_URL=http://localhost:4000
cd test/fixtures/package_0/0.0.1
dart pub publish
```

## Alternatives

- [pub-dev](https://github.com/dart-lang/pub-dev): Source code of [pub.dev](https://pub.dev), which should be deployed at Google Cloud Platform.
- [pub_server](https://github.com/dart-lang/pub_server): An alpha version of pub server provided by Dart team.

## Credits

- [pub-dev](https://github.com/dart-lang/pub-dev): Web page styles are mostly imported from https://pub.dev directly.
- [shields](https://shields.io): Badges generation.

## License

MIT

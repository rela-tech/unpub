# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

Unpub is a self-hosted private Dart Pub registry. It serves Dart package metadata and tarballs via shelf HTTP server, with upstream proxy to pub.dev for packages not hosted locally.

The checkout is a multi-package repo:

| Directory | Purpose |
|---|---|
| `unpub/` | Core server — the main package |
| `unpub_web/` | Web UI (Dart web frontend) |
| `unpub_auth/` | CLI helper for Google OAuth credential setup |
| `unpub_aws/` | AWS S3 package store (community maintained) |

## Commands

```sh
cd unpub

dart pub get                     # install dependencies
dart test                        # run all tests
dart test -N "uploader add"      # run tests matching pattern
dart analyze                     # static analysis

# Code generation (after modifying route annotations or model JSON)
dart run build_runner build

# Run locally
dart run bin/unpub.dart -u "your@email.com"

# AOT compile for deployment
dart compile exe bin/unpub.dart -o unpub
```

Tests use in-memory SQLite — no external database needed (`dart test` works out of the box).

## Architecture

```
bin/unpub.dart              CLI entry point, parses flags, wires App
lib/
  unpub.dart                Public API exports
  src/
    app.dart                HTTP router & request handling (shelf_router)
    app.g.dart              Generated route dispatcher
    meta_store.dart         Abstract interface for metadata storage
    mongo_store.dart        MongoDB implementation of MetaStore
    sqlite_store.dart       SQLite implementation of MetaStore
    package_store.dart      Abstract interface for tarball storage
    file_store.dart         Filesystem implementation of PackageStore
    models.dart / models.g.dart  Data types (UnpubPackage, UnpubVersion, etc.)
    utils.dart              YAML parsing helpers
test/
    unpub_test.dart         HTTP-level integration tests (start server, publish via dart pub)
    sqlite_store_test.dart  Unit tests for SqliteStore
    file_store_test.dart    Unit tests for FileStore
    utils.dart              Test helpers (createServer, pubPublish, etc.)
    fixtures/               Test packages at specific versions for publish testing
```

### Key design: pluggable storage

`App` accepts `MetaStore` and `PackageStore` via its constructor — the HTTP layer has zero knowledge of database specifics.

- **`MetaStore`**: 6 abstract methods for package metadata — `queryPackage`, `addVersion`, `addUploader`, `removeUploader`, `increaseDownloads`, `queryPackages`
- **`SqliteStore`** (default): 4-table normalized schema (`packages`, `versions`, `uploaders`, `stats`), WAL mode, writes use transactions
- **`MongoStore`**: original implementation, preserved for backward compatibility

The `--database-type` CLI flag switches between them; `:memory:` SQLite is used in tests.

### Request flow (publish)

1. `dart pub publish` → `GET .../versions/new` → `POST .../newUpload` (multipart tarball)
2. `upload()` parses tarball, extracts `pubspec.yaml`, README, CHANGELOG
3. Calls `uploadValidator` (if configured) then `_getUploaderEmail()` (Google OAuth or `--uploader-email` override)
4. Writes tarball via `PackageStore.upload()`, writes metadata via `MetaStore.addVersion()`

### Upstream proxy

`GET /api/packages/<name>` and `/packages/<name>/versions/<v>.tar.gz` return `302 Found` to `https://pub.dev` when a package is not found locally. This is transparent to `dart pub` — clients see it as if unpub hosts everything.

### Routes (auto-generated via shelf_router_generator)

Route annotations on `App` methods produce `app.g.dart`. Running `dart run build_runner build` regenerates it. When adding routes, annotate with `@Route.<method>('/path')` and rebuild.

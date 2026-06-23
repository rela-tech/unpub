import 'package:unpub/unpub.dart' as unpub;

main(List<String> args) async {
  final metaStore = await unpub.SqliteStore.open('unpub.db');

  final app = unpub.App(
    metaStore: metaStore,
    packageStore: unpub.FileStore('./unpub-packages'),
  );

  final server = await app.serve('0.0.0.0', 4000);
  print('Serving at http://${server.address.host}:${server.port}');
}

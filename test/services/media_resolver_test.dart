import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:frappe_mobile_sdk/src/database/daos/media_cache_dao.dart';
import 'package:frappe_mobile_sdk/src/database/schema/system_tables.dart';
import 'package:frappe_mobile_sdk/src/models/media_cache_entry.dart';
import 'package:frappe_mobile_sdk/src/services/media_resolver.dart';
import 'package:frappe_mobile_sdk/src/utils/media_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  late Database db;
  late MediaCacheDao cache;
  late Directory root;
  var fetches = 0;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    for (final s in systemTablesDDL()) {
      await db.execute(s);
    }
    cache = MediaCacheDao(db);
    root = await Directory.systemTemp.createTemp('resolver');
    MediaStore.overrideRootForTest(root.path);
    fetches = 0;
  });

  tearDown(() async {
    MediaStore.overrideRootForTest(null);
    await db.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  MediaResolver resolver({bool online = true, List<int>? bytes}) =>
      MediaResolver(
        cache: cache,
        isOnline: () => online,
        fetch: (url) async {
          fetches++;
          return bytes;
        },
      );

  test('a pending marker resolves to its staged path', () async {
    final r = await resolver().resolve(
      'pending:7',
      pendingPaths: {7: '/outbox/x.jpg'},
    );
    expect(r, '/outbox/x.jpg');
    expect(fetches, 0, reason: 'a staged file is never fetched over HTTP');
  });

  test('an unknown marker resolves to null without fetching', () async {
    // The id must never be treated as a url — fetching "pending:99" would be
    // a guaranteed 404 and, worse, leak the marker into a network call.
    expect(await resolver().resolve('pending:99', pendingPaths: {}), isNull);
    expect(fetches, 0);
  });

  test('a malformed marker is not fetched either', () async {
    expect(await resolver().resolve('pending:abc'), isNull);
    expect(fetches, 0);
  });

  test('a cache hit returns the local path without fetching', () async {
    final f = File('${root.path}/hit.jpg')..writeAsStringSync('H');
    await cache.upsert(
      fileUrl: '/files/hit.jpg',
      localPath: f.path,
      source: MediaSource.downloaded,
    );
    expect(await resolver().resolve('/files/hit.jpg'), f.path);
    expect(fetches, 0);
  });

  test('a cache hit records the access for Phase 2 eviction', () async {
    final f = File('${root.path}/hit.jpg')..writeAsStringSync('H');
    await cache.upsert(
      fileUrl: '/files/hit.jpg',
      localPath: f.path,
      source: MediaSource.downloaded,
    );
    final before =
        (await db.query('media_cache')).single['last_accessed_at'] as int;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await resolver().resolve('/files/hit.jpg');
    final after =
        (await db.query('media_cache')).single['last_accessed_at'] as int;
    expect(after >= before, isTrue);
  });

  test('a miss while online fetches, stores, and returns the path', () async {
    final path = await resolver(bytes: [1, 2, 3]).resolve('/files/new.jpg');
    expect(fetches, 1);
    expect(path, isNotNull);
    expect(File(path!).readAsBytesSync(), [1, 2, 3]);

    final entry = await cache.findByUrl('/files/new.jpg');
    expect(entry, isNotNull);
    expect(entry!.source, MediaSource.downloaded);
    expect(entry.sizeBytes, 3);
  });

  test('a second view of a downloaded file is a cache hit', () async {
    final r = resolver(bytes: [1, 2, 3]);
    await r.resolve('/files/new.jpg');
    await r.resolve('/files/new.jpg');
    expect(fetches, 1, reason: 'lazy cache: fetch once, serve forever');
  });

  test('a miss while offline returns null without fetching', () async {
    expect(await resolver(online: false).resolve('/files/nope.jpg'), isNull);
    expect(fetches, 0);
  });

  test('a row whose file vanished is a MISS, not an error', () async {
    await cache.upsert(
      fileUrl: '/files/gone.jpg',
      localPath: '${root.path}/gone.jpg',
      source: MediaSource.downloaded,
    );
    final path = await resolver(bytes: [9]).resolve('/files/gone.jpg');
    expect(fetches, 1, reason: 'self-healing: re-fetch rather than fail');
    expect(File(path!).readAsBytesSync(), [9]);
  });

  test('a failed fetch returns null instead of throwing', () async {
    expect(await resolver(bytes: null).resolve('/files/bad.jpg'), isNull);
  });

  test('a throwing fetch returns null instead of propagating', () async {
    final r = MediaResolver(
      cache: cache,
      isOnline: () => true,
      fetch: (_) async => throw Exception('boom'),
    );
    // A media fetch must never break form rendering.
    expect(await r.resolve('/files/x.jpg'), isNull);
  });

  test('an empty value resolves to null', () async {
    expect(await resolver().resolve('   '), isNull);
    expect(fetches, 0);
  });

  test('a raw LOCAL path is returned directly, never fetched', () async {
    // Between pick and save the field holds a staged path, not a marker and
    // not a server url. Fetching it would prepend the base url and issue a
    // guaranteed 404 — and in offline mode that is precisely the network call
    // the mode exists to avoid.
    final f = File('${root.path}/staged.jpg')..writeAsStringSync('S');
    expect(await resolver().resolve(f.path), f.path);
    expect(fetches, 0);
  });

  test(
    'a local path whose file is gone resolves to null, still no fetch',
    () async {
      expect(await resolver().resolve('${root.path}/missing.jpg'), isNull);
      expect(fetches, 0);
    },
  );

  test('a cache path is also local and is returned as-is', () async {
    final cached = File('${root.path}/deadbeef.jpg')..writeAsStringSync('C');
    expect(await resolver().resolve(cached.path), cached.path);
    expect(fetches, 0);
  });

  test(
    'a server url is still fetched (the local check must not over-match)',
    () async {
      final p = await resolver(bytes: [1]).resolve('/files/real.jpg');
      expect(fetches, 1);
      expect(p, isNotNull);
    },
  );
}

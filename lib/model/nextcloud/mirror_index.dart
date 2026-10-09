import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/mirror_store.dart';

// Row storage behind `NextcloudMirrorStore` (layer L3).
//
// Split out of the store so that the accounting and eviction policy can be exercised without a
// platform database: `NextcloudMirrorStoreImpl` holds the policy, an implementation of this holds
// the rows. Implementations deal with rows only; they never touch the filesystem.
//
// `relativePath` is normalized by `NextcloudPaths` and unique per account.
abstract class NextcloudMirrorIndex {
  Future<void> init();

  Future<NextcloudMirrorIndexEntry?> get(NextcloudAccount account, String relativePath);

  Future<Set<NextcloudMirrorIndexEntry>> getAll(NextcloudAccount account);

  // Least-recently-accessed first, at most `limit` rows. Eviction pages through this instead of
  // loading the whole account: a large library can hold a six-figure number of rows.
  //
  // Pinned rows are excluded, because they can never be evicted: handing them back would give the store a
  // page of candidates that cannot go, which it reads as "the account has nothing left to evict".
  Future<List<NextcloudMirrorIndexEntry>> getLeastRecentlyAccessed(NextcloudAccount account, {required int limit});

  // Inserts or replaces the row for `entry.relativePath`.
  Future<void> put(NextcloudAccount account, NextcloudMirrorIndexEntry entry);

  // Deletes the row; a no-op for unknown paths.
  Future<void> delete(NextcloudAccount account, String relativePath);

  Future<void> deleteAll(NextcloudAccount account);

  // Sum of `localSizeBytes` over the account's rows: bytes on disk, never remote sizes. Named for the
  // column it sums, because summing `remoteSizeBytes` instead would report a mirror of preview rows as
  // the size of the whole remote library and evict everything forever.
  Future<int> sumLocalSizeBytes(NextcloudAccount account);
}

import 'package:aves/model/entry/extensions/props.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/model/nextcloud/account.dart';
import 'package:aves/model/nextcloud/placeholder_entries.dart';
import 'package:aves/model/nextcloud/remote_item.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const builder = NextcloudPlaceholderEntriesImpl();

  final account = NextcloudAccount(
    id: 'nc_1',
    serverUrl: Uri.parse('https://cloud.example.com'),
    username: 'alice',
    rootFolder: 'Photos',
    cacheLimitBytes: NextcloudAccount.defaultCacheLimitBytes,
  );

  final modified = DateTime.utc(2026, 3, 4, 5, 6, 7);
  final taken = DateTime.utc(2019, 8, 9, 10, 11, 12);

  NextcloudRemoteItem itemFor({
    String relativePath = 'Trips/clip.mp4',
    String? mimeType = 'video/mp4',
    int sizeBytes = 900 * 1024 * 1024,
    bool isCollection = false,
    NextcloudPhotoMetadata? photoMetadata,
  }) => NextcloudRemoteItem(
    relativePath: relativePath,
    fileId: 42,
    etag: 'v1',
    mimeType: mimeType,
    sizeBytes: sizeBytes,
    lastModified: modified,
    isCollection: isCollection,
    photoMetadata: photoMetadata,
  );

  group('what the properties can say', () {
    test('a video the mirror holds no bytes for becomes a video entry of the original size', () {
      final entry = builder.build(account, itemFor())!;

      expect(entry.sourceMimeType, 'video/mp4');
      expect(entry.isVideo, isTrue);
      expect(entry.sizeBytes, 900 * 1024 * 1024, reason: 'the original on the server; nothing is held locally');
      expect(entry.origin, EntryOrigins.nextcloud);
      expect(entry.dateModifiedMillis, modified.millisecondsSinceEpoch, reason: "the server's file date, not when it was seen");
    });

    test('an image the server cannot derive a preview for takes the same path', () {
      // HEIC and HEIF answer 404 under the default preview providers, so a placeholder is not a video-only
      // outcome and nothing here may assume a mime class
      final entry = builder.build(account, itemFor(relativePath: 'Phone/IMG_1.heic', mimeType: 'image/heic', sizeBytes: 3 * 1024 * 1024))!;

      expect(entry.isVideo, isFalse);
      expect(entry.sourceMimeType, 'image/heic');
      expect(entry.sizeBytes, 3 * 1024 * 1024);
    });

    test('the capture date and the dimensions come from the server metadata when it has them', () {
      final entry = builder.build(
        account,
        itemFor(photoMetadata: NextcloudPhotoMetadata(width: 1920, height: 1080, originalDateTime: taken)),
      )!;

      expect(entry.sourceDateTakenMillis, taken.millisecondsSinceEpoch);
      expect(entry.width, 1920);
      expect(entry.height, 1080);
      expect(entry.displayAspectRatio, closeTo(16 / 9, 0.001));
    });
  });

  group('what it must not invent', () {
    test('an unknown capture date stays unknown rather than becoming 1970', () {
      final entry = builder.build(account, itemFor())!;

      // the condition, not the number: a 0 reads back as 1970 and sorts the item to the start of the
      // library, which looks like data loss rather than a missing property
      expect(entry.sourceDateTakenMillis, isNull);
      expect(entry.catalogDateMillis, isNull);
      expect(entry.bestDate, DateTime.fromMillisecondsSinceEpoch(modified.millisecondsSinceEpoch), reason: 'it falls back to the file date, not to the epoch');
    });

    test('unknown dimensions are square rather than a division by zero', () {
      final entry = builder.build(account, itemFor())!;

      expect(entry.width, 0);
      expect(entry.height, 0);
      expect(entry.displayAspectRatio, 1);
    });

    test('an unknown duration shows no duration at all, not a zero one', () {
      expect(builder.build(account, itemFor())!.durationMillis, isNull);
    });

    test('the rotation is not guessed: it lives in the bytes and the device poster corrects it later', () {
      expect(builder.build(account, itemFor())!.sourceRotationDegrees, 0);
    });

    test('the builder does not choose a location, so an entry that escaped the override is obviously broken', () {
      final entry = builder.build(account, itemFor())!;

      // the sink is the single authority on where the entry claims to live: a plausible-looking path here
      // would be keyed under the mirror URI and stored under its own, which is the duplicate entry
      // `putPlaceholder`'s comment exists to prevent
      expect(entry.uri, isEmpty);
      expect(entry.path, isNull);
    });
  });

  group('refusals, which are outcomes and not failures', () {
    test('a collection is not an entry', () {
      expect(builder.build(account, itemFor(mimeType: null, isCollection: true)), isNull);
    });

    test('an item with no content type is refused rather than given one', () {
      expect(builder.build(account, itemFor(mimeType: null)), isNull);
    });

    test('a non-media item is refused', () {
      expect(builder.build(account, itemFor(relativePath: 'notes.txt', mimeType: 'text/plain')), isNull);
    });
  });
}

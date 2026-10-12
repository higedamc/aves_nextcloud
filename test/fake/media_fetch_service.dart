import 'package:aves/model/entry/entry.dart';
import 'package:aves/services/media/media_fetch_service.dart';
import 'package:collection/collection.dart';
import 'package:test/fake.dart';

class FakeMediaFetchService extends Fake implements MediaFetchService {
  Set<AvesEntry> entries = {};

  // every `getEntry` URI, in call order. A test that means "the file was never read" has to assert on the
  // calls: an empty `entries` only says what this fake was given, and `getEntry` returning null for an
  // unknown URI is just one of the platform's answers for a file that is not there (the one for an image).
  final List<String> getEntryUris = [];

  @override
  Future<AvesEntry?> getEntry(String uri, String? mimeType, {bool allowUnsized = false}) async {
    getEntryUris.add(uri);
    return entries.firstWhereOrNull((v) => v.uri == uri);
  }
}

import 'dart:io';

import 'package:aves/l10n/l10n.dart';
import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/origins.dart';
import 'package:aves/ref/mime_types.dart';
import 'package:aves/widgets/viewer/info/metadata/metadata_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../../common.dart';

void main() {
  setUpAll(() async {
    await setUpAllServices();
  });

  setUp(() async {
    await setUpServices();
  });

  tearDownAll(() async {
    await tearDownAllServices();
  });

  AvesEntry entryAt({required int origin, required String path}) {
    final id = DateTime.now().microsecondsSinceEpoch;
    return AvesEntry(
      origin: origin,
      id: id,
      uri: 'file://$path',
      path: path,
      contentId: id,
      pageId: null,
      sourceMimeType: MimeTypes.jpeg,
      width: 1,
      height: 1,
      sourceRotationDegrees: 0,
      sizeBytes: 1,
      sourceTitle: 'test',
      dateAddedSecs: 0,
      dateModifiedMillis: 0,
      sourceDateTakenMillis: 0,
      durationMillis: null,
      trashed: false,
    );
  }

  Future<void> pumpSection(WidgetTester tester, AvesEntry entry) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CustomScrollView(
          slivers: [
            MetadataSectionSliver(
              entry: entry,
              metadataNotifier: ValueNotifier({}),
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a missing Nextcloud entry explains the empty metadata section', (tester) async {
    final missingPath = '${Directory.systemTemp.path}/aves_test_missing_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final entry = entryAt(origin: EntryOrigins.nextcloud, path: missingPath);

    await pumpSection(tester, entry);

    expect(find.text('This file has not been downloaded yet, so there is no metadata to show.'), findsOneWidget);
  });

  testWidgets('a Nextcloud entry with a file shows no explanation for its empty metadata section', (tester) async {
    final file = File('${Directory.systemTemp.path}/aves_test_present_${DateTime.now().microsecondsSinceEpoch}.jpg');
    file.writeAsBytesSync([0]);
    addTearDown(file.deleteSync);
    final entry = entryAt(origin: EntryOrigins.nextcloud, path: file.path);

    await pumpSection(tester, entry);

    expect(find.text('This file has not been downloaded yet, so there is no metadata to show.'), findsNothing);
  });

  testWidgets('a missing non-Nextcloud entry shows no explanation for its empty metadata section', (tester) async {
    final missingPath = '${Directory.systemTemp.path}/aves_test_missing_other_${DateTime.now().microsecondsSinceEpoch}.jpg';
    final entry = entryAt(origin: EntryOrigins.mediaStoreContent, path: missingPath);

    await pumpSection(tester, entry);

    expect(find.text('This file has not been downloaded yet, so there is no metadata to show.'), findsNothing);
  });
}

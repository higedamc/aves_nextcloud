import 'package:aves/model/metadata/catalog.dart';
import 'package:aves/model/nextcloud/remote_item.dart';

// Builds the catalog data a preview-backed entry gets at put time. A preview carries none of the original's
// own metadata (measured: 93 Exif tags in the original, 0 in the preview), so for any tier below `original`
// this is the only source for date and GPS, and the device-side cataloguer is not run at all for these
// entries (see `NextcloudCollectionSyncSink._putEntry`). Left-out fields (`isAnimated`, `rotationDegrees`,
// etc.) keep `CatalogMetadata`'s own defaults, which already hold for a preview: a grid/view derivative is
// never itself animated and already carries its rotation burned into the pixels.
//
// A missing date or coordinate is passed through as `null` rather than coerced to `0`, so the app's existing
// "unknown" paths (`AvesEntry.bestDate`, `hasGps`) show it as unknown instead of a silent, wrong zero.
CatalogMetadata catalogMetadataFromPhotoMetadata(int entryId, NextcloudPhotoMetadata? photoMetadata) {
  return CatalogMetadata(
    id: entryId,
    dateMillis: photoMetadata?.originalDateTime?.millisecondsSinceEpoch,
    latitude: photoMetadata?.latitude,
    longitude: photoMetadata?.longitude,
  );
}

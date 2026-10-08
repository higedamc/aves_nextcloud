import 'package:aves/model/entry/entry.dart';
import 'package:aves/model/entry/origins.dart';

extension ExtraAvesEntryNextcloud on AvesEntry {
  bool get isNextcloud => origin == EntryOrigins.nextcloud;

  // v1 is one-way: nothing about a mirrored entry may be edited, moved, renamed, trashed or deleted from Aves.
  // `canEdit` is already false for these entries (their path is neither media store nor vault content),
  // but action delegates must also consult this flag before any destructive operation.
  bool get isRemoteReadOnly => isNextcloud;
}

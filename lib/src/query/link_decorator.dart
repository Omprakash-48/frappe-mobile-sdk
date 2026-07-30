import 'package:sqflite/sqflite.dart';

import '../database/table_name.dart';
import '../models/doc_type_meta.dart';
import '../models/meta_resolver.dart';
import '../utils/sdk_log.dart';

/// Resolves the [DocTypeMeta] for the target of a Link / Dynamic Link
/// during decoration. Same signature as [MetaResolverFn] — kept as an
/// alias so the [LinkDecorator] API has a self-explanatory name.
typedef TargetMetaResolver = MetaResolverFn;

/// Adds a `<field>__display` companion to every Link / Dynamic Link
/// value in [row] so the UI can show the target's title without an extra
/// fetch. Spec §6.2 step 3.
///
/// Resolution rules per field:
/// - `__is_local=1`: the value is a `mobile_uuid` for a doc that hasn't
///   been pushed yet → look up the target by `mobile_uuid`.
/// - `__is_local=0` (or absent): the value is a server `name` → look up
///   the target by `server_name`.
///
/// On miss (target row not in local DB), the raw value is returned as
/// the display value — caller renders it as-is and a future pull will
/// hydrate the target.
class LinkDecorator {
  static Future<Map<String, Object?>> decorate({
    required Database db,
    required DocTypeMeta parentMeta,
    required Map<String, Object?> row,
    required TargetMetaResolver targetMetaResolver,
  }) async {
    final res = await decorateBatch(
      db: db,
      parentMeta: parentMeta,
      rows: [row],
      targetMetaResolver: targetMetaResolver,
    );
    return res.first;
  }

  /// Batch resolves Link / Dynamic Link fields for multiple rows simultaneously.
  /// Eliminates the O(N) database queries problem that occurs when hydrating
  /// large lists or options. Chunked into queries of 900 variables to avoid
  /// SQLite limits.
  static Future<List<Map<String, Object?>>> decorateBatch({
    required Database db,
    required DocTypeMeta parentMeta,
    required List<Map<String, Object?>> rows,
    required TargetMetaResolver targetMetaResolver,
  }) async {
    if (rows.isEmpty) return rows;

    final linkFields = parentMeta.fields
        .where((f) => f.fieldtype == 'Link' || f.fieldtype == 'Dynamic Link')
        .toList();
    if (linkFields.isEmpty) return rows;

    // 1. Gather all required lookups grouped by targetDoctype -> {isLocal: Set<ID>}
    final lookups = <String, Map<bool, Set<String>>>{};

    for (final row in rows) {
      for (final f in linkFields) {
        final name = f.fieldname;
        if (name == null || name.isEmpty) continue;
        final v = row[name];
        if (v == null || v.toString().isEmpty) continue;
        final strVal = v.toString();

        String? targetDoctype;
        if (f.fieldtype == 'Link') {
          targetDoctype = f.options;
        } else {
          final sibling = f.options;
          if (sibling != null && sibling.isNotEmpty) {
            targetDoctype = row[sibling] as String?;
          }
        }
        if (targetDoctype == null || targetDoctype.isEmpty) continue;

        final isLocal = (row['${name}__is_local'] as int?) == 1;

        lookups.putIfAbsent(targetDoctype, () => {true: {}, false: {}});
        lookups[targetDoctype]![isLocal]!.add(strVal);
      }
    }

    if (lookups.isEmpty) return rows;

    // 2. Perform batched queries.
    // Map of targetDoctype -> (Map of ID -> displayLabel)
    final displayCache = <String, Map<String, String>>{};

    for (final entry in lookups.entries) {
      final targetDoctype = entry.key;
      final targetMeta = await targetMetaResolver(targetDoctype);
      final titleCol = targetMeta.titleField ?? 'server_name';
      final targetTable = normalizeDoctypeTableName(targetDoctype);

      final isLocalSet = entry.value[true]!;
      final isServerSet = entry.value[false]!;

      final doctypeCache = <String, String>{};
      displayCache[targetDoctype] = doctypeCache;

      Future<void> fetchChunked(bool isLocal, Set<String> values) async {
        if (values.isEmpty) return;
        final list = values.toList();
        final col = isLocal ? 'mobile_uuid' : 'server_name';

        for (var i = 0; i < list.length; i += 900) {
          final chunk = list.sublist(
            i,
            i + 900 > list.length ? list.length : i + 900,
          );
          final placeholders = List.filled(chunk.length, '?').join(',');

          try {
            final targetRows = await db.query(
              targetTable,
              columns: [titleCol, 'server_name', 'mobile_uuid'],
              where: '$col IN ($placeholders)',
              whereArgs: chunk,
            );

            for (final tr in targetRows) {
              final title = tr[titleCol];
              final idVal = tr[col] as String?;
              if (idVal != null) {
                doctypeCache[idVal] = (title ?? tr['server_name'] ?? idVal)
                    .toString();
              }
            }
          } on DatabaseException catch (e) {
            // Target table not yet provisioned. Fall back to raw value.
            sdkLog(
              'LinkDecorator: target table "$targetTable" not provisioned, '
              'falling back to raw values — $e',
            );
          }
        }
      }

      await fetchChunked(true, isLocalSet);
      await fetchChunked(false, isServerSet);
    }

    // 3. Map back to rows.
    return rows.map((row) {
      final out = Map<String, Object?>.from(row);
      for (final f in linkFields) {
        final name = f.fieldname;
        if (name == null || name.isEmpty) continue;
        final v = row[name];
        if (v == null || v.toString().isEmpty) {
          if (v != null) out['${name}__display'] = v;
          continue;
        }
        final strVal = v.toString();

        String? targetDoctype;
        if (f.fieldtype == 'Link') {
          targetDoctype = f.options;
        } else {
          final sibling = f.options;
          if (sibling != null && sibling.isNotEmpty) {
            targetDoctype = row[sibling] as String?;
          }
        }

        if (targetDoctype == null || targetDoctype.isEmpty) {
          out['${name}__display'] = v;
          continue;
        }

        final doctypeCache = displayCache[targetDoctype];
        if (doctypeCache != null && doctypeCache.containsKey(strVal)) {
          out['${name}__display'] = doctypeCache[strVal];
        } else {
          out['${name}__display'] = v;
        }
      }
      return out;
    }).toList();
  }
}

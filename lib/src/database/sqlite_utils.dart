import 'package:sqflite/sqflite.dart';

/// Returns `true` if a table named [tableName] exists in the SQLite schema.
///
/// Accepts either a [Database] (root connection) or a [Transaction] — both
/// implement [DatabaseExecutor] — so the same helper works inside and outside
/// transactions. Centralized so the `sqlite_master` query string lives in one
/// place; all writers (DDL, form-save, pull-apply, sync) call this instead of
/// inlining the lookup.
Future<bool> sqliteTableExists(DatabaseExecutor exec, String tableName) async {
  final rows = await exec.rawQuery(
    "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
    [tableName],
  );
  return rows.isNotEmpty;
}

/// Returns `true` if [tableName] has a column named [columnName].
///
/// Uses `PRAGMA table_info`. Centralized so callers can cheaply guard a query
/// that references a column which may be absent on drifted/legacy tables
/// (e.g. child/link `docs__*` tables that never carry `sync_status`), instead
/// of issuing the query and catching the resulting "no such column" error.
Future<bool> sqliteColumnExists(
  DatabaseExecutor exec,
  String tableName,
  String columnName,
) async {
  final rows = await exec.rawQuery('PRAGMA table_info("$tableName")');
  for (final r in rows) {
    if (r['name'] == columnName) return true;
  }
  return false;
}

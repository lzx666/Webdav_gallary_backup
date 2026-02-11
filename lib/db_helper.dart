import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

class DbHelper {
  static Database? _db;
  static Future<Database> get db async {
    if (_db != null) return _db!;
    _db = await openDatabase(join(await getDatabasesPath(), 'backup_records.db'),
      onCreate: (db, version) => db.execute('CREATE TABLE uploaded_assets(asset_id TEXT PRIMARY KEY)'),
      version: 1,
    );
    return _db!;
  }
  static Future<void> markAsUploaded(String id) async {
    final database = await db;
    await database.insert('uploaded_assets', {'asset_id': id}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  static Future<bool> isUploaded(String id) async {
    final database = await db;
    final List<Map<String, dynamic>> maps = await database.query('uploaded_assets', where: 'asset_id = ?', whereArgs: [id]);
    return maps.isNotEmpty;
  }
}
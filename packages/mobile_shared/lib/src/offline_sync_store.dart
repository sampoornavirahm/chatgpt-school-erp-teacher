import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as paths;
import 'package:sqflite/sqflite.dart';

class OfflineSyncStore {
  OfflineSyncStore._(this._database);

  final Database _database;
  static OfflineSyncStore? _shared;
  static String? _sharedDatabaseKey;

  static Future<OfflineSyncStore> open({
    String? schoolId,
    String? accountId,
    int? userId,
    String? deviceId,
    bool migrateLegacySnapshot = false,
  }) async {
    final databaseKey = _databaseKey(schoolId, accountId);
    if (_shared != null && _sharedDatabaseKey == databaseKey) return _shared!;
    await _shared?._database.close();
    final root = await getDatabasesPath();
    final databasePath = paths.join(
      root,
      'school_erp_offline_$databaseKey.sqlite',
    );
    final isNewAccountStore =
        !await databaseFactory.databaseExists(databasePath);
    final database = await openDatabase(
      databasePath,
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE cached_classes (
            public_id TEXT PRIMARY KEY,
            name TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE cached_sections (
            public_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            class_public_id TEXT NOT NULL,
            class_name TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE cached_students (
            public_id TEXT PRIMARY KEY,
            student_id INTEGER,
            class_id INTEGER,
            section_id INTEGER,
            full_name TEXT NOT NULL,
            admission_no TEXT NOT NULL,
            status TEXT NOT NULL,
            class_name TEXT NOT NULL,
            section_name TEXT NOT NULL,
            section_public_id TEXT NOT NULL
          )
        ''');
        await db.execute('''
          CREATE TABLE cached_attendance (
            student_public_id TEXT NOT NULL,
            attendance_date TEXT NOT NULL,
            status TEXT NOT NULL,
            reason TEXT NOT NULL,
            revision INTEGER NOT NULL,
            updated_at TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (student_public_id, attendance_date)
          )
        ''');
        await db.execute('''
          CREATE TABLE sync_outbox (
            operation_id TEXT PRIMARY KEY,
            school_id TEXT NOT NULL,
            device_id TEXT NOT NULL,
            user_id INTEGER NOT NULL,
            entity_type TEXT NOT NULL,
            entity_id TEXT NOT NULL,
            operation TEXT NOT NULL,
            payload_schema_version INTEGER NOT NULL,
            created_at TEXT NOT NULL,
            base_revision INTEGER,
            payload_json TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('pending','in_progress','accepted','failed','rejected','conflict')),
            attempts INTEGER NOT NULL DEFAULT 0,
            next_retry_at TEXT NOT NULL,
            last_error TEXT NOT NULL DEFAULT ''
          )
        ''');
        await db.execute('''
          CREATE TABLE sync_cursors (
            direction TEXT PRIMARY KEY,
            cursor_value INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL
          )
        ''');
        await db.execute(
          'CREATE INDEX idx_mobile_outbox_retry ON sync_outbox(status,next_retry_at,created_at)',
        );
        await _createMobileRecords(db);
        await _createHostedParentTables(db);
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'ALTER TABLE cached_students ADD COLUMN student_id INTEGER',
          );
          await db.execute(
            'ALTER TABLE cached_students ADD COLUMN class_id INTEGER',
          );
          await db.execute(
            'ALTER TABLE cached_students ADD COLUMN section_id INTEGER',
          );
          await _createMobileRecords(db);
        }
        if (oldVersion < 3) await _createHostedParentTables(db);
      },
      onOpen: (db) async {
        await db.execute('PRAGMA foreign_keys=ON');
      },
    );
    if (isNewAccountStore &&
        schoolId != null &&
        userId != null &&
        deviceId != null) {
      await _migrateLegacyPendingOperations(
        root: root,
        schoolId: schoolId,
        userId: userId,
        deviceId: deviceId,
        includeSnapshot: migrateLegacySnapshot,
        target: database,
      );
    }
    _shared = OfflineSyncStore._(database);
    _sharedDatabaseKey = databaseKey;
    return _shared!;
  }

  static Future<void> closeForRestart() async {
    await _shared?._database.close();
    _shared = null;
    _sharedDatabaseKey = null;
  }

  static String _databaseKey(String? schoolId, String? accountId) {
    final identity = '${schoolId ?? 'unpaired'}|${accountId ?? 'default'}';
    return sha256.convert(utf8.encode(identity)).toString().substring(0, 32);
  }

  static Future<void> _createMobileRecords(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE mobile_records (
        entity_type TEXT NOT NULL,
        entity_id TEXT NOT NULL,
        payload_json TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY(entity_type,entity_id)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_mobile_records_type ON mobile_records(entity_type)',
    );
  }

  static Future<void> _createHostedParentTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE hosted_parent_cache (
        cache_key TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE hosted_parent_outbox (
        operation_id TEXT PRIMARY KEY,
        payload_json TEXT NOT NULL,
        status TEXT NOT NULL CHECK (status IN ('pending','queued','accepted','rejected')),
        created_at TEXT NOT NULL,
        last_error TEXT NOT NULL DEFAULT ''
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_hosted_parent_outbox_status ON hosted_parent_outbox(status,created_at)',
    );
  }

  Future<void> replaceHostedParentCache({
    required List<Map<String, dynamic>> children,
    required List<Map<String, dynamic>> commands,
  }) async {
    final now = DateTime.now().toUtc().toIso8601String();
    await _database.transaction((txn) async {
      await txn.insert('hosted_parent_cache', {
        'cache_key': 'children',
        'payload_json': jsonEncode(children),
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await txn.insert('hosted_parent_cache', {
        'cache_key': 'commands',
        'payload_json': jsonEncode(commands),
        'updated_at': now,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<Map<String, dynamic>?> readHostedParentCache() async {
    final rows = await _database.query('hosted_parent_cache');
    if (rows.isEmpty) return null;
    final values = <String, dynamic>{};
    for (final row in rows) {
      try {
        values[row['cache_key'] as String] = jsonDecode(
          row['payload_json'] as String,
        );
      } on FormatException {
        continue;
      }
    }
    return values;
  }

  Future<void> queueHostedParentCommand(Map<String, dynamic> command) async {
    await _database.insert('hosted_parent_outbox', {
      'operation_id': command['operationId'],
      'payload_json': jsonEncode(command),
      'status': 'pending',
      'created_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<Map<String, dynamic>>> pendingHostedParentCommands() async {
    final rows = await _database.query(
      'hosted_parent_outbox',
      where: "status IN ('pending','queued')",
      orderBy: 'created_at',
      limit: 100,
    );
    return rows
        .map((row) => jsonDecode(row['payload_json'] as String))
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<List<Map<String, dynamic>>> hostedParentOutbox() async {
    final rows = await _database.query(
      'hosted_parent_outbox',
      orderBy: 'created_at DESC',
      limit: 100,
    );
    return rows.map((row) {
      final payload = jsonDecode(row['payload_json'] as String);
      return {
        if (payload is Map) ...Map<String, dynamic>.from(payload),
        'status': row['status'],
        'lastError': row['last_error'],
      };
    }).toList();
  }

  Future<void> setHostedParentCommandStatus(
    String operationId,
    String status, {
    String message = '',
  }) async {
    await _database.update(
      'hosted_parent_outbox',
      {'status': status, 'last_error': message},
      where: 'operation_id=?',
      whereArgs: [operationId],
    );
  }

  static Future<void> _migrateLegacyPendingOperations({
    required String root,
    required String schoolId,
    required int userId,
    required String deviceId,
    required bool includeSnapshot,
    required Database target,
  }) async {
    final cleanSchoolId = schoolId.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '');
    final legacyKey =
        cleanSchoolId.isEmpty
            ? 'unpaired_v1'
            : cleanSchoolId.substring(0, min(36, cleanSchoolId.length));
    final legacyPath = paths.join(root, 'school_erp_offline_$legacyKey.sqlite');
    if (!await databaseFactory.databaseExists(legacyPath)) return;
    Database? legacy;
    try {
      legacy = await openDatabase(
        legacyPath,
        readOnly: true,
        singleInstance: false,
      );
      try {
        final queued = await legacy.query(
          'sync_outbox',
          where:
              "school_id=? AND user_id=? AND device_id=? AND status IN ('pending','in_progress','failed','conflict','rejected')",
          whereArgs: [schoolId, userId, deviceId],
          orderBy: 'created_at',
        );
        if (queued.isNotEmpty) {
          final batch = target.batch();
          for (final row in queued) {
            batch.insert('sync_outbox', {
              ...row,
              'status':
                  row['status'] == 'in_progress' ? 'pending' : row['status'],
            }, conflictAlgorithm: ConflictAlgorithm.ignore);
          }
          await batch.commit(noResult: true);
        }
      } on DatabaseException {
        // Older or incomplete cache files may not have the Phase 4 outbox table.
      }
      if (includeSnapshot) await _copyLegacySnapshot(legacy, target);
    } on DatabaseException {
      // Leave stale/incomplete legacy data untouched and keep the new cache isolated.
    } finally {
      await legacy?.close();
    }
  }

  static Future<void> _copyLegacySnapshot(
    Database source,
    Database target,
  ) async {
    try {
      final classes = await source.query('cached_classes');
      final sections = await source.query('cached_sections');
      final students = await source.query('cached_students');
      final attendance = await source.query('cached_attendance');
      final cursors = await source.query('sync_cursors');
      final batch = target.batch();
      for (final (table, rows) in [
        ('cached_classes', classes),
        ('cached_sections', sections),
        ('cached_students', students),
        ('cached_attendance', attendance),
        ('sync_cursors', cursors),
      ]) {
        for (final row in rows) {
          batch.insert(
            table,
            row,
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }
      }
      await batch.commit(noResult: true);
    } on DatabaseException {
      // Preserve any outbox already copied; a successful Hub refresh will replace the snapshot.
    }
  }

  Future<void> replaceSnapshot(Map<String, dynamic> snapshot) async {
    final batch = _database.batch();
    for (final table in [
      'cached_classes',
      'cached_sections',
      'cached_students',
      'cached_attendance',
      'mobile_records',
    ]) {
      batch.delete(table);
    }
    for (final row in _mapRows(snapshot['classes'])) {
      batch.insert('cached_classes', {
        'public_id': row['publicId'],
        'name': row['name'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    for (final row in _mapRows(snapshot['sections'])) {
      batch.insert('cached_sections', {
        'public_id': row['publicId'],
        'name': row['name'],
        'class_public_id': row['classPublicId'],
        'class_name': row['className'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    for (final row in _mapRows(snapshot['students'])) {
      batch.insert('cached_students', {
        'public_id': row['publicId'],
        'student_id': row['id'],
        'class_id': row['classId'],
        'section_id': row['sectionId'],
        'full_name': row['fullName'],
        'admission_no': row['admissionNo'] ?? '',
        'status': row['status'] ?? 'active',
        'class_name': row['className'],
        'section_name': row['sectionName'],
        'section_public_id': row['sectionPublicId'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    for (final row in _mapRows(snapshot['attendance'])) {
      batch.insert('cached_attendance', {
        'student_public_id': row['studentPublicId'],
        'attendance_date': row['date'],
        'status': row['status'],
        'reason': row['reason'] ?? '',
        'revision': row['revision'] ?? 1,
        'updated_at': row['updatedAt'] ?? '',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    final mobileRecords = snapshot['mobileRecords'];
    if (mobileRecords is Map) {
      for (final entry in mobileRecords.entries) {
        if (entry.key is! String) continue;
        for (final row in _mapRows(entry.value)) {
          final id = _entityId(entry.key as String, row);
          if (id == null) continue;
          batch.insert('mobile_records', {
            'entity_type': entry.key,
            'entity_id': id,
            'payload_json': jsonEncode(row),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    }
    await batch.commit(noResult: true);
    await saveCursor('pull', _int(snapshot['cursor']));
  }

  Future<void> applyEvents(List<dynamic> events) async {
    final batch = _database.batch();
    for (final event in events) {
      if (event is! Map) continue;
      final payload = event['payload'];
      if (event['entityType'] != 'attendance' || payload is! Map) continue;
      batch.insert('cached_attendance', {
        'student_public_id': payload['studentPublicId'],
        'attendance_date': payload['date'],
        'status': payload['status'],
        'reason': payload['reason'] ?? '',
        'revision': event['revision'] ?? 1,
        'updated_at': event['createdAt'] ?? '',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  Future<String> queueAttendance({
    required String schoolId,
    required String deviceId,
    required int userId,
    required String studentPublicId,
    required String date,
    required String status,
    required int? baseRevision,
    String reason = '',
    String correctionReason = '',
  }) async {
    final now = DateTime.now().toUtc();
    final operationId = _uuidV4();
    final payload = {
      'studentPublicId': studentPublicId,
      'date': date,
      'status': status,
      'reason': reason,
      'correctionReason': correctionReason,
    };
    await _database.insert('sync_outbox', {
      'operation_id': operationId,
      'school_id': schoolId,
      'device_id': deviceId,
      'user_id': userId,
      'entity_type': 'attendance',
      'entity_id': '$studentPublicId:$date',
      'operation': 'attendance.mark',
      'payload_schema_version': 1,
      'created_at': now.toIso8601String(),
      'base_revision': baseRevision,
      'payload_json': jsonEncode(payload),
      'status': 'pending',
      'attempts': 0,
      'next_retry_at': now.toIso8601String(),
    });
    return operationId;
  }

  Future<String> queueCommand({
    required String schoolId,
    required String deviceId,
    required int userId,
    required String entityType,
    required String entityId,
    required String operation,
    required Map<String, dynamic> payload,
    int? baseRevision,
  }) async {
    final now = DateTime.now().toUtc();
    final operationId = _uuidV4();
    await _database.insert('sync_outbox', {
      'operation_id': operationId,
      'school_id': schoolId,
      'device_id': deviceId,
      'user_id': userId,
      'entity_type': entityType,
      'entity_id': entityId,
      'operation': operation,
      'payload_schema_version': 1,
      'created_at': now.toIso8601String(),
      'base_revision': baseRevision,
      'payload_json': jsonEncode(payload),
      'status': 'pending',
      'attempts': 0,
      'next_retry_at': now.toIso8601String(),
    });
    return operationId;
  }

  Future<List<Map<String, Object?>>> dueAttendanceOperations({
    int limit = 100,
  }) => _database.query(
    'sync_outbox',
    where:
        "entity_type='attendance' AND status IN ('pending','failed') AND next_retry_at<=?",
    whereArgs: [DateTime.now().toUtc().toIso8601String()],
    orderBy: 'created_at',
    limit: limit,
  );

  Future<List<Map<String, Object?>>> dueCommandOperations({
    int limit = 100,
  }) => _database.query(
    'sync_outbox',
    where:
        "entity_type!='attendance' AND status IN ('pending','failed') AND next_retry_at<=?",
    whereArgs: [DateTime.now().toUtc().toIso8601String()],
    orderBy: 'created_at',
    limit: limit,
  );

  Future<List<Map<String, Object?>>> queuedAttendanceDrafts(String date) async {
    final rows = await _database.query(
      'sync_outbox',
      where:
          "entity_type='attendance' AND status IN ('pending','in_progress','failed','conflict')",
      orderBy: 'created_at',
    );
    return rows.where((row) {
      try {
        final payload =
            jsonDecode(row['payload_json'] as String) as Map<String, dynamic>;
        return payload['date'] == date;
      } catch (_) {
        return false;
      }
    }).toList();
  }

  Future<void> applyPushResults(List<dynamic> results) async {
    final batch = _database.batch();
    for (final result in results) {
      if (result is! Map) continue;
      final operationId = result['operationId'];
      if (operationId is! String) continue;
      final status = result['status'];
      final storedStatus = switch (status) {
        'accepted' => 'accepted',
        'conflict' => 'conflict',
        'rejected' => 'rejected',
        _ => 'failed',
      };
      batch.update(
        'sync_outbox',
        {
          'status': storedStatus,
          'last_error': result['message']?.toString() ?? '',
        },
        where: 'operation_id=?',
        whereArgs: [operationId],
      );
      if (storedStatus == 'accepted' &&
          result['studentPublicId'] is String &&
          result['date'] is String) {
        batch.insert('cached_attendance', {
          'student_public_id': result['studentPublicId'],
          'attendance_date': result['date'],
          'status': result['attendanceStatus'],
          'reason': result['reason'] ?? '',
          'revision': result['revision'] ?? 1,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    await batch.commit(noResult: true);
  }

  Future<void> applyCommandResults(List<dynamic> results) async {
    final batch = _database.batch();
    for (final result in results) {
      if (result is! Map || result['operationId'] is! String) continue;
      final status = switch (result['status']) {
        'accepted' => 'accepted',
        'conflict' => 'conflict',
        'rejected' => 'rejected',
        _ => 'failed',
      };
      batch.update(
        'sync_outbox',
        {'status': status, 'last_error': result['message']?.toString() ?? ''},
        where: 'operation_id=?',
        whereArgs: [result['operationId']],
      );
      final operationRows = await _database.query(
        'sync_outbox',
        columns: ['entity_type', 'entity_id', 'payload_json'],
        where: 'operation_id=?',
        whereArgs: [result['operationId']],
        limit: 1,
      );
      if (status != 'accepted' || operationRows.isEmpty) continue;
      final operation = operationRows.single;
      final type = operation['entity_type']?.toString();
      final payload = result['record'];
      if (type == null || payload is! Map) continue;
      final record = Map<String, dynamic>.from(payload);
      final queuedPayload = _decode(operation['payload_json']?.toString());
      if (type == 'announcement_ack') {
        final announcementId = queuedPayload?['announcementId'];
        if (announcementId != null) {
          final existing = await mobileRecord(
            'announcements',
            '$announcementId',
          );
          if (existing != null) {
            existing['acknowledged'] = true;
            batch.insert('mobile_records', {
              'entity_type': 'announcements',
              'entity_id': '$announcementId',
              'payload_json': jsonEncode(existing),
              'updated_at': DateTime.now().toUtc().toIso8601String(),
            }, conflictAlgorithm: ConflictAlgorithm.replace);
          }
        }
      } else {
        final entityId =
            _entityId(type, record) ?? operation['entity_id']?.toString();
        if (entityId != null) {
          final recordType =
              type == 'exam_mark' ? 'examMarks' : 'parentRequests';
          final existing = await mobileRecord(recordType, entityId);
          if (existing != null) {
            record.addAll(existing);
            record.addAll(Map<String, dynamic>.from(payload));
          }
          if (type == 'parent_request' && queuedPayload != null) {
            record['studentName'] = queuedPayload['studentName'];
          }
          batch.insert('mobile_records', {
            'entity_type': recordType,
            'entity_id': entityId,
            'payload_json': jsonEncode(record),
            'updated_at': DateTime.now().toUtc().toIso8601String(),
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
    }
    await batch.commit(noResult: true);
  }

  Future<void> markRetry(Map<String, Object?> operation, String message) async {
    final attempts = _int(operation['attempts']) + 1;
    if (attempts >= 8) {
      await _database.update(
        'sync_outbox',
        {
          'status': 'failed',
          'attempts': attempts,
          'last_error': message,
          'next_retry_at':
              DateTime.now()
                  .toUtc()
                  .add(const Duration(days: 3650))
                  .toIso8601String(),
        },
        where: 'operation_id=?',
        whereArgs: [operation['operation_id']],
      );
      return;
    }
    final baseSeconds = min(3600, 5 * (1 << min(attempts - 1, 10)));
    final jitter = 0.75 + Random.secure().nextDouble() * 0.5;
    final wait = Duration(milliseconds: (baseSeconds * 1000 * jitter).round());
    await _database.update(
      'sync_outbox',
      {
        'status': 'failed',
        'attempts': attempts,
        'last_error': message,
        'next_retry_at': DateTime.now().toUtc().add(wait).toIso8601String(),
      },
      where: 'operation_id=?',
      whereArgs: [operation['operation_id']],
    );
  }

  Future<void> retryFailed() async {
    await _database.update('sync_outbox', {
      'status': 'pending',
      'attempts': 0,
      'last_error': '',
      'next_retry_at': DateTime.now().toUtc().toIso8601String(),
    }, where: "status='failed'");
  }

  Future<List<Map<String, Object?>>> classes() =>
      _database.query('cached_classes', orderBy: 'name');
  Future<List<Map<String, Object?>>> sections() =>
      _database.query('cached_sections', orderBy: 'class_name,name');
  Future<List<Map<String, Object?>>> students({String? sectionPublicId}) =>
      _database.query(
        'cached_students',
        where: sectionPublicId == null ? null : 'section_public_id=?',
        whereArgs: sectionPublicId == null ? null : [sectionPublicId],
        orderBy: 'full_name',
      );
  Future<Map<String, Object?>?> attendance(
    String studentPublicId,
    String date,
  ) async {
    final rows = await _database.query(
      'cached_attendance',
      where: 'student_public_id=? AND attendance_date=?',
      whereArgs: [studentPublicId, date],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  Future<List<Map<String, Object?>>> attendanceRows() => _database.query(
    'cached_attendance',
    orderBy: 'attendance_date DESC',
    limit: 1000,
  );

  Future<List<Map<String, dynamic>>> mobileRecords(String entityType) async {
    final rows = await _database.query(
      'mobile_records',
      columns: ['payload_json'],
      where: 'entity_type=?',
      whereArgs: [entityType],
      orderBy: 'entity_id',
    );
    return rows
        .map((row) => _decode(row['payload_json']?.toString()))
        .whereType<Map<String, dynamic>>()
        .toList();
  }

  Future<Map<String, dynamic>?> mobileRecord(
    String entityType,
    String entityId,
  ) async {
    final rows = await _database.query(
      'mobile_records',
      columns: ['payload_json'],
      where: 'entity_type=? AND entity_id=?',
      whereArgs: [entityType, entityId],
      limit: 1,
    );
    return rows.isEmpty
        ? null
        : _decode(rows.first['payload_json']?.toString());
  }

  Future<void> saveMobileRecord(
    String entityType,
    Map<String, dynamic> record,
  ) async {
    final id = _entityId(entityType, record);
    if (id == null)
      throw ArgumentError.value(record, 'record', 'Record needs a stable id.');
    await _database.insert('mobile_records', {
      'entity_type': entityType,
      'entity_id': id,
      'payload_json': jsonEncode(record),
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> queuedCommands({
    String? entityType,
  }) => _database.query(
    'sync_outbox',
    where:
        entityType == null
            ? "entity_type!='attendance' AND status IN ('pending','in_progress','failed','conflict','rejected')"
            : 'entity_type=? AND status IN (\'pending\',\'in_progress\',\'failed\',\'conflict\',\'rejected\')',
    whereArgs: entityType == null ? null : [entityType],
    orderBy: 'created_at DESC',
    limit: 250,
  );

  Future<String?> latestOperationStatus(String entityId) async {
    final rows = await _database.query(
      'sync_outbox',
      columns: ['status'],
      where: 'entity_id=?',
      whereArgs: [entityId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first['status']?.toString();
  }

  Future<Map<String, int>> statusCounts() async {
    final rows = await _database.rawQuery(
      'SELECT status,COUNT(*) AS count FROM sync_outbox GROUP BY status',
    );
    final counts = {
      for (final status in [
        'pending',
        'in_progress',
        'accepted',
        'failed',
        'rejected',
        'conflict',
      ])
        status: 0,
    };
    for (final row in rows) {
      counts[row['status'].toString()] = _int(row['count']);
    }
    return counts;
  }

  Future<int> cursor(String direction) async {
    final rows = await _database.query(
      'sync_cursors',
      columns: ['cursor_value'],
      where: 'direction=?',
      whereArgs: [direction],
      limit: 1,
    );
    return rows.isEmpty ? 0 : _int(rows.first['cursor_value']);
  }

  Future<void> saveCursor(String direction, int cursorValue) async {
    await _database.insert('sync_cursors', {
      'direction': direction,
      'cursor_value': cursorValue,
      'updated_at': DateTime.now().toUtc().toIso8601String(),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearIfNoPendingChanges() async {
    final due = await _database.rawQuery(
      "SELECT COUNT(*) AS count FROM sync_outbox WHERE status IN ('pending','in_progress','failed','conflict')",
    );
    if (_int(due.first['count']) > 0)
      throw StateError(
        'Sync or resolve pending changes before removing this school account from the app.',
      );
    await _database.delete('cached_classes');
    await _database.delete('cached_sections');
    await _database.delete('cached_students');
    await _database.delete('cached_attendance');
    await _database.delete('mobile_records');
    await _database.delete('sync_outbox');
    await _database.delete('sync_cursors');
  }

  static List<Map<String, dynamic>> _mapRows(dynamic value) =>
      value is List
          ? value
              .whereType<Map>()
              .map((row) => Map<String, dynamic>.from(row))
              .toList()
          : const [];

  static int _int(Object? value) =>
      value is int ? value : int.tryParse(value?.toString() ?? '') ?? 0;

  static Map<String, dynamic>? _decode(String? value) {
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  static String? _entityId(String type, Map<String, dynamic> row) {
    final id = row['id'];
    if (id != null) return '$id';
    if (type == 'examMarks' || type == 'exam_mark') {
      final examId = row['examId'];
      final subjectId = row['examSubjectId'];
      final studentId = row['studentId'];
      if (examId != null && subjectId != null && studentId != null) {
        return '$examId:$subjectId:$studentId';
      }
    }
    return null;
  }

  static String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }
}

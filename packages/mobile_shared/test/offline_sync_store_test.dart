import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as paths;
import 'package:school_erp_mobile_shared/src/offline_sync_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  tearDown(() async => OfflineSyncStore.closeForRestart());

  test(
    'version 3 cache upgrade preserves day marks and normalizes queued attendance period',
    () async {
      final schoolId = 'upgrade_${DateTime.now().microsecondsSinceEpoch}';
      const accountId = 'teacher_upgrade';
      const studentId = '018f7e5a-72b4-7ca2-9c2d-112233445577';
      const operationId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      final key = sha256
          .convert(utf8.encode('$schoolId|$accountId'))
          .toString()
          .substring(0, 32);
      final path = paths.join(
        await getDatabasesPath(),
        'school_erp_offline_$key.sqlite',
      );
      final legacy = await openDatabase(
        path,
        version: 3,
        onCreate: (db, _) async {
          await db.execute('''
            CREATE TABLE cached_attendance (
              student_public_id TEXT NOT NULL,
              attendance_date TEXT NOT NULL,
              status TEXT NOT NULL,
              reason TEXT NOT NULL,
              revision INTEGER NOT NULL,
              updated_at TEXT NOT NULL DEFAULT '',
              PRIMARY KEY (student_public_id,attendance_date)
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
        },
      );
      await legacy.insert('cached_attendance', {
        'student_public_id': studentId,
        'attendance_date': '2026-10-20',
        'status': 'present',
        'reason': '',
        'revision': 1,
        'updated_at': '',
      });
      await legacy.insert('sync_outbox', {
        'operation_id': operationId,
        'school_id': schoolId,
        'device_id': 'device_upgrade',
        'user_id': 7,
        'entity_type': 'attendance',
        'entity_id': '$studentId:2026-10-20',
        'operation': 'upsert',
        'payload_schema_version': 1,
        'created_at': '2026-10-20T00:00:00Z',
        'base_revision': 1,
        'payload_json': jsonEncode({
          'studentPublicId': studentId,
          'date': '2026-10-20',
          'status': 'absent',
          'reason': '',
        }),
        'status': 'pending',
        'attempts': 0,
        'next_retry_at': '',
        'last_error': '',
      });
      await legacy.close();

      final store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: accountId,
      );
      expect(
        (await store.attendance(studentId, '2026-10-20'))?['status'],
        'present',
      );
      final queued = await store.queuedAttendanceDrafts(
        '2026-10-20',
        period: 0,
      );
      expect(queued.single['operation_id'], operationId);
      expect(queued.single['entity_id'], '$studentId:2026-10-20:0');
      expect(queued.single['payload_json'], contains('"period":0'));
    },
  );

  test(
    'attendance queue deduplicates retries within a period, not across periods',
    () async {
      final schoolId = 'period_${DateTime.now().microsecondsSinceEpoch}';
      final store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'teacher_periods',
      );
      const studentId = '018f7e5a-72b4-7ca2-9c2d-112233445577';
      const deviceId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
      final first = await store.queueAttendance(
        schoolId: schoolId,
        deviceId: deviceId,
        userId: 7,
        studentPublicId: studentId,
        date: '2026-10-20',
        status: 'present',
        baseRevision: null,
      );
      final second = await store.queueAttendance(
        schoolId: schoolId,
        deviceId: deviceId,
        userId: 7,
        studentPublicId: studentId,
        date: '2026-10-20',
        period: 2,
        status: 'absent',
        baseRevision: null,
      );
      final retry = await store.queueAttendance(
        schoolId: schoolId,
        deviceId: deviceId,
        userId: 7,
        studentPublicId: studentId,
        date: '2026-10-20',
        period: 2,
        status: 'late',
        baseRevision: null,
      );

      expect(first, isNot(second));
      expect(retry, second);
      final queued = await store.dueAttendanceOperations();
      expect(queued, hasLength(2));
      expect(
        queued.map((row) => row['entity_id']),
        contains('$studentId:2026-10-20:0'),
      );
      expect(
        queued.map((row) => row['entity_id']),
        contains('$studentId:2026-10-20:2'),
      );
    },
  );

  test(
    'cached timetable exposes its most recent successful refresh time',
    () async {
      final schoolId = 'schedule_${DateTime.now().microsecondsSinceEpoch}';
      final store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'teacher_schedule',
      );
      await store.replaceSnapshot({
        'schoolId': schoolId,
        'cursor': 0,
        'mobileRecords': {
          'timetable': [
            {'id': 1, 'weekday': 1, 'period': 1, 'subjectName': 'Science'},
          ],
        },
      });

      expect(
        DateTime.tryParse(
          await store.mobileRecordsUpdatedAt('timetable') ?? '',
        ),
        isNotNull,
      );
      expect(await store.mobileRecordsUpdatedAt('schoolCalendar'), isNull);
    },
  );

  test(
    'repeated unsent attendance edits update one queued operation',
    () async {
      final schoolId = 'test_${DateTime.now().microsecondsSinceEpoch}';
      const studentId = '018f7e5a-72b4-7ca2-9c2d-112233445577';
      final store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'teacher_7',
      );

      final firstOperationId = await store.queueAttendance(
        schoolId: schoolId,
        deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        userId: 7,
        studentPublicId: studentId,
        date: '2026-10-20',
        status: 'absent',
        baseRevision: null,
      );
      final secondOperationId = await store.queueAttendance(
        schoolId: schoolId,
        deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        userId: 7,
        studentPublicId: studentId,
        date: '2026-10-20',
        status: 'present',
        baseRevision: null,
      );

      expect(secondOperationId, firstOperationId);
      final queued = await store.dueAttendanceOperations();
      expect(queued, hasLength(1));
      expect(queued.single['operation_id'], firstOperationId);
      expect(queued.single['payload_json'], contains('"status":"present"'));
    },
  );

  test(
    'offline attendance stays queued across an app database restart',
    () async {
      final schoolId = 'test_${DateTime.now().microsecondsSinceEpoch}';
      const studentId = '018f7e5a-72b4-7ca2-9c2d-112233445577';
      const sectionId = '018f7e5a-72b4-7ca2-9c2d-112233445588';
      var store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'teacher_7',
      );
      await store.replaceSnapshot({
        'schoolId': schoolId,
        'cursor': 4,
        'classes': [
          {
            'publicId': '018f7e5a-72b4-7ca2-9c2d-112233445599',
            'name': 'Grade 1',
          },
        ],
        'sections': [
          {
            'publicId': sectionId,
            'name': 'A',
            'classPublicId': '018f7e5a-72b4-7ca2-9c2d-112233445599',
            'className': 'Grade 1',
          },
        ],
        'students': [
          {
            'publicId': studentId,
            'id': 17,
            'classId': 3,
            'sectionId': 5,
            'fullName': 'Sample Student',
            'admissionNo': 'S-1',
            'status': 'active',
            'className': 'Grade 1',
            'sectionName': 'A',
            'sectionPublicId': sectionId,
          },
        ],
        'attendance': [],
        'mobileRecords': {
          'timetable': [
            {'id': 9, 'subjectName': 'Science'},
          ],
          'schoolCalendar': [
            {
              'id': 12,
              'title': 'Staff meeting',
              'startDate': '2026-11-12',
              'eventType': 'event',
            },
          ],
          'teacherSubstitutions': [
            {
              'id': 15,
              'assignmentDate': '2026-11-13',
              'subjectName': 'Science',
              'status': 'assigned',
            },
          ],
          'examMarks': [
            {
              'examId': 4,
              'examSubjectId': 6,
              'studentId': 17,
              'marksAwarded': null,
            },
          ],
        },
      });

      final operationId = await store.queueAttendance(
        schoolId: schoolId,
        deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        userId: 7,
        studentPublicId: studentId,
        date: '2026-10-20',
        status: 'present',
        baseRevision: null,
      );
      final markOperationId = await store.queueCommand(
        schoolId: schoolId,
        deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        userId: 7,
        entityType: 'exam_mark',
        entityId: '4:6:17',
        operation: 'exam.mark',
        payload: {
          'examId': 4,
          'examSubjectId': 6,
          'studentId': 17,
          'marksAwarded': 85,
        },
        baseRevision: null,
      );
      final requestOperationId = await store.queueCommand(
        schoolId: schoolId,
        deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        userId: 7,
        entityType: 'parent_request',
        entityId: 'local-1',
        operation: 'parent_request.submit',
        payload: {
          'studentId': 17,
          'requestType': 'leave',
          'message': 'Appointment',
        },
      );
      expect(operationId, matches(RegExp(r'^[0-9a-f-]{36}$')));
      expect((await store.statusCounts())['pending'], 3);
      await expectLater(
        store.clearIfNoPendingChanges(),
        throwsA(isA<StateError>()),
      );
      await OfflineSyncStore.closeForRestart();

      store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'teacher_7',
      );
      final students = await store.students(sectionPublicId: sectionId);
      final drafts = await store.queuedAttendanceDrafts('2026-10-20');
      expect(students.single['full_name'], 'Sample Student');
      expect(drafts.single['operation_id'], operationId);
      expect((await store.statusCounts())['pending'], 3);
      expect(await store.cursor('pull'), 4);
      expect((await store.students()).single['student_id'], 17);
      expect(
        (await store.mobileRecords('timetable')).single['subjectName'],
        'Science',
      );
      expect(
        (await store.mobileRecords('schoolCalendar')).single['title'],
        'Staff meeting',
      );
      expect(
        (await store.mobileRecords('teacherSubstitutions')).single['status'],
        'assigned',
      );
      expect(
        (await store.queuedCommands()).map((row) => row['operation_id']),
        containsAll([markOperationId, requestOperationId]),
      );

      await OfflineSyncStore.closeForRestart();
      store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'parent_8',
      );
      expect(
        await store.students(),
        isEmpty,
        reason: 'another account on this device must not see the teacher cache',
      );
      expect(await store.mobileRecords('timetable'), isEmpty);
    },
  );

  test(
    'teacher leave requests change from local queued to Hub decision state',
    () async {
      final schoolId = 'leave_${DateTime.now().microsecondsSinceEpoch}';
      var store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'teacher_7',
        userId: 7,
        deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      );
      const acceptedLocalId = 'local-leave-accepted';
      const rejectedLocalId = 'local-leave-rejected';
      final acceptedOperation = await store.queueCommand(
        schoolId: schoolId,
        deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        userId: 7,
        entityType: 'staff_leave_request',
        entityId: acceptedLocalId,
        operation: 'staff_leave.submit',
        payload: {
          'startsOn': '2026-11-03',
          'endsOn': '2026-11-04',
          'reason': 'Family appointment',
        },
      );
      final rejectedOperation = await store.queueCommand(
        schoolId: schoolId,
        deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        userId: 7,
        entityType: 'staff_leave_request',
        entityId: rejectedLocalId,
        operation: 'staff_leave.submit',
        payload: {
          'startsOn': '2026-12-03',
          'endsOn': '2026-12-04',
          'reason': 'Medical appointment',
        },
      );
      await store.saveMobileRecord('staffLeaveRequests', {
        'id': acceptedLocalId,
        'startsOn': '2026-11-03',
        'endsOn': '2026-11-04',
        'reason': 'Family appointment',
        'status': 'queued',
      });
      await store.saveMobileRecord('staffLeaveRequests', {
        'id': rejectedLocalId,
        'startsOn': '2026-12-03',
        'endsOn': '2026-12-04',
        'reason': 'Medical appointment',
        'status': 'queued',
      });

      expect(
        await store.queuedCommands(entityType: 'staff_leave_request'),
        hasLength(2),
      );
      await OfflineSyncStore.closeForRestart();
      store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'teacher_7',
        userId: 7,
        deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      );
      expect(await store.mobileRecords('staffLeaveRequests'), hasLength(2));
      expect(
        await store.queuedCommands(entityType: 'staff_leave_request'),
        hasLength(2),
      );

      await store.applyCommandResults([
        {
          'operationId': acceptedOperation,
          'status': 'accepted',
          'record': {
            'id': 41,
            'staffId': 7,
            'startsOn': '2026-11-03',
            'endsOn': '2026-11-04',
            'reason': 'Family appointment',
            'status': 'pending',
            'resolutionNote': '',
          },
        },
        {
          'operationId': rejectedOperation,
          'status': 'rejected',
          'message': 'This account has no active staff profile.',
        },
      ]);

      expect(
        await store.mobileRecord('staffLeaveRequests', acceptedLocalId),
        isNull,
      );
      expect(
        (await store.mobileRecord('staffLeaveRequests', '41'))?['status'],
        'pending',
      );
      expect(
        (await store.mobileRecord(
          'staffLeaveRequests',
          rejectedLocalId,
        ))?['status'],
        'rejected',
      );
      expect(
        (await store.mobileRecord(
          'staffLeaveRequests',
          rejectedLocalId,
        ))?['resolutionNote'],
        'This account has no active staff profile.',
      );
    },
  );

  test(
    'hosted parent data and queued requests remain account-isolated after restart',
    () async {
      final schoolId = 'hosted_${DateTime.now().microsecondsSinceEpoch}';
      var store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'parent_18',
        userId: 18,
        deviceId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      );
      await store.replaceHostedParentCache(
        children: [
          {
            'studentPublicId': '018f7e5a-72b4-7ca2-9c2d-112233445577',
            'projectedAt': '2026-10-20T12:00:00Z',
            'snapshot': {
              'student': {'fullName': 'Linked Child'},
            },
          },
        ],
        commands: [],
      );
      await store.queueHostedParentCommand({
        'operationId': '018f7e5a-72b4-7ca2-9c2d-112233445588',
        'studentPublicId': '018f7e5a-72b4-7ca2-9c2d-112233445577',
        'requestType': 'leave',
        'message': 'Offline request',
      });
      await OfflineSyncStore.closeForRestart();

      store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'parent_18',
        userId: 18,
        deviceId: 'cccccccc-cccc-4ccc-8ccc-cccccccccccc',
      );
      final cache = await store.readHostedParentCache();
      expect(
        (cache!['children'] as List).single['snapshot']['student']['fullName'],
        'Linked Child',
      );
      expect(
        (await store.pendingHostedParentCommands()).single['message'],
        'Offline request',
      );
      await OfflineSyncStore.closeForRestart();

      store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'parent_19',
        userId: 19,
        deviceId: 'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
      );
      expect(await store.readHostedParentCache(), isNull);
      expect(await store.pendingHostedParentCommands(), isEmpty);
    },
  );

  test(
    'legacy school cache migration keeps only this user and device pending work',
    () async {
      final schoolId = 'legacy_${DateTime.now().microsecondsSinceEpoch}';
      final deviceId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
      final root = await getDatabasesPath();
      final legacyPath = paths.join(
        root,
        'school_erp_offline_$schoolId.sqlite',
      );
      final legacy = await openDatabase(
        legacyPath,
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE cached_classes (public_id TEXT PRIMARY KEY, name TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE cached_sections (public_id TEXT PRIMARY KEY, name TEXT NOT NULL, class_public_id TEXT NOT NULL, class_name TEXT NOT NULL)',
          );
          await db.execute('''
            CREATE TABLE cached_students (
              public_id TEXT PRIMARY KEY, full_name TEXT NOT NULL, admission_no TEXT NOT NULL,
              status TEXT NOT NULL, class_name TEXT NOT NULL, section_name TEXT NOT NULL,
              section_public_id TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE cached_attendance (
              student_public_id TEXT NOT NULL, attendance_date TEXT NOT NULL,
              status TEXT NOT NULL, reason TEXT NOT NULL, revision INTEGER NOT NULL,
              updated_at TEXT NOT NULL DEFAULT '', PRIMARY KEY(student_public_id,attendance_date)
            )
          ''');
          await db.execute('''
            CREATE TABLE sync_cursors (
              direction TEXT PRIMARY KEY, cursor_value INTEGER NOT NULL DEFAULT 0,
              updated_at TEXT NOT NULL
            )
          ''');
          await db.execute('''
          CREATE TABLE sync_outbox (
            operation_id TEXT PRIMARY KEY, school_id TEXT NOT NULL, device_id TEXT NOT NULL,
            user_id INTEGER NOT NULL, entity_type TEXT NOT NULL, entity_id TEXT NOT NULL,
            operation TEXT NOT NULL, payload_schema_version INTEGER NOT NULL,
            created_at TEXT NOT NULL, base_revision INTEGER, payload_json TEXT NOT NULL,
            status TEXT NOT NULL, attempts INTEGER NOT NULL DEFAULT 0,
            next_retry_at TEXT NOT NULL, last_error TEXT NOT NULL DEFAULT ''
          )
        ''');
        },
      );
      await legacy.insert('cached_classes', {
        'public_id': 'old-class',
        'name': 'Grade 1',
      });
      await legacy.insert('cached_sections', {
        'public_id': 'old-section',
        'name': 'A',
        'class_public_id': 'old-class',
        'class_name': 'Grade 1',
      });
      await legacy.insert('cached_students', {
        'public_id': 'old-student',
        'full_name': 'Previously cached student',
        'admission_no': 'OLD-1',
        'status': 'active',
        'class_name': 'Grade 1',
        'section_name': 'A',
        'section_public_id': 'old-section',
      });
      await legacy.insert('cached_attendance', {
        'student_public_id': 'old-student',
        'attendance_date': '2026-10-20',
        'status': 'present',
        'reason': '',
        'revision': 1,
        'updated_at': '',
      });
      await legacy.insert('sync_cursors', {
        'direction': 'pull',
        'cursor_value': 12,
        'updated_at': DateTime.now().toUtc().toIso8601String(),
      });
      for (final entry in [
        ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 7, deviceId),
        ('cccccccc-cccc-4ccc-8ccc-cccccccccccc', 8, deviceId),
        (
          'dddddddd-dddd-4ddd-8ddd-dddddddddddd',
          7,
          'eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee',
        ),
      ]) {
        await legacy.insert('sync_outbox', {
          'operation_id': entry.$1,
          'school_id': schoolId,
          'device_id': entry.$3,
          'user_id': entry.$2,
          'entity_type': 'attendance',
          'entity_id': 'student:2026-10-21',
          'operation': 'attendance.mark',
          'payload_schema_version': 1,
          'created_at': DateTime.now().toUtc().toIso8601String(),
          'base_revision': null,
          'payload_json':
              '{"studentPublicId":"student","date":"2026-10-21","status":"present"}',
          'status': 'pending',
          'attempts': 0,
          'next_retry_at': DateTime.now().toUtc().toIso8601String(),
          'last_error': '',
        });
      }
      await legacy.close();

      final store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'teacher_7',
        userId: 7,
        deviceId: deviceId,
        migrateLegacySnapshot: true,
      );
      final drafts = await store.queuedAttendanceDrafts('2026-10-21');
      expect(drafts.map((row) => row['operation_id']), [
        'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
      ]);
      expect((await store.statusCounts())['pending'], 1);
      expect(
        (await store.students()).single['full_name'],
        'Previously cached student',
      );
      expect(await store.cursor('pull'), 12);
    },
  );
}

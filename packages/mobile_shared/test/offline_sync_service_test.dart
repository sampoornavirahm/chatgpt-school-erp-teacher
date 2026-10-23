import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:school_erp_mobile_shared/src/api_client.dart';
import 'package:school_erp_mobile_shared/src/offline_sync_service.dart';
import 'package:school_erp_mobile_shared/src/offline_sync_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _FakeSyncApi implements LocalSyncApi {
  Object? pullError;
  final pushedCommands = <Map<String, dynamic>>[];

  @override
  Future<Map<String, dynamic>> localSyncBootstrap() async => {
    'schoolId': 'sync-school',
    'cursor': 0,
    'classes': [],
    'sections': [],
    'students': [],
    'attendance': [],
    'mobileRecords': {
      'parentRequests': [
        {
          'id': 18,
          'studentId': 7,
          'studentName': 'Asha',
          'requestType': 'leave',
          'status': 'pending',
        },
      ],
    },
  };

  @override
  Future<Map<String, dynamic>> pullLocalSync(
    int cursor, {
    int limit = 100,
  }) async {
    if (pullError case final error?) throw error;
    return {'events': [], 'cursor': cursor, 'hasMore': false};
  }

  @override
  Future<Map<String, dynamic>> pushLocalSync(
    List<Map<String, dynamic>> operations,
  ) async => {'results': []};

  @override
  Future<Map<String, dynamic>> pushLocalCommands(
    List<Map<String, dynamic>> operations,
  ) async {
    pushedCommands.addAll(operations);
    return {
      'results': [
        for (final operation in operations)
          {
            'operationId': operation['operationId'],
            'status': 'accepted',
            'record': {
              'id': 18,
              'studentId': 7,
              'requestType': 'leave',
              'status': 'pending',
            },
          },
      ],
    };
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });
  tearDown(() async => OfflineSyncStore.closeForRestart());

  test(
    'a failed network attempt preserves queued commands and recovery delivers them',
    () async {
      final schoolId = 'service_${DateTime.now().microsecondsSinceEpoch}';
      final store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'parent_7',
      );
      final operationId = await store.queueCommand(
        schoolId: schoolId,
        deviceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        userId: 7,
        entityType: 'parent_request',
        entityId: 'local-request-1',
        operation: 'parent_request.submit',
        payload: {
          'studentId': 7,
          'requestType': 'leave',
          'message': 'Appointment',
        },
      );
      final api =
          _FakeSyncApi()
            ..pullError = const SocketException('network unavailable');
      final service = OfflineSyncService(api: api, store: store);

      expect(await service.syncNow(), contains('network unavailable'));
      expect((await store.queuedCommands()).single['status'], 'pending');

      api.pullError = null;
      expect(await service.syncNow(), isNull);
      expect(api.pushedCommands.single['operationId'], operationId);
      expect(await store.latestOperationStatus('local-request-1'), 'accepted');
      expect(
        (await store.mobileRecords('parentRequests')).single['studentName'],
        'Asha',
      );
    },
  );

  test(
    'device revocation is surfaced as an access failure for the app to sign out',
    () async {
      final schoolId = 'revoked_${DateTime.now().microsecondsSinceEpoch}';
      final store = await OfflineSyncStore.open(
        schoolId: schoolId,
        accountId: 'teacher_3',
      );
      final api =
          _FakeSyncApi()
            ..pullError = const ApiException('Device revoked', statusCode: 403);
      final service = OfflineSyncService(api: api, store: store);
      await expectLater(service.syncNow(), throwsA(isA<ApiException>()));
    },
  );
}

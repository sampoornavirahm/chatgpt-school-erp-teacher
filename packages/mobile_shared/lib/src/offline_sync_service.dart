import 'dart:convert';

import 'api_client.dart';
import 'offline_sync_store.dart';
import 'parent_feature_flags.dart';

class OfflineSyncService {
  OfflineSyncService({
    required LocalSyncApi api,
    required OfflineSyncStore store,
  }) : _api = api,
       _store = store;

  final LocalSyncApi _api;
  final OfflineSyncStore _store;
  ParentFeatureFlags parentFeatures = const ParentFeatureFlags();

  Future<void> refreshSnapshot() async {
    final snapshot = await _api.localSyncBootstrap();
    parentFeatures = ParentFeatureFlags.fromWire(snapshot['parentFeatures']);
    await _store.replaceSnapshot(snapshot);
  }

  Future<void> pullChanges() async {
    var cursor = await _store.cursor('pull');
    for (var page = 0; page < 5; page++) {
      final result = await _api.pullLocalSync(cursor);
      final events =
          result['events'] is List ? result['events'] as List : const [];
      await _store.applyEvents(events);
      cursor = _asInt(result['cursor']);
      await _store.saveCursor('pull', cursor);
      if (result['hasMore'] != true) break;
    }
  }

  Future<String?> syncNow() async {
    try {
      await pullChanges();
    } catch (error) {
      _rethrowAccessFailure(error);
      return error.toString();
    }

    final attendanceOperations = await _store.dueAttendanceOperations();
    if (attendanceOperations.isNotEmpty) {
      final envelopes = attendanceOperations.map(_asEnvelope).toList();
      try {
        final response = await _api.pushLocalSync(envelopes);
        final results =
            response['results'] is List
                ? response['results'] as List
                : const [];
        await _store.applyPushResults(results);
      } catch (error) {
        _rethrowAccessFailure(error);
        for (final operation in attendanceOperations) {
          await _store.markRetry(operation, error.toString());
        }
        return error.toString();
      }
    }

    final commands = await _store.dueCommandOperations();
    if (commands.isNotEmpty) {
      try {
        final response = await _api.pushLocalCommands(
          commands.map(_asEnvelope).toList(),
        );
        final results =
            response['results'] is List
                ? response['results'] as List
                : const [];
        await _store.applyCommandResults(results);
      } catch (error) {
        _rethrowAccessFailure(error);
        for (final operation in commands) {
          await _store.markRetry(operation, error.toString());
        }
        return error.toString();
      }
    }

    try {
      await pullChanges();
      await refreshSnapshot();
      await pullChanges();
    } catch (error) {
      _rethrowAccessFailure(error);
      return error.toString();
    }
    return null;
  }

  Map<String, dynamic> _asEnvelope(Map<String, Object?> row) => {
    'operationId': row['operation_id'],
    'schoolId': row['school_id'],
    'deviceId': row['device_id'],
    'userId': row['user_id'],
    'entityType': row['entity_type'],
    'entityId': row['entity_id'],
    'operation': row['operation'],
    'payloadSchemaVersion': row['payload_schema_version'],
    'createdAt': row['created_at'],
    'baseRevision': row['base_revision'],
    'payload': jsonDecode(row['payload_json'] as String),
  };

  static int _asInt(Object? value) =>
      value is int ? value : int.tryParse(value?.toString() ?? '') ?? 0;

  static void _rethrowAccessFailure(Object error) {
    if (error is ApiException &&
        (error.statusCode == 401 || error.statusCode == 403)) {
      throw error;
    }
  }
}

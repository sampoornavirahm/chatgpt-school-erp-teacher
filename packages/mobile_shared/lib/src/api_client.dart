import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'firebase_services.dart';

const schoolErpAppVersion = String.fromEnvironment(
  'SCHOOL_ERP_APP_VERSION',
  defaultValue: '0.1.0',
);

class ApiException implements Exception {
  const ApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

abstract interface class LocalSyncApi {
  Future<Map<String, dynamic>> localSyncBootstrap();
  Future<Map<String, dynamic>> pushLocalSync(
    List<Map<String, dynamic>> operations,
  );
  Future<Map<String, dynamic>> pushLocalCommands(
    List<Map<String, dynamic>> operations,
  );
  Future<Map<String, dynamic>> pullLocalSync(int cursor, {int limit = 100});
}

class ApiClient implements LocalSyncApi {
  ApiClient({String? baseUrl}) : _baseUrl = baseUrl;

  static const _tokenKey = 'school_erp_access_token';
  static const _fcmFidKey = 'school_erp_fcm_fid';
  static const _deviceIdKey = 'school_erp_device_id';
  static const _fingerprintKey = 'school_erp_hub_fingerprint';
  static const _cachedUserKey = 'school_erp_cached_user';
  static const _cachedSchoolIdKey = 'school_erp_cached_school_id';
  static const _storage = FlutterSecureStorage();
  String? _baseUrl;
  String? _deviceId;
  String? _platform;
  http.Client? _pinnedClient;

  String? get baseUrl => _baseUrl;
  String newOperationId() => _uuidV4();

  set baseUrl(String? value) =>
      _baseUrl = value?.replaceFirst(RegExp(r'/+$'), '');

  Future<String> deviceId() async {
    _deviceId ??= await _storage.read(key: _deviceIdKey);
    if (_deviceId == null) {
      _deviceId = _uuidV4();
      await _storage.write(key: _deviceIdKey, value: _deviceId);
    }
    return _deviceId!;
  }

  Future<void> configureLocalHub({
    required String baseUrl,
    required String fingerprint,
    required String platform,
  }) async {
    final normalizedFingerprint =
        fingerprint.replaceFirst('sha256:', '').toLowerCase();
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(normalizedFingerprint)) {
      throw const ApiException(
        'The Hub certificate fingerprint is invalid. Ask your administrator for a new pairing code.',
      );
    }
    _pinnedClient?.close();
    _baseUrl = baseUrl.replaceFirst(RegExp(r'/+$'), '');
    _deviceId = await deviceId();
    _platform = platform;
    await _storage.write(
      key: _fingerprintKey,
      value: 'sha256:$normalizedFingerprint',
    );
    // With platform roots disabled every peer certificate is checked against the explicit pairing pin.
    final client = HttpClient(
      context: SecurityContext(withTrustedRoots: false),
    );
    client.badCertificateCallback =
        (certificate, host, port) =>
            sha256.convert(certificate.der).toString() == normalizedFingerprint;
    _pinnedClient = IOClient(client);
  }

  Future<void> clearLocalHubTrust() async {
    _pinnedClient?.close();
    _pinnedClient = null;
    _deviceId = null;
    _platform = null;
    await _storage.delete(key: _fingerprintKey);
  }

  Future<String?> readHubFingerprint() => _storage.read(key: _fingerprintKey);
  Future<void> saveToken(String token) =>
      _storage.write(key: _tokenKey, value: token);
  Future<String?> readToken() => _storage.read(key: _tokenKey);
  Future<void> clearToken() => _storage.delete(key: _tokenKey);
  Future<void> saveFcmFid(String fid) =>
      _storage.write(key: _fcmFidKey, value: fid);
  Future<String?> readFcmFid() => _storage.read(key: _fcmFidKey);
  Future<void> clearFcmFid() => _storage.delete(key: _fcmFidKey);
  Future<void> saveCachedUser(
    Map<String, dynamic> user,
    String schoolId,
  ) async {
    await _storage.write(key: _cachedUserKey, value: jsonEncode(user));
    await _storage.write(key: _cachedSchoolIdKey, value: schoolId);
  }

  Future<Map<String, dynamic>?> readCachedUser() async {
    final value = await _storage.read(key: _cachedUserKey);
    if (value == null) return null;
    try {
      final decoded = jsonDecode(value);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  Future<String?> readCachedSchoolId() =>
      _storage.read(key: _cachedSchoolIdKey);
  Future<void> clearCachedIdentity() async {
    await _storage.delete(key: _cachedUserKey);
    await _storage.delete(key: _cachedSchoolIdKey);
  }

  Future<Map<String, dynamic>> setupStatus() => _send('GET', '/setup/status');
  Future<Map<String, dynamic>> completeSetup(Map<String, Object?> payload) =>
      _send('POST', '/setup/complete', body: payload);
  Future<Map<String, dynamic>> activateSetup({
    required String googleIdToken,
    required String activationCode,
  }) => _send(
    'POST',
    '/setup/activate',
    body: {'google_id_token': googleIdToken, 'activation_code': activationCode},
  );

  Future<Map<String, dynamic>> login({
    required String email,
    required String password,
    required String role,
    String? schoolId,
  }) => _send(
    'POST',
    '/auth/login',
    body: {
      'email': email,
      'password': password,
      'role': role,
      if (schoolId?.isNotEmpty == true) 'school_id': schoolId,
      'device_name': 'school-erp-mobile',
    },
  );

  Future<Map<String, dynamic>> loginWithGoogle({
    required String email,
    required String phone,
    required String role,
    required String googleIdToken,
    String? schoolId,
  }) => _send(
    'POST',
    '/auth/google-login',
    body: {
      'email': email,
      'phone': phone,
      'role': role,
      'google_id_token': googleIdToken,
      if (schoolId?.isNotEmpty == true) 'school_id': schoolId,
      'device_name': 'school-erp-mobile',
    },
  );

  Future<Map<String, dynamic>> appUpdate({
    required String app,
    required String platform,
    required String version,
  }) =>
      _send('GET', '/app-updates?app=$app&platform=$platform&version=$version');

  Future<Map<String, dynamic>> loginToLocalHub({
    required String username,
    required String password,
  }) => _send(
    'POST',
    '/auth/login',
    body: {'username': username, 'password': password},
  );

  Future<Map<String, dynamic>> redeemPairingCode(String code) async => _send(
    'POST',
    '/pairing/redeem',
    body: {
      'pairingCode': code,
      'deviceId': await deviceId(),
      'displayName': 'School ERP ${_platform ?? 'mobile'}',
      'platform': _platform ?? 'android',
      'appVersion': schoolErpAppVersion,
    },
  );

  Future<Map<String, dynamic>> localSyncBootstrap() =>
      _send('GET', '/sync/bootstrap', authenticated: true);
  Future<Map<String, dynamic>> pushLocalSync(
    List<Map<String, dynamic>> operations,
  ) => _send(
    'POST',
    '/sync/push',
    body: {'operations': operations},
    authenticated: true,
  );
  Future<Map<String, dynamic>> pushLocalCommands(
    List<Map<String, dynamic>> operations,
  ) => _send(
    'POST',
    '/sync/commands',
    body: {'operations': operations},
    authenticated: true,
  );
  Future<Map<String, dynamic>> pullLocalSync(int cursor, {int limit = 100}) =>
      _send(
        'GET',
        '/sync/pull?cursor=$cursor&limit=$limit',
        authenticated: true,
      );

  Future<Map<String, dynamic>> currentUser() =>
      _send('GET', '/auth/me', authenticated: true);
  Future<Map<String, dynamic>> hostedParentChildren() =>
      _send('GET', '/parent/children', authenticated: true);
  Future<Map<String, dynamic>> hostedParentCommands() =>
      _send('GET', '/parent/commands', authenticated: true);
  Future<Map<String, dynamic>> submitHostedParentRequest({
    required String operationId,
    required String studentPublicId,
    required String requestType,
    required String message,
    String? startsOn,
    String? endsOn,
  }) => _send(
    'POST',
    '/parent/commands',
    body: {
      'operation_id': operationId,
      'student_public_id': studentPublicId,
      'operation': 'parent_request.submit',
      'payload': {
        'request_type': requestType,
        'starts_on': startsOn,
        'ends_on': endsOn,
        'message': message,
      },
    },
    authenticated: true,
  );
  Future<void> logout() async =>
      _send('POST', '/auth/logout', authenticated: true);

  Future<void> registerFcmInstallation(String fid, String platform) async {
    await _send(
      'POST',
      '/devices/fcm-token',
      body: {'fid': fid, 'platform': platform},
      authenticated: true,
    );
  }

  Future<void> revokeFcmInstallation(String fid) async {
    await _send(
      'DELETE',
      '/devices/fcm-token',
      body: {'fid': fid},
      authenticated: true,
    );
  }

  Future<Map<String, dynamic>> createUser({
    required String name,
    required String email,
    required String phone,
    required String role,
  }) => _send(
    'POST',
    '/admin/users',
    body: {'name': name, 'email': email, 'phone': phone, 'role': role},
    authenticated: true,
  );

  Future<Map<String, dynamic>> sendTestNotification() =>
      _send('POST', '/admin/notifications/test', authenticated: true);

  Future<Map<String, dynamic>> _send(
    String method,
    String path, {
    Map<String, Object?>? body,
    bool authenticated = false,
  }) async {
    final baseUrl = _baseUrl;
    if (baseUrl == null || baseUrl.isEmpty)
      throw const ApiException('Enter your school server address first.');
    final uri = Uri.parse('$baseUrl$path');
    final headers = <String, String>{'Accept': 'application/json'};
    if (body != null) headers['Content-Type'] = 'application/json';
    if (_deviceId != null) headers['x-school-erp-device-id'] = _deviceId!;
    if (_platform != null) {
      headers['x-school-erp-platform'] = _platform!;
      headers['x-school-erp-device-name'] = 'School ERP $_platform';
      headers['x-school-erp-app-version'] = schoolErpAppVersion;
    }
    if (authenticated) {
      final token = await readToken();
      if (token == null)
        throw const ApiException(
          'Your session has ended. Please sign in again.',
        );
      headers['Authorization'] = 'Bearer $token';
    }
    final trace = await FirebaseServices.startApiTrace();
    try {
      final pinned = _pinnedClient;
      final encodedBody = body == null ? null : jsonEncode(body);
      final response = switch (method) {
        'GET' => await (pinned?.get(uri, headers: headers) ??
                http.get(uri, headers: headers))
            .timeout(const Duration(seconds: 15)),
        'POST' => await (pinned?.post(
                  uri,
                  headers: headers,
                  body: encodedBody,
                ) ??
                http.post(uri, headers: headers, body: encodedBody))
            .timeout(const Duration(seconds: 15)),
        'DELETE' => await (pinned?.delete(
                  uri,
                  headers: headers,
                  body: encodedBody,
                ) ??
                http.delete(uri, headers: headers, body: encodedBody))
            .timeout(const Duration(seconds: 15)),
        _ => throw const ApiException('This request is not supported.'),
      };
      final decoded =
          response.body.isEmpty
              ? <String, dynamic>{}
              : jsonDecode(response.body);
      if (response.statusCode >= 200 &&
          response.statusCode < 300 &&
          decoded is Map<String, dynamic>)
        return decoded;
      throw ApiException(
        _safeErrorMessage(decoded, response.statusCode),
        statusCode: response.statusCode,
      );
    } on ApiException {
      rethrow;
    } catch (_) {
      throw const ApiException(
        'Could not reach the school server. Check the address and connection.',
      );
    } finally {
      await FirebaseServices.stopApiTrace(trace);
    }
  }

  String _uuidV4() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    final hex =
        bytes.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
  }

  String _safeErrorMessage(Object? decoded, int statusCode) {
    if (decoded is Map<String, dynamic>) {
      final apiError = decoded['error'];
      if (apiError is Map && apiError['message'] is String)
        return apiError['message'] as String;
      final errors = decoded['errors'];
      if (errors is Map) {
        for (final fieldErrors in errors.values) {
          if (fieldErrors is List &&
              fieldErrors.isNotEmpty &&
              fieldErrors.first is String)
            return fieldErrors.first as String;
        }
      }
    }
    return switch (statusCode) {
      401 =>
        'Your sign-in could not be verified. Check your details and try again.',
      403 => 'This account or device does not have access to this app.',
      409 => 'School setup has already been completed.',
      _ => 'The server could not complete this request. Please try again.',
    };
  }
}

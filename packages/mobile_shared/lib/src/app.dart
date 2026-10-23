import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:school_erp_mobile_shared/src/api_client.dart';
import 'package:school_erp_mobile_shared/src/firebase_services.dart';
import 'package:school_erp_mobile_shared/src/parent_biometric_service.dart';
import 'package:school_erp_mobile_shared/src/offline_sync_store.dart';
import 'package:school_erp_mobile_shared/src/parent_request_dates.dart';
import 'package:school_erp_mobile_shared/src/offline_sync_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

enum MobileRole { teacher, parent }

const _uatDistributionEnabled = bool.fromEnvironment('SCHOOL_ERP_UAT');
const _appDistributionChannel = MethodChannel('school_erp/app_distribution');

Future<void> launchSchoolErpApp({
  required MobileRole role,
  required FirebaseOptions firebaseOptions,
}) async {
  WidgetsFlutterBinding.ensureInitialized();
  final firebaseReady = await FirebaseServices.initialize(firebaseOptions);
  if (firebaseReady && _uatDistributionEnabled && Platform.isAndroid) {
    unawaited(_checkUatDistributionUpdate());
  }
  if (firebaseReady) {
    FirebaseMessaging.onBackgroundMessage(schoolErpFcmBackgroundHandler);
  }
  runApp(SchoolErpMobile(role: role));
}

Future<void> _checkUatDistributionUpdate() async {
  if (!_uatDistributionEnabled ||
      !Platform.isAndroid ||
      !FirebaseServices.ready)
    return;
  try {
    await _appDistributionChannel.invokeMethod<void>('checkForUpdate');
  } on PlatformException {
    // Keep normal app use available if the tester service is temporarily unavailable.
  } on MissingPluginException {
    // Firebase App Distribution is only included in UAT Android builds.
  }
}

@pragma('vm:entry-point')
Future<void> schoolErpFcmBackgroundHandler(RemoteMessage message) async {
  // FCM payloads carry only a generic event; fetch school details after sign-in.
  if (Firebase.apps.isEmpty) await Firebase.initializeApp();
}

extension on MobileRole {
  String get apiValue => this == MobileRole.teacher ? 'teacher' : 'parent';
  String get title => this == MobileRole.teacher ? 'Teacher' : 'Parent';
  String get welcome =>
      this == MobileRole.teacher
          ? 'Your teaching day, at a glance.'
          : 'Your child’s school day, at a glance.';
  List<String> get areas =>
      this == MobileRole.teacher
          ? ['My classes', 'Attendance', 'School messages']
          : ['My child', 'Attendance', 'School messages'];
}

class SchoolErpMobile extends StatefulWidget {
  const SchoolErpMobile({super.key, required this.role});

  final MobileRole role;

  @override
  State<SchoolErpMobile> createState() => _SchoolErpMobileState();
}

class _SchoolErpMobileState extends State<SchoolErpMobile>
    with WidgetsBindingObserver {
  static const _apiUrlKey = 'school_erp_api_url';
  static const _hubModeKey = 'school_erp_local_hub_mode';
  static const _hubSchoolIdKey = 'school_erp_hub_school_id';
  static const _parentBiometricKey = 'school_erp_parent_biometric_unlock';
  static bool _googleSignInInitialized = false;
  final _api = ApiClient();
  StreamSubscription<RemoteMessage>? _messageSubscription;
  StreamSubscription<String>? _tokenSubscription;
  bool _loading = true;
  bool _working = false;
  bool _signedIn = false;
  bool _hubMode = false;
  bool _offline = false;
  bool _legacyCacheMatchesAccount = false;
  bool _setupJustCompleted = false;
  bool _analyticsConsent = false;
  bool _biometricEnabled = false;
  bool _biometricLocked = false;
  bool _updatePromptShown = false;
  bool _updateCheckRunning = false;
  String? _dismissedUpdateKey;
  String? _error;
  String? _success;
  String? _googleIdToken;
  String? _googleEmail;
  Map<String, dynamic>? _setupStatus;
  Map<String, dynamic>? _user;
  String? _schoolId;
  List<Map<String, dynamic>> _parentChildren = [];
  List<Map<String, dynamic>> _parentCommands = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_bootstrap());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_checkForAppUpdate());
      unawaited(_checkUatDistributionUpdate());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _messageSubscription?.cancel();
    _tokenSubscription?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap({bool skipBiometric = false}) async {
    final preferences = await SharedPreferences.getInstance();
    final savedUrl = preferences.getString(_apiUrlKey);
    _hubMode = preferences.getBool(_hubModeKey) ?? false;
    _schoolId = preferences.getString(_hubSchoolIdKey);
    _analyticsConsent =
        preferences.getBool('school_erp_analytics_consent') ?? false;
    _biometricEnabled =
        widget.role == MobileRole.parent &&
        (preferences.getBool(_parentBiometricKey) ?? false);
    if (_biometricEnabled && !skipBiometric) {
      final unlocked = await _authenticateParentOnDevice();
      if (!unlocked) {
        _biometricLocked = true;
        if (mounted) setState(() => _loading = false);
        return;
      }
      _biometricLocked = false;
    }
    if (FirebaseServices.ready) {
      await FirebaseServices.setAnalyticsConsent(_analyticsConsent);
    }
    if (savedUrl != null && _hubMode) {
      _api.baseUrl = savedUrl;
      _schoolId ??= await _api.readCachedSchoolId();
      final fingerprint = await _api.readHubFingerprint();
      if (fingerprint != null) {
        try {
          await _api.configureLocalHub(
            baseUrl: savedUrl,
            fingerprint: fingerprint,
            platform: Platform.isIOS ? 'ios' : 'android',
          );
          final token = await _api.readToken();
          if (token != null) {
            try {
              final response = await _api.currentUser();
              final user = response['user'] as Map<String, dynamic>;
              if (user['role'] == widget.role.apiValue) {
                final cachedUser = await _api.readCachedUser();
                final cachedSchoolId = await _api.readCachedSchoolId();
                _legacyCacheMatchesAccount = _sameCachedAccount(
                  cachedUser,
                  cachedSchoolId,
                  user,
                  _schoolId ?? '',
                );
                _user = user;
                _signedIn = true;
                await _api.saveCachedUser(user, _schoolId ?? '');
              } else {
                await _api.clearToken();
              }
            } on ApiException catch (error) {
              final cachedUser = await _api.readCachedUser();
              if (error.statusCode == null &&
                  cachedUser != null &&
                  cachedUser['role'] == widget.role.apiValue) {
                _legacyCacheMatchesAccount = _sameCachedAccount(
                  cachedUser,
                  await _api.readCachedSchoolId(),
                  cachedUser,
                  _schoolId ?? '',
                );
                _user = cachedUser;
                _signedIn = true;
                _offline = true;
              } else {
                await _api.clearToken();
              }
            }
          }
        } on ApiException catch (error) {
          _error = error.message;
        }
      } else {
        _error =
            'This saved Hub connection has no trusted certificate. Pair again using a current code.';
      }
    } else if (savedUrl != null) {
      _api.baseUrl = savedUrl;
      try {
        await _loadServerState();
        final token = await _api.readToken();
        if (token != null && _setupStatus?['access_ready'] == true) {
          try {
            final response = await _api.currentUser();
            final user = response['user'] as Map<String, dynamic>;
            if (user['role'] == widget.role.apiValue ||
                user['role'] == 'school_admin') {
              if (user['role'] == 'parent') {
                final schoolId =
                    (user['school'] as Map?)?['id']?.toString() ?? '';
                await _api.saveCachedUser(user, schoolId);
                await _loadHostedParentData(user: user);
              }
              _user = user;
              _signedIn = true;
              _offline = false;
              if (FirebaseServices.ready &&
                  preferences.getBool('school_erp_notifications_enabled') ==
                      true) {
                unawaited(_registerNotificationsIfPermitted());
              }
            } else {
              await _api.clearToken();
            }
          } on ApiException catch (error) {
            final restored =
                error.statusCode == null
                    ? await _restoreHostedParentOffline()
                    : false;
            if (!restored) await _api.clearToken();
          }
        }
      } on ApiException catch (error) {
        final restored = await _restoreHostedParentOffline();
        if (!restored) _error = error.message;
      }
    }
    if (mounted) {
      setState(() => _loading = false);
      unawaited(_checkForAppUpdate());
    }
  }

  Future<void> _checkForAppUpdate() async {
    if (_updatePromptShown ||
        _updateCheckRunning ||
        _hubMode ||
        _api.baseUrl == null ||
        (!Platform.isAndroid && !Platform.isIOS))
      return;
    _updateCheckRunning = true;
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      final update = await _api.appUpdate(
        app: widget.role.apiValue,
        platform: Platform.isIOS ? 'ios' : 'android',
        version: packageInfo.version,
      );
      if (!mounted || update['updateAvailable'] != true) return;
      final updateKey =
          '${update['latestVersion']}:${update['minimumVersion']}:${update['required']}';
      if (_dismissedUpdateKey == updateKey) return;
      final link = Uri.tryParse(update['downloadUrl']?.toString() ?? '');
      if (link == null || link.scheme != 'https') return;
      _updatePromptShown = true;
      final required = update['required'] == true;
      await showDialog<void>(
        context: context,
        barrierDismissible: !required,
        builder:
            (dialogContext) => AlertDialog(
              title: Text(required ? 'Update required' : 'Update available'),
              content: Text(
                [
                  'Version ${update['latestVersion']} is available.',
                  if ((update['releaseNotes']?.toString() ?? '').isNotEmpty)
                    update['releaseNotes'].toString(),
                  if (required) 'Update this app to continue.',
                ].join('\n\n'),
              ),
              actions: [
                if (!required)
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('Later'),
                  ),
                FilledButton(
                  onPressed: () async {
                    final opened = await launchUrl(
                      link,
                      mode: LaunchMode.externalApplication,
                    );
                    if (dialogContext.mounted && opened && !required)
                      Navigator.pop(dialogContext);
                  },
                  child: const Text('Get update'),
                ),
              ],
            ),
      );
      if (!required) {
        _dismissedUpdateKey = updateKey;
        _updatePromptShown = false;
      }
    } catch (_) {
      // Update checks are best effort; sign-in and offline school access remain available.
    } finally {
      _updateCheckRunning = false;
    }
  }

  Future<bool> _authenticateParentOnDevice() =>
      ParentBiometricService(
        PlatformParentBiometricAdapter(),
      ).unlockOnThisDevice();

  Future<void> _setParentBiometricUnlock(bool enabled) async {
    final preferences = await SharedPreferences.getInstance();
    if (!enabled) {
      await preferences.setBool(_parentBiometricKey, false);
      if (mounted) setState(() => _biometricEnabled = false);
      return;
    }
    final biometrics = ParentBiometricService(PlatformParentBiometricAdapter());
    if (!await biometrics.isAvailable) {
      if (mounted) {
        setState(
          () =>
              _error =
                  'Set up a fingerprint or face unlock in your phone settings first.',
        );
      }
      return;
    }
    if (!await biometrics.enableOnThisDevice()) {
      if (mounted)
        setState(() => _error = 'Biometric check was not completed.');
      return;
    }
    await preferences.setBool(_parentBiometricKey, true);
    if (mounted) {
      setState(() {
        _biometricEnabled = true;
        _error = null;
        _success = 'Biometric unlock is enabled on this phone.';
      });
    }
  }

  Future<void> _retryParentBiometricUnlock() async {
    setState(() => _working = true);
    final unlocked = await _authenticateParentOnDevice();
    if (!mounted) return;
    if (!unlocked) {
      setState(() {
        _working = false;
        _error =
            'Biometric check was not completed. Try again or use password sign-in.';
      });
      return;
    }
    setState(() {
      _biometricLocked = false;
      _loading = true;
      _working = false;
      _error = null;
    });
    await _bootstrap(skipBiometric: true);
  }

  Future<void> _useParentPasswordInstead() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool(_parentBiometricKey, false);
    await _api.clearToken();
    await _api.clearCachedIdentity();
    _parentChildren = [];
    _parentCommands = [];
    if (!mounted) return;
    setState(() {
      _biometricEnabled = false;
      _biometricLocked = false;
      _user = null;
      _signedIn = false;
      _loading = true;
      _error = null;
    });
    await _bootstrap(skipBiometric: true);
  }

  Future<void> _loadServerState() async {
    _setupStatus = await _api.setupStatus();
  }

  Future<void> _connectServer(String value) async {
    final normalized = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final uri = Uri.tryParse(normalized);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.hasQuery ||
        uri.hasFragment ||
        !(uri.scheme == 'https' || _isLoopback(uri.host))) {
      setState(
        () =>
            _error =
                'Enter the full HTTPS server address ending in /api/v1. HTTP is allowed only for localhost testing.',
      );
      return;
    }
    if (!uri.path.endsWith('/api/v1')) {
      setState(() => _error = 'The server address must end in /api/v1.');
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    _api.baseUrl = normalized;
    try {
      await _loadServerState();
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_apiUrlKey, normalized);
      await preferences.setBool(_hubModeKey, false);
      _hubMode = false;
      setState(() {
        _error = null;
        _success = null;
      });
    } on ApiException catch (error) {
      _api.baseUrl = null;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _pairWithCode(String value) async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      final code = value.trim();
      if (!code.startsWith('PAIR1.'))
        throw const ApiException(
          'Paste the one-time pairing code from the school administrator.',
        );
      final normalized = base64Url.normalize(code.substring(6));
      final decoded = jsonDecode(utf8.decode(base64Url.decode(normalized)));
      if (decoded is! Map<String, dynamic>)
        throw const ApiException('The pairing code could not be read.');
      final hubUrl = decoded['hubUrl']?.toString() ?? '';
      final fingerprint = decoded['certificateFingerprint']?.toString() ?? '';
      final schoolId = decoded['schoolId']?.toString() ?? '';
      final expiresAt = DateTime.tryParse(
        decoded['expiresAt']?.toString() ?? '',
      );
      final uri = Uri.tryParse(hubUrl);
      if (uri == null ||
          uri.scheme != 'https' ||
          !uri.path.endsWith('/api/v1') ||
          !RegExp(r'^sha256:[a-f0-9]{64}$').hasMatch(fingerprint) ||
          schoolId.isEmpty ||
          expiresAt == null ||
          !expiresAt.isAfter(DateTime.now().toUtc())) {
        throw const ApiException(
          'This pairing code is invalid or expired. Ask the school administrator for a new one.',
        );
      }
      await _api.configureLocalHub(
        baseUrl: hubUrl,
        fingerprint: fingerprint,
        platform: Platform.isIOS ? 'ios' : 'android',
      );
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(_apiUrlKey, hubUrl);
      await preferences.setString(_hubSchoolIdKey, schoolId);
      await preferences.setBool(_hubModeKey, true);
      await _api.clearToken();
      await _api.clearCachedIdentity();
      final paired = await _api.redeemPairingCode(code);
      if (paired['paired'] != true)
        throw const ApiException(
          'The Hub did not confirm this device pairing.',
        );
      setState(() {
        _hubMode = true;
        _schoolId = schoolId;
        _setupStatus = null;
        _signedIn = false;
        _user = null;
        _success =
            'This device is paired with the school Hub. Sign in with the account created by your school.';
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } on FormatException {
      setState(
        () =>
            _error =
                'The pairing code could not be read. Copy it again and try once more.',
      );
    } catch (_) {
      setState(
        () =>
            _error =
                'Pairing failed. Check that you are on the school Wi-Fi and request a new code.',
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _signInToLocalHub(Map<String, String> values) async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      final response = await _api.loginToLocalHub(
        username: values['username']!,
        password: values['password']!,
      );
      final user = response['user'] as Map<String, dynamic>;
      if (user['role'] != widget.role.apiValue) {
        await _api.clearToken();
        throw ApiException(
          'This account is not a ${widget.role.title.toLowerCase()} account. Ask your administrator to check its role.',
        );
      }
      await _api.saveToken(response['token'] as String);
      final schoolId = _schoolId ?? await _api.readCachedSchoolId() ?? '';
      _legacyCacheMatchesAccount = _sameCachedAccount(
        await _api.readCachedUser(),
        await _api.readCachedSchoolId(),
        user,
        schoolId,
      );
      await _api.saveCachedUser(user, schoolId);
      _offline = false;
      setState(() {
        _user = user;
        _schoolId = schoolId;
        _signedIn = true;
        _success =
            _offline
                ? 'Signed in. Showing saved school data while the Hub is offline.'
                : null;
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  bool _sameCachedAccount(
    Map<String, dynamic>? cachedUser,
    String? cachedSchoolId,
    Map<String, dynamic> activeUser,
    String activeSchoolId,
  ) =>
      cachedUser?['id'] == activeUser['id'] &&
      cachedUser?['role'] == activeUser['role'] &&
      cachedSchoolId == activeSchoolId;

  bool _isLoopback(String host) =>
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host == '10.0.2.2';

  Future<void> _changeServer() async {
    if (_hubMode && _schoolId != null) {
      final store = await OfflineSyncStore.open(
        schoolId: _schoolId,
        accountId: '${widget.role.apiValue}_${_user?['id'] ?? 'unknown'}',
        userId: _user?['id'] as int?,
        deviceId: await _api.deviceId(),
      );
      try {
        await store.clearIfNoPendingChanges();
      } on StateError {
        if (mounted) {
          setState(
            () =>
                _error =
                    'Sync or resolve queued changes before changing schools.',
          );
        }
        return;
      }
    }
    if (!_hubMode) await _unregisterFcmDevice();
    try {
      await _api.logout();
    } catch (_) {
      // Clear the local credential even when the server cannot be reached.
    }
    await _api.clearToken();
    await _api.clearCachedIdentity();
    if (_hubMode) await _api.clearLocalHubTrust();
    final preferences = await SharedPreferences.getInstance();
    await preferences.remove(_apiUrlKey);
    await preferences.remove(_hubModeKey);
    await preferences.remove(_hubSchoolIdKey);
    setState(() {
      _signedIn = false;
      _hubMode = false;
      _offline = false;
      _schoolId = null;
      _user = null;
      _setupStatus = null;
      _api.baseUrl = null;
      _error = null;
      _success = null;
    });
  }

  Future<void> _attachGoogle() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final idToken = await _requestGoogleIdToken();
      setState(() {
        _googleIdToken = idToken;
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(
        () =>
            _error =
                'Google sign-in could not be completed. Check the platform OAuth configuration and try again.',
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<String> _requestGoogleIdToken() async {
    const serverClientId = String.fromEnvironment('GOOGLE_SERVER_CLIENT_ID');
    const clientId = String.fromEnvironment('GOOGLE_CLIENT_ID');
    final signIn = GoogleSignIn.instance;
    if (!_googleSignInInitialized) {
      await signIn.initialize(
        clientId: clientId.isEmpty ? null : clientId,
        serverClientId: serverClientId.isEmpty ? null : serverClientId,
      );
      _googleSignInInitialized = true;
    }
    if (!signIn.supportsAuthenticate()) {
      throw const ApiException(
        'Google sign-in is not available on this device configuration yet.',
      );
    }
    final account = await signIn.authenticate();
    final idToken = account.authentication.idToken;
    if (idToken == null || idToken.isEmpty) {
      throw const ApiException(
        'Google did not return an identity token. Check the Google app configuration.',
      );
    }
    _googleEmail = account.email;
    return idToken;
  }

  Future<void> _completeSetup(Map<String, String> values) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final response = await _api.completeSetup({
        'school_name': values['school_name'],
        'admin_name': values['admin_name'],
        'email': values['email'],
        'password': values['password'],
        if (_googleIdToken != null) 'google_id_token': _googleIdToken,
        if (values['activation_code']?.isNotEmpty == true)
          'activation_code': values['activation_code'],
      });
      await _api.saveToken(response['token'] as String);
      await _loadServerState();
      setState(() {
        _setupJustCompleted = true;
        _user = response['user'] as Map<String, dynamic>;
        _signedIn = true;
        _googleIdToken = null;
        _success =
            _setupStatus?['trial_enabled'] == true
                ? 'School setup is complete. Trial access is active; Google account and server activation checks were bypassed.'
                : 'School setup is complete and the required account and server checks passed.';
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _activateSchool(String activationCode) async {
    final identityToken = _googleIdToken;
    if (identityToken == null) {
      setState(
        () =>
            _error =
                'Attach the Google account used for the initial school setup first.',
      );
      return;
    }
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      await _api.activateSetup(
        googleIdToken: identityToken,
        activationCode: activationCode.trim(),
      );
      await _loadServerState();
      setState(() {
        _googleIdToken = null;
        _success =
            'Google account and server activation are verified. Sign in to continue.';
      });
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _signIn(Map<String, String> values) async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      final role = values['role'] ?? widget.role.apiValue;
      final googleIdToken =
          role == 'school_admin' ? null : await _requestGoogleIdToken();
      var response =
          role == 'school_admin'
              ? await _api.login(
                email: values['email']!,
                password: values['password']!,
                role: role,
                schoolId: values['schoolId'],
              )
              : await _api.loginWithGoogle(
                email: values['email']!,
                phone: values['phone']!,
                role: role,
                googleIdToken: googleIdToken!,
                schoolId: values['schoolId'],
              );
      if (response['requiresSchoolSelection'] == true) {
        final selectedSchoolId = await _chooseSchool(response['schools']);
        if (selectedSchoolId == null) {
          throw const ApiException('Select a school to finish signing in.');
        }
        response = await _api.loginWithGoogle(
          email: values['email']!,
          phone: values['phone']!,
          role: role,
          googleIdToken: googleIdToken!,
          schoolId: selectedSchoolId,
        );
      }
      await _api.saveToken(response['token'] as String);
      final user = response['user'] as Map<String, dynamic>;
      final schoolId = (user['school'] as Map?)?['id']?.toString() ?? '';
      await _api.saveCachedUser(user, schoolId);
      _schoolId = schoolId;
      if (user['role'] == 'parent') await _loadHostedParentData(user: user);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool(
        'school_erp_analytics_consent',
        _analyticsConsent,
      );
      await FirebaseServices.setAnalyticsConsent(_analyticsConsent);
      setState(() {
        _user = user;
        _signedIn = true;
        _success = null;
        _googleEmail = null;
      });
      if (FirebaseServices.ready &&
          preferences.getBool('school_erp_notifications_enabled') == true) {
        unawaited(_registerNotificationsIfPermitted());
      }
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<String?> _chooseSchool(Object? value) async {
    final schools = (value as List? ?? []).whereType<Map>().toList();
    if (schools.isEmpty || !mounted) return null;
    return showDialog<String>(
      context: context,
      builder:
          (dialogContext) => AlertDialog(
            title: const Text('Choose your school'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children:
                  schools.map((school) {
                    final id = school['id']?.toString() ?? '';
                    final name = school['name']?.toString() ?? 'School';
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.school_outlined),
                      title: Text(name),
                      onTap: () => Navigator.pop(dialogContext, id),
                    );
                  }).toList(),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
            ],
          ),
    );
  }

  Future<OfflineSyncStore> _openHostedParentStore(
    Map<String, dynamic> user,
  ) async {
    final school = user['school'] as Map?;
    final schoolId = school?['id']?.toString() ?? '';
    return OfflineSyncStore.open(
      schoolId: schoolId,
      accountId: 'parent_${user['id'] ?? 'unknown'}',
      userId: int.tryParse(user['id']?.toString() ?? ''),
      deviceId: await _api.deviceId(),
    );
  }

  Future<void> _loadHostedParentCache({
    required Map<String, dynamic> user,
  }) async {
    final store = await _openHostedParentStore(user);
    final cache = await store.readHostedParentCache();
    if (cache != null) {
      _parentChildren = _mapRows(cache['children']);
      _parentCommands = _mapRows(cache['commands']);
    }
    _parentCommands = _mergeParentCommands(
      _parentCommands,
      await store.hostedParentOutbox(),
    );
  }

  List<Map<String, dynamic>> _mapRows(Object? rows) =>
      (rows as List? ?? [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();

  List<Map<String, dynamic>> _mergeParentCommands(
    List<Map<String, dynamic>> remote,
    List<Map<String, dynamic>> local,
  ) {
    final commands = <String, Map<String, dynamic>>{
      for (final command in remote)
        if (command['operationId'] != null)
          command['operationId'].toString(): command,
    };
    for (final command in local) {
      final operationId = command['operationId']?.toString();
      if (operationId != null) commands[operationId] = command;
    }
    return commands.values.toList();
  }

  Future<bool> _restoreHostedParentOffline() async {
    final token = await _api.readToken();
    final user = await _api.readCachedUser();
    final schoolId = await _api.readCachedSchoolId();
    if (token == null || user?['role'] != 'parent' || schoolId == null) {
      return false;
    }
    _user = user;
    _schoolId = schoolId;
    _signedIn = true;
    _offline = true;
    _setupStatus = {
      'configured': true,
      'access_ready': true,
      'trial_enabled': true,
    };
    await _loadHostedParentCache(user: user!);
    _success =
        'School server is offline. Showing saved school information from your last sync.';
    return true;
  }

  Future<void> _pushHostedParentOutbox(OfflineSyncStore store) async {
    for (final command in await store.pendingHostedParentCommands()) {
      try {
        final response = await _api.submitHostedParentRequest(
          operationId: command['operationId'] as String,
          studentPublicId: command['studentPublicId'] as String,
          requestType: command['requestType'] as String,
          message: command['message'] as String,
          startsOn: command['startsOn'] as String?,
          endsOn: command['endsOn'] as String?,
        );
        await store.setHostedParentCommandStatus(
          command['operationId'] as String,
          response['status']?.toString() ?? 'queued',
        );
      } on ApiException catch (error) {
        if (error.statusCode == null) return;
        await store.setHostedParentCommandStatus(
          command['operationId'] as String,
          'rejected',
          message: error.message,
        );
      }
    }
  }

  Future<void> _loadHostedParentData({
    required Map<String, dynamic> user,
  }) async {
    final store = await _openHostedParentStore(user);
    try {
      await _pushHostedParentOutbox(store);
      final childrenResponse = await _api.hostedParentChildren();
      final commandsResponse = await _api.hostedParentCommands();
      _parentChildren = _mapRows(childrenResponse['children']);
      _parentCommands = _mergeParentCommands(
        _mapRows(commandsResponse['commands']),
        await store.hostedParentOutbox(),
      );
      await store.replaceHostedParentCache(
        children: _parentChildren,
        commands: _parentCommands,
      );
      _error = null;
      _offline = false;
    } on ApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        await _api.clearToken();
        await _api.clearCachedIdentity();
        _user = null;
        _signedIn = false;
        _offline = false;
        _parentChildren = [];
        _parentCommands = [];
        _error = error.message;
        rethrow;
      }
      await _loadHostedParentCache(user: user);
      _offline = error.statusCode == null;
      if (!_offline) _error = error.message;
    }
  }

  Future<void> _refreshHostedParentData() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      if (_user != null) await _loadHostedParentData(user: _user!);
    } on ApiException catch (error) {
      _error = error.message;
    }
    if (mounted) {
      setState(() {
        _working = false;
        if (_error == null) _success = 'School information refreshed.';
      });
    }
  }

  Future<void> _submitHostedParentRequest(Map<String, String> values) async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      final user = _user;
      if (user == null)
        throw const ApiException('Sign in again to submit a request.');
      final store = await _openHostedParentStore(user);
      final operationId = _api.newOperationId();
      await store.queueHostedParentCommand({
        'operationId': operationId,
        'studentPublicId': values['studentPublicId']!,
        'requestType': values['requestType']!,
        'message': values['message']!,
        'startsOn':
            values['startsOn']?.isEmpty == true ? null : values['startsOn'],
        'endsOn': values['endsOn']?.isEmpty == true ? null : values['endsOn'],
      });
      _parentCommands = await store.hostedParentOutbox();
      try {
        await _pushHostedParentOutbox(store);
        if (_api.baseUrl != null) await _loadHostedParentData(user: user);
      } on ApiException catch (error) {
        _offline = error.statusCode == null;
        if (!_offline) _error = error.message;
      }
      if (mounted) {
        setState(() {
          if (_error == null) {
            _success =
                _offline
                    ? 'Saved on this phone. Waiting for an internet connection to submit it.'
                    : 'Submitted. Waiting for the school Hub to sync this request.';
          }
        });
      }
    } on ApiException catch (error) {
      if (mounted) setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _enableNotifications() async {
    setState(() {
      _working = true;
      _error = null;
    });
    try {
      if (!FirebaseServices.ready) {
        throw const ApiException(
          'Firebase is not configured for this app yet. The school app can still be used after the server is connected.',
        );
      }
      final settings = await FirebaseMessaging.instance.requestPermission();
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        throw const ApiException(
          'Notifications are off in device settings. You can enable them later.',
        );
      }
      final registration = FirebaseMessaging.instance.onRegistered.first
          .timeout(const Duration(seconds: 20));
      await _registerFirebaseMessaging();
      final fid = await registration;
      await _api.saveFcmFid(fid);
      await _api.registerFcmInstallation(
        fid,
        Platform.isIOS ? 'ios' : 'android',
      );
      final preferences = await SharedPreferences.getInstance();
      await preferences.setBool('school_erp_notifications_enabled', true);
      _startMessagingListeners();
      setState(() => _success = 'Notifications are connected on this device.');
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } catch (_) {
      setState(
        () =>
            _error =
                'Notifications could not be connected. Check app permissions and Firebase setup.',
      );
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _registerNotificationsIfPermitted() async {
    try {
      final settings =
          await FirebaseMessaging.instance.getNotificationSettings();
      if (settings.authorizationStatus != AuthorizationStatus.authorized &&
          settings.authorizationStatus != AuthorizationStatus.provisional)
        return;
      _startMessagingListeners();
      await _registerFirebaseMessaging();
    } catch (_) {
      // Sign-in and school data remain available when push registration is offline.
    }
  }

  Future<void> _registerFirebaseMessaging() async {
    if (Platform.isIOS) {
      for (var attempt = 0; attempt < 10; attempt++) {
        if (await FirebaseMessaging.instance.getAPNSToken() != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    await FirebaseMessaging.instance.register();
  }

  void _startMessagingListeners() {
    _messageSubscription ??= FirebaseMessaging.onMessage.listen((_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('You have a new school update.')),
      );
    });
    _tokenSubscription ??= FirebaseMessaging.instance.onRegistered.listen(
      _registerFcmInstallation,
    );
  }

  Future<void> _registerFcmInstallation(String fid) async {
    try {
      await _api.saveFcmFid(fid);
      await _api.registerFcmInstallation(
        fid,
        Platform.isIOS ? 'ios' : 'android',
      );
    } catch (_) {
      // The current token will be registered the next time the user enables push.
    }
  }

  Future<void> _signOut() async {
    if (!_hubMode) await _unregisterFcmDevice();
    try {
      await _api.logout();
    } catch (_) {
      // Clear local credentials even if the server is offline.
    }
    await _api.clearToken();
    if (mounted)
      setState(() {
        _signedIn = false;
        _user = null;
        _error = null;
      });
  }

  Future<void> _unregisterFcmDevice() async {
    try {
      final fid = await _api.readFcmFid();
      if (fid != null) await _api.revokeFcmInstallation(fid);
      await _api.clearFcmFid();
    } catch (_) {
      // Revocation can be retried by the school administrator if this device is offline.
    }
    if (FirebaseServices.ready) {
      try {
        await FirebaseMessaging.instance.unregister();
      } catch (_) {
        // The server record is already revoked; local notification cleanup can be retried.
      }
    }
    await _messageSubscription?.cancel();
    await _tokenSubscription?.cancel();
    _messageSubscription = null;
    _tokenSubscription = null;
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('school_erp_notifications_enabled', false);
  }

  Future<void> _saveConsent(bool value) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setBool('school_erp_analytics_consent', value);
    await FirebaseServices.setAnalyticsConsent(value);
    if (mounted) setState(() => _analyticsConsent = value);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'School ERP ${widget.role.title}',
      debugShowCheckedModeBanner: false,
      theme: _theme,
      home: Scaffold(
        body: DecoratedBox(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xfff2f6fc), Color(0xffe6edf6)],
            ),
          ),
          child: SafeArea(
            child:
                _loading
                    ? const Center(child: CircularProgressIndicator())
                    : _buildBody(),
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_biometricLocked) {
      return _BiometricUnlockView(
        working: _working,
        error: _error,
        onUnlock: _retryParentBiometricUnlock,
        onUsePassword: _useParentPasswordInstead,
      );
    }
    if (_api.baseUrl == null) {
      return _ServerAddressView(
        role: widget.role,
        error: _error,
        working: _working,
        onConnect: _connectServer,
        onPairCode: _pairWithCode,
      );
    }
    if (_hubMode) {
      if (_signedIn && _user != null) {
        return _HubWorkspace(
          role: widget.role,
          user: _user!,
          schoolId: _schoolId ?? '',
          api: _api,
          offlineAtLaunch: _offline,
          migrateLegacySnapshot: _legacyCacheMatchesAccount,
          biometricEnabled: _biometricEnabled,
          onBiometricChanged: _setParentBiometricUnlock,
          onSignOut: _signOut,
          onChangeServer: _changeServer,
        );
      }
      return _HubLoginView(
        role: widget.role,
        error: _error,
        success: _success,
        working: _working,
        onSubmit: _signInToLocalHub,
        onChangeServer: _changeServer,
      );
    }
    if (_setupStatus?['configured'] != true) {
      return _SetupView(
        role: widget.role,
        trialEnabled: _setupStatus?['trial_enabled'] == true,
        googleEmail: _googleEmail,
        error: _error,
        success: _success,
        working: _working,
        consent: _analyticsConsent,
        onConsentChanged: _saveConsent,
        onAttachGoogle: _attachGoogle,
        onSubmit: _completeSetup,
        onChangeServer: _changeServer,
      );
    }
    if (_setupStatus?['access_ready'] != true) {
      return _GateView(
        role: widget.role,
        reason:
            'The school server is waiting for verified Google account and server activation setup.',
        googleEmail: _googleEmail,
        error: _error,
        success: _success,
        working: _working,
        onAttachGoogle: _attachGoogle,
        onActivate: _activateSchool,
        onRefresh: _refresh,
        onChangeServer: _changeServer,
      );
    }
    if (_signedIn && _user != null) {
      if (_user!['role'] == 'school_admin') {
        return _AdminView(
          role: widget.role,
          user: _user!,
          error: _error,
          success: _success,
          working: _working,
          onCreateUser: _createUser,
          onTestNotification: _sendTestNotification,
          onSignOut: _signOut,
          onChangeServer: _changeServer,
        );
      }
      return _HomeView(
        role: widget.role,
        user: _user!,
        hostedParent: !_hubMode && _user!['role'] == 'parent',
        parentChildren: _parentChildren,
        parentCommands: _parentCommands,
        analyticsConsent: _analyticsConsent,
        success: _success,
        error: _error,
        working: _working,
        showWelcomeCard: FirebaseServices.showWelcomeCard,
        onEnableNotifications: _enableNotifications,
        onConsentChanged: _saveConsent,
        onRefreshHostedParent: _refreshHostedParentData,
        onSubmitHostedParentRequest: _submitHostedParentRequest,
        onSignOut: _signOut,
        onChangeServer: _changeServer,
        biometricEnabled: _biometricEnabled,
        onBiometricChanged: _setParentBiometricUnlock,
      );
    }
    return _LoginView(
      role: widget.role,
      setupJustCompleted: _setupJustCompleted,
      error: _error,
      success: _success,
      working: _working,
      consent: _analyticsConsent,
      firebaseReady: FirebaseServices.ready,
      serverUrl: _api.baseUrl!,
      onConsentChanged: _saveConsent,
      onSubmit: _signIn,
      onChangeServer: _changeServer,
    );
  }

  Future<void> _refresh() async {
    setState(() => _working = true);
    try {
      await _loadServerState();
      setState(() => _error = null);
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _createUser(Map<String, String> values) async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      final user = await _api.createUser(
        name: values['name']!,
        email: values['email']!,
        phone: values['phone']!,
        role: values['role']!,
      );
      setState(
        () =>
            _success =
                '${user['role']} account created for ${user['email']}. They sign in with this Google account and their registered phone number.',
      );
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _sendTestNotification() async {
    setState(() {
      _working = true;
      _error = null;
      _success = null;
    });
    try {
      final result = await _api.sendTestNotification();
      setState(
        () => _success = '${result['sent'] ?? 0} test notification(s) sent.',
      );
    } on ApiException catch (error) {
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }
}

final _theme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(
    seedColor: const Color(0xff2467ed),
    brightness: Brightness.light,
  ),
  scaffoldBackgroundColor: Colors.transparent,
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xfff7f9fc),
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(13),
      borderSide: BorderSide.none,
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(13),
      borderSide: const BorderSide(color: Color(0xffe3e9f1)),
    ),
    focusedBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(13),
      borderSide: const BorderSide(color: Color(0xff2467ed), width: 1.5),
    ),
    contentPadding: const EdgeInsets.symmetric(horizontal: 15, vertical: 14),
  ),
  cardTheme: CardThemeData(
    color: Colors.white,
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
  ),
);

class _Page extends StatelessWidget {
  const _Page({required this.role, required this.child, this.footer});

  final MobileRole role;
  final Widget child;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            width > 520 ? 30 : 20,
            22,
            width > 520 ? 30 : 20,
            28,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const _Brand(),
              const SizedBox(height: 22),
              Text(
                '${role.title} app',
                style: const TextStyle(
                  color: Color(0xff607086),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 5),
              child,
              if (footer != null) ...[const SizedBox(height: 20), footer!],
            ],
          ),
        ),
      ),
    );
  }
}

class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) => Container(
    height: 76,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    decoration: BoxDecoration(
      color: const Color(0xff091a2b),
      borderRadius: BorderRadius.circular(18),
    ),
    child: Image.asset(
      'packages/school_erp_mobile_shared/assets/branding/logow.png',
      width: 156,
      fit: BoxFit.contain,
    ),
  );
}

class _ServerAddressView extends StatefulWidget {
  const _ServerAddressView({
    required this.role,
    this.error,
    required this.working,
    required this.onConnect,
    required this.onPairCode,
  });
  final MobileRole role;
  final String? error;
  final bool working;
  final ValueChanged<String> onConnect;
  final ValueChanged<String> onPairCode;

  @override
  State<_ServerAddressView> createState() => _ServerAddressViewState();
}

class _ServerAddressViewState extends State<_ServerAddressView> {
  final _controller = TextEditingController();
  final _pairCodeController = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    _pairCodeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Page(
    role: widget.role,
    child: _CardBody(
      title: 'Connect your school',
      subtitle:
          'Enter the School ERP server address provided by your school administrator.',
      error: widget.error,
      children: [
        TextField(
          controller: _controller,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'Server address',
            hintText: 'https://school.example.com/api/v1',
          ),
        ),
        const SizedBox(height: 12),
        _PrimaryButton(
          label: 'Connect securely',
          working: widget.working,
          onPressed: () => widget.onConnect(_controller.text),
        ),
        const SizedBox(height: 8),
        const Text(
          'The app checks the server before showing sign-in. Use HTTPS for school servers.',
          style: TextStyle(color: Color(0xff6b788a), fontSize: 12.5),
        ),
        const Divider(height: 30),
        const Text(
          'School Hub pairing',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 5),
        const Text(
          'For a school on the same Wi-Fi, paste the one-time code from the Hub administrator. The app verifies the Hub certificate from that code.',
          style: TextStyle(
            color: Color(0xff6b788a),
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _pairCodeController,
          minLines: 2,
          maxLines: 4,
          autocorrect: false,
          decoration: const InputDecoration(
            labelText: 'One-time pairing code',
            hintText: 'PAIR1…',
          ),
        ),
        const SizedBox(height: 10),
        _PrimaryButton(
          label: 'Pair this device',
          working: widget.working,
          onPressed: () => widget.onPairCode(_pairCodeController.text),
        ),
      ],
    ),
  );
}

class _HubLoginView extends StatefulWidget {
  const _HubLoginView({
    required this.role,
    this.error,
    this.success,
    required this.working,
    required this.onSubmit,
    required this.onChangeServer,
  });

  final MobileRole role;
  final String? error;
  final String? success;
  final bool working;
  final ValueChanged<Map<String, String>> onSubmit;
  final VoidCallback onChangeServer;

  @override
  State<_HubLoginView> createState() => _HubLoginViewState();
}

class _HubLoginViewState extends State<_HubLoginView> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Page(
    role: widget.role,
    child: _CardBody(
      title: 'Sign in to your school',
      subtitle:
          'This device is paired with the local School Hub. Use the username and password created by your school administrator.',
      error: widget.error,
      success: widget.success,
      children: [
        Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _username,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Username'),
                validator:
                    (value) =>
                        (value?.trim().isEmpty ?? true)
                            ? 'Enter your username.'
                            : null,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _password,
                obscureText: !_showPassword,
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    tooltip: _showPassword ? 'Hide password' : 'Show password',
                    onPressed:
                        () => setState(() => _showPassword = !_showPassword),
                    icon: Icon(
                      _showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                  ),
                ),
                validator:
                    (value) =>
                        (value?.isEmpty ?? true)
                            ? 'Enter your password.'
                            : null,
              ),
              const SizedBox(height: 12),
              _PrimaryButton(
                label: 'Sign in',
                working: widget.working,
                onPressed: () {
                  if (_formKey.currentState?.validate() != true) return;
                  widget.onSubmit({
                    'username': _username.text.trim(),
                    'password': _password.text,
                  });
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Your attendance drafts are saved in this device’s private app storage before they appear as queued.',
          style: TextStyle(
            color: Color(0xff6b788a),
            fontSize: 12.5,
            height: 1.4,
          ),
        ),
        TextButton(
          onPressed: widget.onChangeServer,
          child: const Text('Pair with another school'),
        ),
      ],
    ),
  );
}

class _HubWorkspace extends StatefulWidget {
  const _HubWorkspace({
    required this.role,
    required this.user,
    required this.schoolId,
    required this.api,
    required this.offlineAtLaunch,
    required this.migrateLegacySnapshot,
    required this.biometricEnabled,
    required this.onBiometricChanged,
    required this.onSignOut,
    required this.onChangeServer,
  });

  final MobileRole role;
  final Map<String, dynamic> user;
  final String schoolId;
  final ApiClient api;
  final bool offlineAtLaunch;
  final bool migrateLegacySnapshot;
  final bool biometricEnabled;
  final ValueChanged<bool> onBiometricChanged;
  final VoidCallback onSignOut;
  final VoidCallback onChangeServer;

  @override
  State<_HubWorkspace> createState() => _HubWorkspaceState();
}

class _HubWorkspaceState extends State<_HubWorkspace> {
  OfflineSyncStore? _store;
  OfflineSyncService? _syncService;
  List<Map<String, dynamic>> _timetable = [];
  List<Map<String, dynamic>> _homework = [];
  List<Map<String, dynamic>> _announcements = [];
  List<Map<String, dynamic>> _examMarks = [];
  List<Map<String, dynamic>> _feeInvoices = [];
  List<Map<String, dynamic>> _feePayments = [];
  List<Map<String, dynamic>> _parentRequests = [];
  List<Map<String, Object?>> _queuedCommands = [];
  List<Map<String, Object?>> _sections = [];
  List<Map<String, Object?>> _students = [];
  List<Map<String, Object?>> _attendance = [];
  Map<String, int> _counts = {};
  final Map<String, String> _draftStatuses = {};
  final _dateController = TextEditingController();
  String? _selectedSection;
  String? _selectedParentStudentId;
  String _activeTab = '';
  late String _date;
  bool _loading = true;
  bool _busy = false;
  bool _offline = false;
  String? _message;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    _offline = widget.offlineAtLaunch;
    _activeTab = widget.role == MobileRole.teacher ? 'Overview' : 'Children';
    final today = DateTime.now();
    _date =
        '${today.year.toString().padLeft(4, '0')}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';
    _dateController.text = _date;
    unawaited(_initialize());
    _retryTimer = Timer.periodic(const Duration(minutes: 2), (_) {
      if (mounted && !_busy) unawaited(_syncNow(showMessage: false));
    });
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    _dateController.dispose();
    super.dispose();
  }

  Future<void> _initialize() async {
    final store = await OfflineSyncStore.open(
      schoolId: widget.schoolId,
      accountId: '${widget.role.apiValue}_${widget.user['id'] ?? 'unknown'}',
      userId: widget.user['id'] as int?,
      deviceId: await widget.api.deviceId(),
      migrateLegacySnapshot: widget.migrateLegacySnapshot,
    );
    _store = store;
    _syncService = OfflineSyncService(api: widget.api, store: store);
    try {
      await _syncService!.refreshSnapshot();
      _offline = false;
    } on ApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        widget.onSignOut();
        return;
      }
      _offline = true;
    }
    await _reloadLocal();
    if (mounted) setState(() => _loading = false);
    if (!_offline && mounted) unawaited(_syncNow(showMessage: false));
  }

  Future<void> _reloadLocal() async {
    final store = _store;
    if (store == null) return;
    final sections = await store.sections();
    if (_selectedSection == null &&
        widget.role == MobileRole.teacher &&
        sections.isNotEmpty) {
      _selectedSection = sections.first['public_id']?.toString();
    }
    final attendance = await store.students(
      sectionPublicId:
          widget.role == MobileRole.teacher ? _selectedSection : null,
    );
    final marks = await store.attendanceRows();
    final queuedDrafts = await store.queuedAttendanceDrafts(_date);
    final counts = await store.statusCounts();
    final timetable = await store.mobileRecords('timetable');
    final homework = await store.mobileRecords('homework');
    final announcements = await store.mobileRecords('announcements');
    final examMarks = await store.mobileRecords('examMarks');
    final feeInvoices = await store.mobileRecords('feeInvoices');
    final feePayments = await store.mobileRecords('feePayments');
    final parentRequests = await store.mobileRecords('parentRequests');
    final queuedCommands = await store.queuedCommands();
    if (!mounted) return;
    setState(() {
      _sections = sections;
      _students = attendance;
      _attendance = marks;
      _counts = counts;
      _timetable = timetable;
      _homework = homework;
      _announcements = announcements;
      _examMarks = examMarks;
      _feeInvoices = feeInvoices;
      _feePayments = feePayments;
      _parentRequests = parentRequests;
      _queuedCommands = queuedCommands;
      for (final student in attendance) {
        final id = student['public_id']?.toString() ?? '';
        Map<String, Object?>? row;
        for (final mark in marks) {
          if (mark['student_public_id'] == id &&
              mark['attendance_date'] == _date) {
            row = mark;
            break;
          }
        }
        _draftStatuses.putIfAbsent(
          id,
          () => row?['status']?.toString() ?? 'present',
        );
      }
      for (final draft in queuedDrafts) {
        try {
          final payload =
              jsonDecode(draft['payload_json'] as String)
                  as Map<String, dynamic>;
          final id = payload['studentPublicId']?.toString();
          if (id != null)
            _draftStatuses[id] = payload['status']?.toString() ?? 'present';
        } catch (_) {
          // Ignore an unreadable older queue row and keep the last cached value.
        }
      }
    });
  }

  Future<void> _syncNow({bool showMessage = true}) async {
    final service = _syncService;
    if (service == null || _busy) return;
    setState(() {
      _busy = true;
      if (showMessage) _message = 'Syncing with the school Hub…';
    });
    try {
      final problem = await service.syncNow();
      if (problem == null) {
        _offline = false;
        _message = 'Sync complete · ${TimeOfDay.now().format(context)}';
      } else {
        _offline = true;
        if (showMessage)
          _message =
              'Offline changes stay saved on this device and will retry when the Hub is reachable.';
      }
      await _reloadLocal();
    } on ApiException catch (error) {
      if (error.statusCode == 401 || error.statusCode == 403) {
        widget.onSignOut();
        return;
      }
      _offline = true;
      if (showMessage)
        _message =
            'Offline changes stay saved on this device and will retry when the Hub is reachable.';
      await _reloadLocal();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retryFailed() async {
    await _store?.retryFailed();
    await _reloadLocal();
    await _syncNow();
  }

  Future<void> _queueAttendance(Map<String, Object?> student) async {
    final store = _store;
    if (store == null) return;
    final publicId = student['public_id']?.toString() ?? '';
    final current = await store.attendance(publicId, _date);
    final status = _draftStatuses[publicId] ?? 'present';
    var correctionReason = '';
    if (current != null && current['status'] != status) {
      final reason = await _askCorrectionReason();
      if (reason == null || reason.trim().length < 3) return;
      correctionReason = reason.trim();
    }
    final deviceId = await widget.api.deviceId();
    await store.queueAttendance(
      schoolId: widget.schoolId,
      deviceId: deviceId,
      userId: widget.user['id'] as int,
      studentPublicId: publicId,
      date: _date,
      status: status,
      baseRevision:
          current == null ? null : int.tryParse(current['revision'].toString()),
      correctionReason: correctionReason,
    );
    if (mounted)
      setState(
        () =>
            _message =
                'Attendance saved on this device and added to the sync queue.',
      );
    await _reloadLocal();
  }

  Future<String?> _askCorrectionReason() async {
    final controller = TextEditingController();
    final reason = await showDialog<String>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('Explain this correction'),
            content: TextField(
              controller: controller,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, controller.text),
                child: const Text('Save draft'),
              ),
            ],
          ),
    );
    controller.dispose();
    return reason;
  }

  String? _localAttendance(String studentId) {
    for (final row in _attendance) {
      if (row['student_public_id'] == studentId &&
          row['attendance_date'] == _date) {
        return row['status']?.toString();
      }
    }
    return null;
  }

  List<String> get _tabs =>
      widget.role == MobileRole.teacher
          ? const [
            'Overview',
            'Attendance',
            'Homework',
            'Draft marks',
            'Notices',
          ]
          : const ['Children', 'Learning', 'Fees', 'Notices', 'Requests'];

  List<Widget> _workflowTabs() => [
    SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final tab in _tabs)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ChoiceChip(
                label: Text(tab),
                selected: _activeTab == tab,
                onSelected: (_) => setState(() => _activeTab = tab),
              ),
            ),
        ],
      ),
    ),
  ];

  List<Widget> _activeWorkflow() {
    if (widget.role == MobileRole.teacher) {
      switch (_activeTab) {
        case 'Attendance':
          return _teacherAttendance();
        case 'Homework':
          return [..._homeworkCards(), ..._announcementCards()];
        case 'Draft marks':
          return _teacherMarkCards();
        case 'Notices':
          return _announcementCards(allowAcknowledge: true);
        default:
          return [..._teacherOverview(), ..._homeworkCards(limit: 3)];
      }
    }
    switch (_activeTab) {
      case 'Learning':
        return _parentLearning();
      case 'Fees':
        return _parentFees();
      case 'Notices':
        return _announcementCards(allowAcknowledge: true);
      case 'Requests':
        return _parentRequestCards();
      default:
        return _parentRecords();
    }
  }

  int get _parentNavigationIndex => switch (_activeTab) {
    'Learning' => 1,
    'Notices' => 2,
    'Fees' => 3,
    'Requests' => 4,
    _ => 0,
  };

  void _selectParentNavigation(int index) {
    const tabs = ['Children', 'Learning', 'Notices', 'Fees', 'Requests'];
    setState(() => _activeTab = tabs[index]);
  }

  List<Map<String, Object?>> get _visibleParentStudents {
    final selectedId = _selectedParentStudentId;
    if (selectedId == null) return _students;
    return _students
        .where((student) => student['public_id']?.toString() == selectedId)
        .toList();
  }

  List<Widget> _teacherOverview() => [
    _sectionHeading('Today at school'),
    if (_sections.isEmpty)
      const _InfoBanner(
        text: 'No assigned classes have been synced to this account yet.',
      ),
    ..._sections.map(
      (section) => Card(
        child: ListTile(
          leading: const Icon(Icons.groups_outlined),
          title: Text('${section['class_name']} · ${section['name']}'),
          subtitle: Text(
            '${_students.where((s) => s['section_public_id'] == section['public_id']).length} students cached',
          ),
        ),
      ),
    ),
    _sectionHeading('Timetable'),
    if (_timetable.isEmpty)
      const _InfoBanner(text: 'No timetable entries are available offline.'),
    ..._timetable
        .take(12)
        .map(
          (row) => _recordCard(
            icon: Icons.schedule_outlined,
            title:
                '${row['startTime'] ?? ''}–${row['endTime'] ?? ''} · ${row['subjectName'] ?? 'Class'}',
            subtitle:
                '${row['className'] ?? ''} · ${row['sectionName'] ?? ''} · ${row['room'] ?? 'Room not set'}',
            trailing:
                'Day ${row['weekday'] ?? '—'} · Period ${row['period'] ?? '—'}',
          ),
        ),
  ];

  List<Widget> _homeworkCards({int limit = 100}) => [
    _sectionHeading('Homework'),
    if (_homework.isEmpty)
      const _InfoBanner(
        text: 'No homework is available in the saved school data.',
      ),
    ..._homework
        .take(limit)
        .map(
          (row) => _recordCard(
            icon: Icons.menu_book_outlined,
            title: row['title']?.toString() ?? 'Homework',
            subtitle:
                '${row['subjectName'] ?? 'Classwork'} · ${row['className'] ?? ''} ${row['sectionName'] ?? ''} · Due ${row['dueDate'] ?? 'not set'}',
            trailing: row['status']?.toString(),
            detail: row['details']?.toString(),
          ),
        ),
  ];

  List<Widget> _teacherMarkCards() => [
    _sectionHeading('Draft examination marks'),
    if (_examMarks.isEmpty)
      const _InfoBanner(
        text: 'No assigned draft or published marks were returned by the Hub.',
      ),
    ..._examMarks.map((row) {
      final canEdit = row['examStatus'] == 'draft';
      return Card(
        child: ListTile(
          leading: Icon(canEdit ? Icons.edit_note : Icons.grading_outlined),
          title: Text(
            '${row['studentName'] ?? 'Student'} · ${row['subjectName'] ?? 'Subject'}',
          ),
          subtitle: Text(
            '${row['examTitle'] ?? 'Exam'} · ${row['marksAwarded'] ?? 'Not entered'} / ${row['maxMarks'] ?? '—'}${row['teacherNote'] == null || row['teacherNote'] == '' ? '' : ' · ${row['teacherNote']}'}',
          ),
          trailing:
              canEdit
                  ? const Icon(Icons.chevron_right)
                  : const Icon(Icons.lock_outline, size: 18),
          onTap: canEdit ? () => unawaited(_editMark(row)) : null,
        ),
      );
    }),
    ..._queuedCommands
        .where((row) => row['entity_type'] == 'exam_mark')
        .map(_queuedCommandCard),
    const _InfoBanner(
      text:
          'Draft marks save to this device first. The Hub checks your class assignment, mark range, exam state, and revision when sync resumes.',
    ),
  ];

  List<Widget> _announcementCards({bool allowAcknowledge = false}) => [
    _sectionHeading('School notices'),
    if (_announcements.isEmpty)
      const _InfoBanner(
        text: 'No notices are available in the saved school data.',
      ),
    ..._announcements.map((row) {
      final id = row['id']?.toString() ?? '';
      final acknowledged = row['acknowledged'] == true;
      final queued = _queuedCommands.any(
        (command) =>
            command['entity_type'] == 'announcement_ack' &&
            command['entity_id']?.toString() == id,
      );
      final permissions = widget.user['permissions'];
      final canAcknowledge =
          allowAcknowledge &&
          permissions is List &&
          permissions.contains('announcements.acknowledge');
      return Card(
        child: ListTile(
          leading: const Icon(Icons.campaign_outlined),
          title: Text(row['title']?.toString() ?? 'Notice'),
          subtitle: Text(
            '${row['publishOn'] ?? ''} · ${row['className'] ?? 'Whole school'}\n${row['body'] ?? ''}',
          ),
          isThreeLine: true,
          trailing:
              canAcknowledge && !acknowledged
                  ? IconButton(
                    tooltip:
                        queued
                            ? 'Acknowledgement queued'
                            : 'Acknowledge notice',
                    onPressed:
                        queued
                            ? null
                            : () => unawaited(
                              _queueCommand(
                                entityType: 'announcement_ack',
                                entityId: id,
                                operation: 'announcement.acknowledge',
                                payload: {'announcementId': int.tryParse(id)},
                              ),
                            ),
                    icon: Icon(queued ? Icons.schedule : Icons.done),
                  )
                  : Icon(
                    acknowledged
                        ? Icons.check_circle_outline
                        : Icons.chevron_right,
                  ),
        ),
      );
    }),
  ];

  List<Widget> _parentLearning() => [
    _sectionHeading('Attendance, homework and results'),
    ..._visibleParentStudents.map((student) {
      final studentId = student['student_id'];
      final studentPublicId = student['public_id'];
      final attendance = _attendance
          .where((row) => row['student_public_id'] == studentPublicId)
          .take(5);
      final homework = _homework
          .where(
            (row) =>
                row['sectionId']?.toString() ==
                student['section_id']?.toString(),
          )
          .take(5);
      final marks = _examMarks
          .where((row) => row['studentId']?.toString() == studentId?.toString())
          .take(8);
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                student['full_name']?.toString() ?? 'Student',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text('Attendance', style: Theme.of(context).textTheme.labelLarge),
              ...attendance.map(
                (row) => Text('${row['attendance_date']} · ${row['status']}'),
              ),
              Text('Homework', style: Theme.of(context).textTheme.labelLarge),
              ...homework.map(
                (row) => Text('${row['title']} · due ${row['dueDate'] ?? '—'}'),
              ),
              Text(
                'Published results',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              ...marks.map(
                (row) => Text(
                  '${row['examTitle']} · ${row['subjectName']}: ${row['marksAwarded'] ?? 'Not entered'} / ${row['maxMarks']}',
                ),
              ),
              if (studentId == null)
                const Text('Reconnect to refresh this linked student record.'),
            ],
          ),
        ),
      );
    }),
    if (_timetable.isNotEmpty) ...[
      _sectionHeading('Timetable'),
      ..._timetable
          .take(20)
          .map(
            (row) => _recordCard(
              icon: Icons.schedule_outlined,
              title:
                  '${row['subjectName'] ?? 'Class'} · ${row['startTime'] ?? ''}',
              subtitle:
                  '${row['className'] ?? ''} · ${row['sectionName'] ?? ''}',
              trailing: 'Day ${row['weekday'] ?? '—'}',
            ),
          ),
    ],
  ];

  List<Widget> _parentFees() => [
    _sectionHeading('Fee invoices and receipts'),
    if (_feeInvoices.isEmpty)
      const _InfoBanner(
        text: 'No fee invoices are available to this parent account.',
      ),
    ..._feeInvoices
        .where(_parentRecordMatchesSelectedStudent)
        .map(
          (row) => _recordCard(
            icon: Icons.receipt_long_outlined,
            title: '${row['feeName'] ?? 'Fee'} · ${row['period'] ?? ''}',
            subtitle:
                '${row['fullName'] ?? ''} · Due ${row['dueOn'] ?? '—'} · ${row['status'] ?? ''}',
            trailing: '₹${row['paidAmount'] ?? 0} / ₹${row['amount'] ?? 0}',
          ),
        ),
    _sectionHeading('Payments'),
    if (_feePayments.isEmpty) const Text('No recorded payments.'),
    ..._feePayments
        .where(_parentRecordMatchesSelectedStudent)
        .map(
          (row) => _recordCard(
            icon: Icons.payments_outlined,
            title: '${row['receiptNo'] ?? 'Payment'} · ${row['feeName'] ?? ''}',
            subtitle:
                '${row['fullName'] ?? ''} · ${row['paidOn'] ?? ''} · ${row['method'] ?? ''}',
            trailing: '₹${row['amount'] ?? 0} · ${row['status'] ?? ''}',
          ),
        ),
  ];

  List<Widget> _parentRequestCards() => [
    _sectionHeading('Requests'),
    Align(
      alignment: Alignment.centerRight,
      child: FilledButton.icon(
        onPressed:
            _students.isEmpty ? null : () => unawaited(_submitParentRequest()),
        icon: const Icon(Icons.add),
        label: const Text('New request'),
      ),
    ),
    if (_parentRequests.isEmpty)
      const _InfoBanner(
        text: 'Requests you submit appear here with their current status.',
      ),
    ..._parentRequests
        .where(_parentRecordMatchesSelectedStudent)
        .map(
          (row) => _recordCard(
            icon: Icons.assignment_outlined,
            title:
                '${row['requestType'] ?? 'Request'} · ${row['studentName'] ?? 'Student'}',
            subtitle:
                '${row['startsOn'] ?? ''}${row['endsOn'] == null ? '' : ' to ${row['endsOn']}'} · ${row['message'] ?? ''}',
            trailing: row['status']?.toString(),
          ),
        ),
    ..._queuedCommands
        .where((row) => row['entity_type'] == 'parent_request')
        .map(_queuedCommandCard),
  ];

  bool _parentRecordMatchesSelectedStudent(Map<String, dynamic> row) {
    final selected = _selectedParentStudentId;
    if (selected == null) return true;
    final student = _students.cast<Map<String, Object?>?>().firstWhere(
      (item) => item?['public_id']?.toString() == selected,
      orElse: () => null,
    );
    if (student == null) return false;
    final rowPublicId = row['studentPublicId']?.toString();
    if (rowPublicId != null) return rowPublicId == selected;
    final studentId = student['student_id']?.toString();
    if (row['studentId'] != null) {
      return row['studentId'].toString() == studentId;
    }
    return row['fullName']?.toString() == student['full_name']?.toString() ||
        row['studentName']?.toString() == student['full_name']?.toString();
  }

  Widget _sectionHeading(String text) => Padding(
    padding: const EdgeInsets.only(top: 8, bottom: 5),
    child: Text(
      text,
      style: const TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Color(0xff122238),
      ),
    ),
  );

  Widget _recordCard({
    required IconData icon,
    required String title,
    String? subtitle,
    String? trailing,
    String? detail,
  }) => Card(
    child: ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle:
          detail == null
              ? (subtitle == null ? null : Text(subtitle))
              : Text('${subtitle ?? ''}\n$detail'),
      isThreeLine: detail != null,
      trailing:
          trailing == null
              ? null
              : Text(trailing, style: const TextStyle(fontSize: 11)),
      onTap:
          () => showDialog<void>(
            context: context,
            builder:
                (context) => AlertDialog(
                  title: Text(title),
                  content: SingleChildScrollView(
                    child: Text(
                      [
                        if (subtitle?.trim().isNotEmpty == true)
                          subtitle!.trim(),
                        if (trailing?.trim().isNotEmpty == true)
                          trailing!.trim(),
                        if (detail?.trim().isNotEmpty == true) detail!.trim(),
                      ].join('\n\n'),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
          ),
    ),
  );

  Widget _queuedCommandCard(Map<String, Object?> row) {
    Map<String, dynamic> payload = {};
    try {
      final decoded = jsonDecode(row['payload_json']?.toString() ?? '{}');
      if (decoded is Map) payload = Map<String, dynamic>.from(decoded);
    } catch (_) {
      // Keep a damaged local draft visible with its status and operation.
    }
    final title =
        row['entity_type'] == 'parent_request'
            ? '${payload['requestType'] ?? 'Request'} · ${payload['studentName'] ?? 'Linked student'}'
            : row['entity_type'] == 'exam_mark'
            ? 'Draft mark · student ${payload['studentId'] ?? ''}'
            : row['operation']?.toString() ?? 'Queued change';
    final detail =
        payload['message'] ?? payload['teacherNote'] ?? row['last_error'] ?? '';
    return Card(
      child: ListTile(
        leading: const Icon(Icons.cloud_upload_outlined),
        title: Text(title),
        subtitle: Text('${row['status']} · $detail'),
      ),
    );
  }

  Future<void> _queueCommand({
    required String entityType,
    required String entityId,
    required String operation,
    required Map<String, dynamic> payload,
    int? baseRevision,
  }) async {
    final store = _store;
    if (store == null) return;
    await store.queueCommand(
      schoolId: widget.schoolId,
      deviceId: await widget.api.deviceId(),
      userId: widget.user['id'] as int,
      entityType: entityType,
      entityId: entityId,
      operation: operation,
      payload: payload,
      baseRevision: baseRevision,
    );
    if (mounted)
      setState(
        () => _message = 'Saved on this device and queued for the school Hub.',
      );
    await _reloadLocal();
    if (!_offline) unawaited(_syncNow(showMessage: false));
  }

  Future<void> _editMark(Map<String, dynamic> row) async {
    final marks = TextEditingController(
      text: row['marksAwarded']?.toString() ?? '',
    );
    final note = TextEditingController(
      text: row['teacherNote']?.toString() ?? '',
    );
    final save = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text('${row['studentName']} · ${row['subjectName']}'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: marks,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: 'Marks out of ${row['maxMarks']}',
                  ),
                ),
                TextField(
                  controller: note,
                  decoration: const InputDecoration(labelText: 'Teacher note'),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save draft'),
              ),
            ],
          ),
    );
    if (save == true) {
      final awarded =
          marks.text.trim().isEmpty ? null : double.tryParse(marks.text.trim());
      if (marks.text.trim().isNotEmpty &&
          (awarded == null ||
              awarded < 0 ||
              awarded > (double.tryParse('${row['maxMarks']}') ?? 0))) {
        if (mounted)
          setState(
            () => _message = 'Enter a mark within the exam subject maximum.',
          );
      } else {
        final studentId = row['studentId'] as int;
        final examId = row['examId'] as int;
        final subjectId = row['examSubjectId'] as int;
        final updated = {
          ...row,
          'marksAwarded': awarded,
          'teacherNote': note.text.trim(),
        };
        await _store?.saveMobileRecord('examMarks', updated);
        await _queueCommand(
          entityType: 'exam_mark',
          entityId: '$examId:$subjectId:$studentId',
          operation: 'exam.mark',
          payload: {
            'examId': examId,
            'examSubjectId': subjectId,
            'studentId': studentId,
            'marksAwarded': awarded,
            'teacherNote': note.text.trim(),
          },
          baseRevision:
              row['revision'] == null
                  ? null
                  : int.tryParse('${row['revision']}'),
        );
      }
    }
    marks.dispose();
    note.dispose();
  }

  Future<void> _submitParentRequest() async {
    final message = TextEditingController();
    final startsOn = TextEditingController();
    final endsOn = TextEditingController();
    final formKey = GlobalKey<FormState>();
    var studentId = int.tryParse('${_students.first['student_id']}');
    var type = 'leave';
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder:
          (context) => StatefulBuilder(
            builder:
                (context, setDialogState) => AlertDialog(
                  title: const Text('Submit a request'),
                  content: Form(
                    key: formKey,
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          DropdownButtonFormField<int>(
                            initialValue: studentId,
                            decoration: const InputDecoration(
                              labelText: 'Student',
                            ),
                            items:
                                _students
                                    .map(
                                      (student) => DropdownMenuItem(
                                        value: int.tryParse(
                                          '${student['student_id']}',
                                        ),
                                        child: Text(
                                          student['full_name']?.toString() ??
                                              'Student',
                                        ),
                                      ),
                                    )
                                    .where((item) => item.value != null)
                                    .toList(),
                            onChanged:
                                (value) =>
                                    setDialogState(() => studentId = value),
                          ),
                          DropdownButtonFormField<String>(
                            initialValue: type,
                            decoration: const InputDecoration(
                              labelText: 'Request type',
                            ),
                            items:
                                const [
                                      'leave',
                                      'profile_change',
                                      'document',
                                      'other',
                                    ]
                                    .map(
                                      (value) => DropdownMenuItem(
                                        value: value,
                                        child: Text(value.replaceAll('_', ' ')),
                                      ),
                                    )
                                    .toList(),
                            onChanged:
                                (value) => setDialogState(
                                  () => type = value ?? 'other',
                                ),
                          ),
                          TextFormField(
                            controller: startsOn,
                            decoration: const InputDecoration(
                              labelText: 'Starts on (YYYY-MM-DD, optional)',
                            ),
                            validator:
                                (value) => validateOptionalIsoDate(
                                  value,
                                  label: 'start date',
                                ),
                          ),
                          TextFormField(
                            controller: endsOn,
                            decoration: const InputDecoration(
                              labelText: 'Ends on (YYYY-MM-DD, optional)',
                            ),
                            validator:
                                (value) =>
                                    validateOptionalIsoDate(
                                      value,
                                      label: 'end date',
                                    ) ??
                                    validateOptionalRequestDateRange(
                                      startsOn: startsOn.text,
                                      endsOn: value,
                                    ),
                          ),
                          TextFormField(
                            controller: message,
                            minLines: 2,
                            maxLines: 4,
                            decoration: const InputDecoration(
                              labelText: 'Message',
                            ),
                            validator:
                                (value) =>
                                    (value?.trim().length ?? 0) < 3
                                        ? 'Enter at least 3 characters.'
                                        : null,
                          ),
                        ],
                      ),
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () {
                        if (formKey.currentState?.validate() != true) return;
                        Navigator.pop(context, {
                          'studentId': studentId,
                          'type': type,
                          'startsOn': startsOn.text.trim(),
                          'endsOn': endsOn.text.trim(),
                          'message': message.text.trim(),
                        });
                      },
                      child: const Text('Queue request'),
                    ),
                  ],
                ),
          ),
    );
    message.dispose();
    startsOn.dispose();
    endsOn.dispose();
    if (result == null) return;
    final text = result['message'] as String;
    if (result['studentId'] == null || text.length < 3) {
      if (mounted)
        setState(
          () =>
              _message =
                  'Select a linked student and enter a message of at least three characters.',
        );
      return;
    }
    final student = _students.firstWhere(
      (row) => '${row['student_id']}' == '${result['studentId']}',
    );
    await _queueCommand(
      entityType: 'parent_request',
      entityId: 'local-${DateTime.now().microsecondsSinceEpoch}',
      operation: 'parent_request.submit',
      payload: {
        'studentId': result['studentId'],
        'requestType': result['type'],
        'startsOn': result['startsOn'],
        'endsOn': result['endsOn'],
        'message': text,
        'studentName': student['full_name'],
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final pending = (_counts['pending'] ?? 0) + (_counts['failed'] ?? 0);
    final page = _Page(
      role: widget.role,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Hello, ${widget.user['displayName'] ?? widget.role.title}',
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w700,
              color: Color(0xff122238),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.role == MobileRole.teacher
                ? 'Your assigned classes and attendance'
                : 'Your linked students and attendance',
            style: const TextStyle(color: Color(0xff68778b)),
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _offline
                            ? Icons.cloud_off_outlined
                            : Icons.cloud_done_outlined,
                        color:
                            _offline
                                ? const Color(0xff9b671c)
                                : const Color(0xff26744e),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _offline
                              ? 'Offline · saved data is available'
                              : 'Connected to school Hub',
                          style: const TextStyle(fontWeight: FontWeight.w700),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Sync now',
                        onPressed: _busy ? null : () => unawaited(_syncNow()),
                        icon:
                            _busy
                                ? const SizedBox.square(
                                  dimension: 18,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                                : const Icon(Icons.sync),
                      ),
                    ],
                  ),
                  Text(
                    '${_counts['pending'] ?? 0} queued · ${_counts['accepted'] ?? 0} accepted · ${_counts['failed'] ?? 0} retryable · ${_counts['conflict'] ?? 0} conflicts · ${_counts['rejected'] ?? 0} rejected',
                    style: const TextStyle(
                      color: Color(0xff69788d),
                      fontSize: 12,
                    ),
                  ),
                  if (pending > 0)
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: _busy ? null : _retryFailed,
                        child: const Text('Retry failed changes'),
                      ),
                    ),
                  if (_message != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        _message!,
                        style: const TextStyle(
                          color: Color(0xff49627f),
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          if (widget.role == MobileRole.parent && _students.length > 1)
            DropdownButtonFormField<String?>(
              initialValue: _selectedParentStudentId,
              decoration: const InputDecoration(
                labelText: 'Showing information for',
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('All children'),
                ),
                ..._students.map(
                  (student) => DropdownMenuItem<String?>(
                    value: student['public_id']?.toString(),
                    child: Text(student['full_name']?.toString() ?? 'Student'),
                  ),
                ),
              ],
              onChanged:
                  (value) => setState(() => _selectedParentStudentId = value),
            ),
          if (widget.role == MobileRole.parent && _students.length > 1)
            const SizedBox(height: 10),
          if (widget.role == MobileRole.teacher) ..._workflowTabs(),
          const SizedBox(height: 12),
          ..._activeWorkflow(),
          const SizedBox(height: 10),
          if (widget.role == MobileRole.parent)
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('Use phone biometrics'),
              subtitle: const Text(
                'Unlock this saved session on this phone. School access is still checked by the server.',
              ),
              value: widget.biometricEnabled,
              onChanged: widget.onBiometricChanged,
            ),
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.user['username']?.toString() ?? '',
                  style: const TextStyle(
                    color: Color(0xff6c7a8e),
                    fontSize: 12,
                  ),
                ),
              ),
              TextButton(
                onPressed: widget.onSignOut,
                child: const Text('Sign out'),
              ),
            ],
          ),
          TextButton(
            onPressed: widget.onChangeServer,
            child: const Text('Pair with another school'),
          ),
        ],
      ),
    );
    if (widget.role != MobileRole.parent) return page;
    return Scaffold(
      body: page,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _parentNavigationIndex,
        onDestinationSelected: _selectParentNavigation,
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
          NavigationDestination(
            icon: Icon(Icons.menu_book_outlined),
            label: 'Learning',
          ),
          NavigationDestination(
            icon: Icon(Icons.inbox_outlined),
            label: 'Inbox',
          ),
          NavigationDestination(
            icon: Icon(Icons.payments_outlined),
            label: 'Payments',
          ),
          NavigationDestination(
            icon: Icon(Icons.explore_outlined),
            label: 'Explore',
          ),
        ],
      ),
    );
  }

  List<Widget> _teacherAttendance() {
    return [
      const Text(
        'Attendance drafts',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: Color(0xff122238),
        ),
      ),
      const SizedBox(height: 8),
      if (_sections.isNotEmpty)
        DropdownButtonFormField<String>(
          initialValue: _selectedSection,
          decoration: const InputDecoration(
            labelText: 'Assigned class and section',
          ),
          items:
              _sections
                  .map(
                    (section) => DropdownMenuItem(
                      value: section['public_id']?.toString(),
                      child: Text(
                        '${section['class_name']} · ${section['name']}',
                      ),
                    ),
                  )
                  .toList(),
          onChanged: (value) async {
            setState(() => _selectedSection = value);
            await _reloadLocal();
          },
        ),
      const SizedBox(height: 8),
      TextField(
        controller: _dateController,
        keyboardType: TextInputType.datetime,
        decoration: InputDecoration(
          labelText: 'Attendance date (YYYY-MM-DD)',
          suffixIcon: IconButton(
            icon: const Icon(Icons.check),
            onPressed: () async {
              final value = _dateController.text.trim();
              if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
                setState(() => _date = value);
                await _reloadLocal();
              }
            },
          ),
        ),
        onSubmitted: (value) async {
          if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
            setState(() => _date = value);
            await _reloadLocal();
          }
        },
      ),
      const SizedBox(height: 8),
      if (_students.isEmpty)
        const _InfoBanner(
          text:
              'No assigned students are cached yet. Connect to the school Hub while on the school network, then sync.',
        ),
      ..._students.map((student) {
        final id = student['public_id']?.toString() ?? '';
        final current = _localAttendance(id);
        return Card(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        student['full_name']?.toString() ?? '',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      Text(
                        '${student['admission_no']} · ${current ?? 'Not marked'}',
                        style: const TextStyle(
                          color: Color(0xff718095),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
                DropdownButton<String>(
                  value: _draftStatuses[id] ?? 'present',
                  items:
                      const ['present', 'absent', 'late', 'excused']
                          .map(
                            (value) => DropdownMenuItem(
                              value: value,
                              child: Text(value),
                            ),
                          )
                          .toList(),
                  onChanged: (value) {
                    if (value != null)
                      setState(() => _draftStatuses[id] = value);
                  },
                ),
                IconButton(
                  tooltip: 'Save on device',
                  onPressed: () => unawaited(_queueAttendance(student)),
                  icon: const Icon(Icons.save_outlined),
                ),
              ],
            ),
          ),
        );
      }),
      const SizedBox(height: 4),
      const Text(
        'Each change is written to the offline queue before the app reports it as saved. The app retries in the foreground when the Hub is reachable.',
        style: TextStyle(color: Color(0xff6b788a), fontSize: 12, height: 1.4),
      ),
    ];
  }

  List<Widget> _parentRecords() => [
    const Text(
      'Linked students',
      style: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w700,
        color: Color(0xff122238),
      ),
    ),
    const SizedBox(height: 8),
    if (_students.isEmpty)
      const _InfoBanner(
        text:
            'No linked student records are cached yet. Connect to the school Hub and sync to load the records shared with your account.',
      ),
    ..._students.map((student) {
      final id = student['public_id']?.toString() ?? '';
      final latest =
          _attendance
              .where((row) => row['student_public_id'] == id)
              .take(5)
              .toList();
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                student['full_name']?.toString() ?? '',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              Text(
                '${student['class_name']} · ${student['section_name']}',
                style: const TextStyle(color: Color(0xff718095), fontSize: 12),
              ),
              const Divider(height: 18),
              if (latest.isEmpty)
                const Text(
                  'No attendance is available yet.',
                  style: TextStyle(color: Color(0xff718095), fontSize: 12),
                ),
              ...latest.map(
                (row) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    '${row['attendance_date']} · ${row['status']}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }),
    const _InfoBanner(
      text:
          'Only records linked to your parent account are stored on this phone. Parent accounts can view attendance but cannot change it.',
    ),
  ];
}

class _SetupView extends StatefulWidget {
  const _SetupView({
    required this.role,
    required this.trialEnabled,
    this.googleEmail,
    this.error,
    this.success,
    required this.working,
    required this.consent,
    required this.onConsentChanged,
    required this.onAttachGoogle,
    required this.onSubmit,
    required this.onChangeServer,
  });
  final MobileRole role;
  final bool trialEnabled;
  final String? googleEmail;
  final String? error;
  final String? success;
  final bool working;
  final bool consent;
  final ValueChanged<bool> onConsentChanged;
  final VoidCallback onAttachGoogle;
  final ValueChanged<Map<String, String>> onSubmit;
  final VoidCallback onChangeServer;

  @override
  State<_SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<_SetupView> {
  final _formKey = GlobalKey<FormState>();
  final _school = TextEditingController();
  final _admin = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _activation = TextEditingController();

  @override
  void dispose() {
    _school.dispose();
    _admin.dispose();
    _email.dispose();
    _password.dispose();
    _activation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Page(
    role: widget.role,
    child: _CardBody(
      title: 'Set up this school server',
      subtitle:
          'One-time setup. The school administrator can then create teacher and parent accounts.',
      error: widget.error,
      success: widget.success,
      children: [
        _TrialBanner(enabled: widget.trialEnabled),
        const SizedBox(height: 15),
        Form(
          key: _formKey,
          child: Column(
            children: [
              TextFormField(
                controller: _school,
                decoration: const InputDecoration(labelText: 'School name'),
                validator: _required,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _admin,
                decoration: const InputDecoration(
                  labelText: 'Administrator name',
                ),
                validator: _required,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Administrator email',
                ),
                validator: _emailValidator,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Administrator password',
                  helperText: 'Use at least 12 characters',
                ),
                validator:
                    (value) =>
                        (value?.length ?? 0) < 12
                            ? 'Use at least 12 characters.'
                            : null,
              ),
              const SizedBox(height: 15),
              OutlinedButton.icon(
                onPressed: widget.working ? null : widget.onAttachGoogle,
                icon: const Icon(Icons.account_circle_outlined),
                label: Text(
                  widget.googleEmail == null
                      ? (widget.trialEnabled
                          ? 'Attach Google account (optional during trial)'
                          : 'Attach required Google account')
                      : widget.googleEmail!,
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _activation,
                decoration: InputDecoration(
                  labelText:
                      widget.trialEnabled
                          ? 'Server activation code (optional during trial)'
                          : 'Required server activation code',
                ),
              ),
              const SizedBox(height: 8),
              _ConsentRow(
                value: widget.consent,
                onChanged: widget.onConsentChanged,
              ),
              const SizedBox(height: 10),
              _PrimaryButton(
                label: 'Complete school setup',
                working: widget.working,
                onPressed: () {
                  if (_formKey.currentState?.validate() != true) return;
                  widget.onSubmit({
                    'school_name': _school.text.trim(),
                    'admin_name': _admin.text.trim(),
                    'email': _email.text.trim(),
                    'password': _password.text,
                    'activation_code': _activation.text.trim(),
                  });
                },
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: widget.onChangeServer,
                child: const Text('Use another server'),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

String? _required(String? value) =>
    (value?.trim().length ?? 0) < 2 ? 'Enter at least 2 characters.' : null;

String? _emailValidator(String? value) =>
    value != null &&
            RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$').hasMatch(value.trim())
        ? null
        : 'Enter a valid email address.';

String? _phoneValidator(String? value) {
  final digits = value?.replaceAll(RegExp(r'\D'), '') ?? '';
  return digits.length >= 8 && digits.length <= 15
      ? null
      : 'Enter the phone number registered with the school.';
}

class _LoginView extends StatefulWidget {
  const _LoginView({
    required this.role,
    required this.setupJustCompleted,
    this.error,
    this.success,
    required this.working,
    required this.consent,
    required this.firebaseReady,
    required this.serverUrl,
    required this.onConsentChanged,
    required this.onSubmit,
    required this.onChangeServer,
  });
  final MobileRole role;
  final bool setupJustCompleted;
  final String? error;
  final String? success;
  final bool working;
  final bool consent;
  final bool firebaseReady;
  final String serverUrl;
  final ValueChanged<bool> onConsentChanged;
  final ValueChanged<Map<String, String>> onSubmit;
  final VoidCallback onChangeServer;

  @override
  State<_LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<_LoginView> {
  final _formKey = GlobalKey<FormState>();
  final _schoolId = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  bool _showPassword = false;
  String _selectedRole = '';

  @override
  void initState() {
    super.initState();
    _selectedRole = widget.role.apiValue;
  }

  @override
  void dispose() {
    _schoolId.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Page(
    role: widget.role,
    child: _CardBody(
      title: 'Welcome back',
      subtitle: widget.role.welcome,
      error: widget.error,
      success: widget.success,
      children: [
        if (widget.setupJustCompleted)
          const _InfoBanner(
            text:
                'School setup is complete. Ask the administrator to create your teacher or parent sign-in.',
          ),
        const SizedBox(height: 12),
        Form(
          key: _formKey,
          child: Column(
            children: [
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: widget.role.apiValue,
                    label: Text('${widget.role.title}'),
                  ),
                  const ButtonSegment(
                    value: 'school_admin',
                    label: Text('School admin'),
                  ),
                ],
                selected: {_selectedRole},
                onSelectionChanged:
                    (value) => setState(() => _selectedRole = value.first),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _schoolId,
                decoration: const InputDecoration(
                  labelText: 'School ID (if provided)',
                  helperText: 'Required when several schools use this server.',
                ),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Google account email',
                ),
                validator: _emailValidator,
              ),
              if (_selectedRole != 'school_admin') ...[
                const SizedBox(height: 10),
                TextFormField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                    labelText: 'Phone number registered with school',
                  ),
                  validator: _phoneValidator,
                ),
              ] else ...[
                const SizedBox(height: 10),
                TextFormField(
                  controller: _password,
                  obscureText: !_showPassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    suffixIcon: IconButton(
                      tooltip:
                          _showPassword ? 'Hide password' : 'Show password',
                      onPressed:
                          () => setState(() => _showPassword = !_showPassword),
                      icon: Icon(
                        _showPassword
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                      ),
                    ),
                  ),
                  validator:
                      (value) =>
                          (value?.isEmpty ?? true)
                              ? 'Enter your password.'
                              : null,
                ),
              ],
              const SizedBox(height: 12),
              _ConsentRow(
                value: widget.consent,
                onChanged: widget.onConsentChanged,
              ),
              const SizedBox(height: 10),
              _PrimaryButton(
                label:
                    _selectedRole == 'school_admin'
                        ? 'Sign in as school admin'
                        : 'Continue with Google',
                working: widget.working,
                onPressed: () {
                  if (_formKey.currentState?.validate() != true) return;
                  widget.onSubmit({
                    'email': _email.text.trim(),
                    'phone': _phone.text.trim(),
                    'password': _password.text,
                    'role': _selectedRole,
                    'schoolId': _schoolId.text.trim(),
                  });
                },
              ),
              const SizedBox(height: 12),
              Text(
                'Server: ${Uri.parse(widget.serverUrl).host}',
                style: const TextStyle(color: Color(0xff748196), fontSize: 12),
              ),
              TextButton(
                onPressed: widget.onChangeServer,
                child: const Text('Change school server'),
              ),
            ],
          ),
        ),
      ],
    ),
    footer: Text(
      'Analytics and crash diagnostics are ${widget.consent ? 'enabled by your choice' : 'off'}. Firebase setup ${widget.firebaseReady ? 'is ready' : 'is pending'}.',
      textAlign: TextAlign.center,
      style: const TextStyle(color: Color(0xff758196), fontSize: 11.5),
    ),
  );
}

class _AdminView extends StatefulWidget {
  const _AdminView({
    required this.role,
    required this.user,
    this.error,
    this.success,
    required this.working,
    required this.onCreateUser,
    required this.onTestNotification,
    required this.onSignOut,
    required this.onChangeServer,
  });
  final MobileRole role;
  final Map<String, dynamic> user;
  final String? error;
  final String? success;
  final bool working;
  final ValueChanged<Map<String, String>> onCreateUser;
  final VoidCallback onTestNotification;
  final VoidCallback onSignOut;
  final VoidCallback onChangeServer;

  @override
  State<_AdminView> createState() => _AdminViewState();
}

class _AdminViewState extends State<_AdminView> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  String _role = 'teacher';

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Page(
    role: widget.role,
    child: _CardBody(
      title: 'School setup',
      subtitle:
          'Create the first teacher and parent sign-ins for ${widget.user['school']?['name'] ?? 'your school'}.',
      error: widget.error,
      success: widget.success,
      children: [
        Form(
          key: _formKey,
          child: Column(
            children: [
              DropdownButtonFormField<String>(
                initialValue: _role,
                decoration: const InputDecoration(labelText: 'Account type'),
                items: const [
                  DropdownMenuItem(value: 'teacher', child: Text('Teacher')),
                  DropdownMenuItem(value: 'parent', child: Text('Parent')),
                ],
                onChanged:
                    (value) => setState(() => _role = value ?? 'teacher'),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Full name'),
                validator: _required,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Google account email',
                ),
                validator: _emailValidator,
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(labelText: 'Phone number'),
                validator: _phoneValidator,
              ),
              const SizedBox(height: 14),
              _PrimaryButton(
                label:
                    'Create ${_role == 'teacher' ? 'teacher' : 'parent'} account',
                working: widget.working,
                onPressed: () {
                  if (_formKey.currentState?.validate() != true) return;
                  widget.onCreateUser({
                    'name': _name.text.trim(),
                    'email': _email.text.trim(),
                    'phone': _phone.text.trim(),
                    'role': _role,
                  });
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: widget.working ? null : widget.onTestNotification,
          icon: const Icon(Icons.notifications_active_outlined),
          label: const Text('Send generic test notification'),
        ),
        const SizedBox(height: 10),
        const Text(
          'This sign-in uses the hosted PHP service. To use records from the local school Hub, pair this phone with the school network.',
          style: TextStyle(color: Color(0xff718095), height: 1.4, fontSize: 12),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Text(
                widget.user['email']?.toString() ?? '',
                style: const TextStyle(fontSize: 12, color: Color(0xff6c7a8e)),
              ),
            ),
            TextButton(
              onPressed: widget.onSignOut,
              child: const Text('Sign out'),
            ),
          ],
        ),
        TextButton(
          onPressed: widget.onChangeServer,
          child: const Text('Change school server'),
        ),
      ],
    ),
  );
}

class _HomeView extends StatelessWidget {
  const _HomeView({
    required this.role,
    required this.user,
    required this.hostedParent,
    required this.parentChildren,
    required this.parentCommands,
    required this.analyticsConsent,
    this.success,
    this.error,
    required this.working,
    required this.showWelcomeCard,
    required this.onEnableNotifications,
    required this.onConsentChanged,
    required this.onRefreshHostedParent,
    required this.onSubmitHostedParentRequest,
    required this.onSignOut,
    required this.onChangeServer,
    required this.biometricEnabled,
    required this.onBiometricChanged,
  });
  final MobileRole role;
  final Map<String, dynamic> user;
  final bool hostedParent;
  final List<Map<String, dynamic>> parentChildren;
  final List<Map<String, dynamic>> parentCommands;
  final bool analyticsConsent;
  final String? success;
  final String? error;
  final bool working;
  final bool showWelcomeCard;
  final VoidCallback onEnableNotifications;
  final ValueChanged<bool> onConsentChanged;
  final VoidCallback onRefreshHostedParent;
  final ValueChanged<Map<String, String>> onSubmitHostedParentRequest;
  final VoidCallback onSignOut;
  final VoidCallback onChangeServer;
  final bool biometricEnabled;
  final ValueChanged<bool> onBiometricChanged;

  @override
  Widget build(BuildContext context) => _Page(
    role: role,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showWelcomeCard) ...[
          Text(
            'Hello, ${user['name'] ?? role.title}',
            style: const TextStyle(
              fontSize: 25,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: Color(0xff122238),
            ),
          ),
          const SizedBox(height: 5),
          Text(role.welcome, style: const TextStyle(color: Color(0xff68778b))),
          const SizedBox(height: 16),
        ],
        if (error != null) _MessageBanner(text: error!, error: true),
        if (success != null) _MessageBanner(text: success!, error: false),
        if (hostedParent) ...[
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use phone biometrics'),
            subtitle: const Text(
              'Unlock this saved session on this phone. School access is still checked by the server.',
            ),
            value: biometricEnabled,
            onChanged: onBiometricChanged,
          ),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: working ? null : onRefreshHostedParent,
              icon: const Icon(Icons.sync),
              label: const Text('Refresh school information'),
            ),
          ),
          if (parentChildren.isEmpty)
            const Card(
              child: Padding(
                padding: EdgeInsets.all(17),
                child: Text(
                  'No child has been linked to this account yet. Ask the school office to connect your parent account to your child.',
                  style: TextStyle(color: Color(0xff69788d), height: 1.45),
                ),
              ),
            ),
          ...parentChildren.map((child) => _hostedChildCard(context, child)),
          if (parentCommands.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'Your requests',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
            ...parentCommands.map(
              (command) => Card(
                child: ListTile(
                  leading: const Icon(Icons.outbox_outlined),
                  title: Text(
                    command['status'] == 'queued' ||
                            command['status'] == 'delivered'
                        ? 'Waiting for the school to sync'
                        : (command['message']?.toString().isNotEmpty == true
                            ? command['message'].toString()
                            : command['status'].toString()),
                  ),
                  subtitle: Text('Request ${command['operationId'] ?? ''}'),
                  trailing: Text(command['status']?.toString() ?? 'queued'),
                ),
              ),
            ),
          ],
        ] else ...[
          Card(
            child: Padding(
              padding: const EdgeInsets.all(17),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'School Hub connection',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
                  ),
                  const SizedBox(height: 7),
                  const Text(
                    'No local School Hub is paired to this phone. Pair on the school network with a one-time code from the Hub administrator.',
                    style: TextStyle(color: Color(0xff69788d), height: 1.45),
                  ),
                  const SizedBox(height: 10),
                  const Row(
                    children: [
                      Icon(
                        Icons.sync_problem_outlined,
                        size: 17,
                        color: Color(0xff9b671c),
                      ),
                      SizedBox(width: 7),
                      Text(
                        'Last synced: not connected',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                          color: Color(0xff7b5b2d),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 13),
          ...role.areas.map(
            (area) => Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Card(
                child: ListTile(
                  leading: CircleAvatar(
                    backgroundColor: const Color(0xffedf3ff),
                    child: Icon(_iconFor(area), color: const Color(0xff2467ed)),
                  ),
                  title: Text(
                    area,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Available after your school connects its Hub',
                  ),
                  trailing: const Icon(Icons.lock_outline, size: 18),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 5),
        _PrimaryButton(
          label: 'Enable notifications',
          working: working,
          icon: Icons.notifications_active_outlined,
          onPressed: onEnableNotifications,
        ),
        const SizedBox(height: 10),
        _ConsentRow(value: analyticsConsent, onChanged: onConsentChanged),
        const Divider(height: 28),
        Row(
          children: [
            Expanded(
              child: Text(
                user['email']?.toString() ?? '',
                style: const TextStyle(fontSize: 12, color: Color(0xff6c7a8e)),
              ),
            ),
            TextButton(onPressed: onSignOut, child: const Text('Sign out')),
          ],
        ),
        TextButton(
          onPressed: onChangeServer,
          child: const Text('Change school server'),
        ),
      ],
    ),
  );

  Widget _hostedChildCard(BuildContext context, Map<String, dynamic> child) {
    final snapshot = Map<String, dynamic>.from(child['snapshot'] as Map? ?? {});
    final student = Map<String, dynamic>.from(
      snapshot['student'] as Map? ?? {},
    );
    final attendance = _snapshotRows(snapshot['attendance']);
    final timetable = _snapshotRows(snapshot['timetable']);
    final homework = _snapshotRows(snapshot['homework']);
    final announcements = _snapshotRows(snapshot['announcements']);
    final results = _snapshotRows(snapshot['results']);
    final fees = _snapshotRows(snapshot['fees']);
    final projectedAt = child['projectedAt']?.toString() ?? 'unknown';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              student['fullName']?.toString() ??
                  student['name']?.toString() ??
                  'Linked child',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
            ),
            Text(
              '${student['className'] ?? ''} ${student['sectionName'] ?? ''} · ${student['admissionNo'] ?? ''}',
              style: const TextStyle(color: Color(0xff68778b)),
            ),
            const SizedBox(height: 4),
            Text(
              'Last synced ${projectedAt.replaceFirst('T', ' ').replaceFirst('Z', ' UTC')}',
              style: const TextStyle(fontSize: 11, color: Color(0xff68778b)),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 7,
              runSpacing: 7,
              children: [
                _ParentCount(label: 'Attendance', count: attendance.length),
                _ParentCount(label: 'Periods', count: timetable.length),
                _ParentCount(label: 'Homework', count: homework.length),
                _ParentCount(label: 'Results', count: results.length),
                _ParentCount(label: 'Fee records', count: fees.length),
              ],
            ),
            if (announcements.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                'School notices',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              ...announcements
                  .take(3)
                  .map(
                    (row) => Text(
                      '• ${row['title'] ?? row['message'] ?? 'School notice'}',
                      style: const TextStyle(height: 1.5),
                    ),
                  ),
            ],
            if (homework.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Homework',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              ...homework
                  .take(3)
                  .map(
                    (row) => Text(
                      '• ${row['title'] ?? 'Assignment'}${row['dueOn'] == null ? '' : ' · due ${row['dueOn']}'}',
                      style: const TextStyle(height: 1.5),
                    ),
                  ),
            ],
            if (results.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text(
                'Published results',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              ...results
                  .take(3)
                  .map(
                    (row) => Text(
                      '• ${row['examTitle'] ?? 'Exam'} · ${row['subjectName'] ?? ''} ${row['marksAwarded'] ?? ''}/${row['maxMarks'] ?? ''}',
                      style: const TextStyle(height: 1.5),
                    ),
                  ),
            ],
            if (fees.isNotEmpty) ...[
              const SizedBox(height: 10),
              const Text('Fees', style: TextStyle(fontWeight: FontWeight.w700)),
              ...fees
                  .take(3)
                  .map(
                    (row) => Text(
                      '• ${row['feeName'] ?? row['period'] ?? 'Fee'} · ${row['status'] ?? ''}',
                      style: const TextStyle(height: 1.5),
                    ),
                  ),
            ],
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed:
                  working
                      ? null
                      : () => _requestLeave(
                        context,
                        child['studentPublicId']?.toString() ?? '',
                      ),
              icon: const Icon(Icons.edit_calendar_outlined),
              label: const Text('Send a request to school'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _requestLeave(
    BuildContext context,
    String studentPublicId,
  ) async {
    if (studentPublicId.isEmpty) return;
    final values = await showDialog<Map<String, String>>(
      context: context,
      builder: (_) => const _HostedParentRequestDialog(),
    );
    if (values != null) {
      onSubmitHostedParentRequest({
        ...values,
        'studentPublicId': studentPublicId,
      });
    }
  }

  List<Map<String, dynamic>> _snapshotRows(Object? value) =>
      (value as List? ?? [])
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList();
}

class _ParentCount extends StatelessWidget {
  const _ParentCount({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) => Chip(
    label: Text('$label  $count', style: const TextStyle(fontSize: 11)),
    visualDensity: VisualDensity.compact,
    backgroundColor: const Color(0xffedf3ff),
  );
}

class _HostedParentRequestDialog extends StatefulWidget {
  const _HostedParentRequestDialog();

  @override
  State<_HostedParentRequestDialog> createState() =>
      _HostedParentRequestDialogState();
}

class _HostedParentRequestDialogState
    extends State<_HostedParentRequestDialog> {
  final _formKey = GlobalKey<FormState>();
  final _message = TextEditingController();
  final _startsOn = TextEditingController();
  final _endsOn = TextEditingController();
  String _requestType = 'leave';

  @override
  void dispose() {
    _message.dispose();
    _startsOn.dispose();
    _endsOn.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Send a request to school'),
    content: Form(
      key: _formKey,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              initialValue: _requestType,
              decoration: const InputDecoration(labelText: 'Request type'),
              items: const [
                DropdownMenuItem(value: 'leave', child: Text('Leave')),
                DropdownMenuItem(
                  value: 'profile_change',
                  child: Text('Profile change'),
                ),
                DropdownMenuItem(value: 'document', child: Text('Document')),
                DropdownMenuItem(value: 'other', child: Text('Other')),
              ],
              onChanged:
                  (value) => setState(() => _requestType = value ?? 'leave'),
            ),
            TextFormField(
              controller: _startsOn,
              decoration: const InputDecoration(
                labelText: 'Start date (optional)',
                hintText: 'YYYY-MM-DD',
              ),
              validator:
                  (value) =>
                      validateOptionalIsoDate(value, label: 'start date'),
            ),
            TextFormField(
              controller: _endsOn,
              decoration: const InputDecoration(
                labelText: 'End date (optional)',
                hintText: 'YYYY-MM-DD',
              ),
              validator:
                  (value) =>
                      validateOptionalIsoDate(value, label: 'end date') ??
                      validateOptionalRequestDateRange(
                        startsOn: _startsOn.text,
                        endsOn: value,
                      ),
            ),
            TextFormField(
              controller: _message,
              minLines: 2,
              maxLines: 4,
              decoration: const InputDecoration(labelText: 'Message'),
              validator:
                  (value) =>
                      (value?.trim().length ?? 0) < 3
                          ? 'Enter at least 3 characters.'
                          : null,
            ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          if (_formKey.currentState?.validate() != true) return;
          Navigator.pop(context, {
            'requestType': _requestType,
            'startsOn': _startsOn.text.trim(),
            'endsOn': _endsOn.text.trim(),
            'message': _message.text.trim(),
          });
        },
        child: const Text('Submit'),
      ),
    ],
  );
}

IconData _iconFor(String area) {
  if (area.toLowerCase().contains('attendance'))
    return Icons.fact_check_outlined;
  if (area.toLowerCase().contains('message')) return Icons.chat_bubble_outline;
  return Icons.school_outlined;
}

class _BiometricUnlockView extends StatelessWidget {
  const _BiometricUnlockView({
    required this.working,
    required this.onUnlock,
    required this.onUsePassword,
    this.error,
  });

  final bool working;
  final String? error;
  final VoidCallback onUnlock;
  final VoidCallback onUsePassword;

  @override
  Widget build(BuildContext context) => _Page(
    role: MobileRole.parent,
    child: _CardBody(
      title: 'Unlock Parent app',
      subtitle:
          'Confirm with this phone’s biometrics to reopen the saved session.',
      error: error,
      children: [
        _PrimaryButton(
          label: 'Unlock with biometrics',
          working: working,
          icon: Icons.fingerprint,
          onPressed: onUnlock,
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed: working ? null : onUsePassword,
          child: const Text('Use password sign-in instead'),
        ),
        const Text(
          'Biometrics unlock this phone only. Your school still checks account access with its server.',
          style: TextStyle(color: Color(0xff6b788a), fontSize: 12.5),
        ),
      ],
    ),
  );
}

class _GateView extends StatefulWidget {
  const _GateView({
    required this.role,
    required this.reason,
    this.googleEmail,
    this.error,
    this.success,
    required this.working,
    required this.onAttachGoogle,
    required this.onActivate,
    required this.onRefresh,
    required this.onChangeServer,
  });
  final MobileRole role;
  final String reason;
  final String? googleEmail;
  final String? error;
  final String? success;
  final bool working;
  final VoidCallback onAttachGoogle;
  final ValueChanged<String> onActivate;
  final VoidCallback onRefresh;
  final VoidCallback onChangeServer;

  @override
  State<_GateView> createState() => _GateViewState();
}

class _GateViewState extends State<_GateView> {
  final _activationCode = TextEditingController();

  @override
  void dispose() {
    _activationCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _Page(
    role: widget.role,
    child: _CardBody(
      title: 'Access is not active yet',
      subtitle: widget.reason,
      error: widget.error,
      success: widget.success,
      children: [
        const _InfoBanner(
          text:
              'The initial trial bypass has ended. Verify the original Google account and enter a valid server activation code to restore access.',
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: widget.working ? null : widget.onAttachGoogle,
          icon: const Icon(Icons.account_circle_outlined),
          label: Text(widget.googleEmail ?? 'Attach original Google account'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _activationCode,
          obscureText: true,
          decoration: const InputDecoration(
            labelText: 'Server activation code',
          ),
        ),
        const SizedBox(height: 14),
        _PrimaryButton(
          label: 'Verify and activate',
          working: widget.working,
          onPressed: () => widget.onActivate(_activationCode.text),
        ),
        TextButton(
          onPressed: widget.working ? null : widget.onRefresh,
          child: const Text('Check setup again'),
        ),
        TextButton(
          onPressed: widget.onChangeServer,
          child: const Text('Use another server'),
        ),
      ],
    ),
  );
}

class _TrialBanner extends StatelessWidget {
  const _TrialBanner({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context) => _InfoBanner(
    text:
        enabled
            ? 'Trial mode is active. Google account and activation checks are bypassed for now.'
            : 'Trial mode is off. Verified Google sign-in and a valid server activation code are required before setup can finish.',
  );
}

class _ConsentRow extends StatelessWidget {
  const _ConsentRow({required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => SwitchListTile.adaptive(
    contentPadding: EdgeInsets.zero,
    value: value,
    onChanged: onChanged,
    title: const Text(
      'Share analytics and crash diagnostics',
      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    ),
    subtitle: const Text(
      'Optional. Student names, records and messages are never sent as analytics.',
      style: TextStyle(fontSize: 11.5),
    ),
  );
}

class _CardBody extends StatelessWidget {
  const _CardBody({
    required this.title,
    required this.subtitle,
    required this.children,
    this.error,
    this.success,
  });
  final String title;
  final String subtitle;
  final List<Widget> children;
  final String? error;
  final String? success;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 21,
              height: 1.2,
              color: Color(0xff122238),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            subtitle,
            style: const TextStyle(color: Color(0xff68778b), height: 1.4),
          ),
          const SizedBox(height: 16),
          if (error != null) ...[
            _MessageBanner(text: error!, error: true),
            const SizedBox(height: 10),
          ],
          if (success != null) ...[
            _MessageBanner(text: success!, error: false),
            const SizedBox(height: 10),
          ],
          ...children,
        ],
      ),
    ),
  );
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    this.working = false,
    this.icon,
    required this.onPressed,
  });
  final String label;
  final bool working;
  final IconData? icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 49,
    child: FilledButton.icon(
      onPressed: working ? null : onPressed,
      icon:
          working
              ? const SizedBox.square(
                dimension: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
              : Icon(icon ?? Icons.arrow_forward_rounded, size: 18),
      label: Text(
        working ? 'Please wait…' : label,
        style: const TextStyle(fontWeight: FontWeight.w700),
      ),
    ),
  );
}

class _MessageBanner extends StatelessWidget {
  const _MessageBanner({required this.text, required this.error});
  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: error ? const Color(0xffffeeee) : const Color(0xffe9f8f0),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: error ? const Color(0xffa13f3f) : const Color(0xff26744e),
        height: 1.4,
        fontSize: 13,
      ),
    ),
  );
}

class _InfoBanner extends StatelessWidget {
  const _InfoBanner({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xffeef4ff),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      text,
      style: const TextStyle(
        color: Color(0xff315783),
        height: 1.45,
        fontSize: 12.5,
      ),
    ),
  );
}

import 'dart:async';

import 'package:firebase_analytics/firebase_analytics.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:firebase_in_app_messaging/firebase_in_app_messaging.dart';
import 'package:firebase_performance/firebase_performance.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class FirebaseServices {
  FirebaseServices._();

  static bool _ready = false;
  static bool _consent = false;
  static FirebaseRemoteConfig? _remoteConfig;

  static bool get ready => _ready;
  static bool get analyticsConsent => _consent;
  static bool get showWelcomeCard =>
      _remoteConfig?.getBool('show_welcome_card') ?? true;

  static Future<bool> initialize([FirebaseOptions? options]) async {
    if (options == null ||
        options.apiKey.isEmpty ||
        options.appId.isEmpty ||
        options.messagingSenderId.isEmpty ||
        options.projectId.isEmpty) {
      return false;
    }

    try {
      if (Firebase.apps.isEmpty) {
        await Firebase.initializeApp(options: options);
      }
      _ready = true;
      await setAnalyticsConsent(false);
      FlutterError.onError = (details) {
        FlutterError.presentError(details);
        if (_consent) {
          unawaited(
            _bestEffort(
              () =>
                  FirebaseCrashlytics.instance.recordFlutterFatalError(details),
            ),
          );
        }
      };
      PlatformDispatcher.instance.onError = (error, stack) {
        if (!_consent) return false;
        unawaited(
          _bestEffort(
            () => FirebaseCrashlytics.instance.recordError(
              error,
              stack,
              fatal: true,
            ),
          ),
        );
        return true;
      };
      return true;
    } on PlatformException {
      _ready = false;
      return false;
    } catch (_) {
      _ready = false;
      return false;
    }
  }

  static Future<void> setAnalyticsConsent(bool enabled) async {
    _consent = enabled;
    if (!_ready) return;
    await _bestEffort(
      () => FirebaseAnalytics.instance.setAnalyticsCollectionEnabled(enabled),
    );
    await _bestEffort(
      () =>
          FirebaseCrashlytics.instance.setCrashlyticsCollectionEnabled(enabled),
    );
    await _bestEffort(
      () =>
          FirebasePerformance.instance.setPerformanceCollectionEnabled(enabled),
    );
    await _bestEffort(
      () => FirebaseInAppMessaging.instance.setAutomaticDataCollectionEnabled(
        enabled,
      ),
    );
    if (!enabled) return;

    try {
      final remoteConfig = FirebaseRemoteConfig.instance;
      _remoteConfig = remoteConfig;
      await remoteConfig.setConfigSettings(
        RemoteConfigSettings(
          fetchTimeout: const Duration(seconds: 4),
          minimumFetchInterval:
              kDebugMode ? Duration.zero : const Duration(hours: 12),
        ),
      );
      await remoteConfig.setDefaults(const {'show_welcome_card': true});
      await remoteConfig.fetchAndActivate();
    } catch (_) {
      // Keep the shipped default when remote values are not available.
    }
    await _bestEffort(
      () => FirebaseAnalytics.instance.logEvent(name: 'mobile_app_open'),
    );
    await _bestEffort(
      () => FirebaseInAppMessaging.instance.triggerEvent('mobile_home_opened'),
    );
  }

  static Future<Trace?> startApiTrace() async {
    if (!_ready || !_consent) return null;
    try {
      final trace = FirebasePerformance.instance.newTrace('school_api_request');
      await trace.start();
      return trace;
    } catch (_) {
      return null;
    }
  }

  static Future<void> stopApiTrace(Trace? trace) async {
    if (trace == null) return;
    try {
      await trace.stop();
    } catch (_) {
      // Performance collection is optional and never blocks a school workflow.
    }
  }

  static Future<void> _bestEffort(Future<void> Function() operation) async {
    try {
      await operation();
    } catch (_) {
      // Firebase services are optional and must not block local school work.
    }
  }
}

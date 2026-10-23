import 'package:flutter_test/flutter_test.dart';
import 'package:school_erp_mobile_shared/src/firebase_services.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'unconfigured Firebase keeps optional services off and app defaults',
    () async {
      expect(await FirebaseServices.initialize(), isFalse);
      await FirebaseServices.setAnalyticsConsent(true);

      expect(FirebaseServices.ready, isFalse);
      expect(FirebaseServices.analyticsConsent, isTrue);
      expect(FirebaseServices.showWelcomeCard, isTrue);
      expect(await FirebaseServices.startApiTrace(), isNull);

      await FirebaseServices.setAnalyticsConsent(false);
      expect(FirebaseServices.analyticsConsent, isFalse);
    },
  );
}

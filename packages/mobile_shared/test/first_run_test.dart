import 'package:flutter_test/flutter_test.dart';
import 'package:school_erp_mobile_shared/school_erp_mobile_shared.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('first launch asks for the school server before sign-in', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(const SchoolErpMobile(role: MobileRole.teacher));
    await tester.pumpAndSettle();

    expect(find.text('Connect your school'), findsOneWidget);
    expect(find.text('Server address'), findsOneWidget);
    expect(find.text('Connect securely'), findsOneWidget);
    expect(find.text('Sign in'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

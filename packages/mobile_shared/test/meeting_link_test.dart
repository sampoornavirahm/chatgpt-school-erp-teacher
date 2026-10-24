import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:school_erp_mobile_shared/src/meeting_link.dart';

void main() {
  testWidgets('shows an action only for an accepted meeting URL', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SchoolMeetingLinkButton(link: 'https://meet.example.org/room'),
        ),
      ),
    );
    expect(find.text('Open class'), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SchoolMeetingLinkButton(link: 'javascript:alert(1)'),
        ),
      ),
    );
    expect(find.text('Open class'), findsNothing);
  });

  group('schoolMeetingUri', () {
    test('accepts external HTTP and HTTPS meeting URLs', () {
      expect(
        schoolMeetingUri('https://meet.example.org/room')?.host,
        'meet.example.org',
      );
      expect(schoolMeetingUri('http://school.local:8080/class')?.port, 8080);
    });

    test(
      'rejects non-web schemes, embedded credentials and malformed values',
      () {
        expect(schoolMeetingUri('javascript:alert(1)'), isNull);
        expect(schoolMeetingUri('file:///etc/passwd'), isNull);
        expect(
          schoolMeetingUri('https://user:password@example.org/room'),
          isNull,
        );
        expect(schoolMeetingUri('not a URL'), isNull);
        expect(schoolMeetingUri('https://example.org/${'x' * 2049}'), isNull);
      },
    );
  });
}

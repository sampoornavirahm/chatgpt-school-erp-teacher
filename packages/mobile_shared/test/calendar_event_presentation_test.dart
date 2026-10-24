import 'package:flutter_test/flutter_test.dart';
import 'package:school_erp_mobile_shared/src/calendar_event_presentation.dart';

void main() {
  test('school closures have a distinct, explicit label from holidays', () {
    expect(calendarEventTypeLabel('closure'), 'School closure');
    expect(calendarEventTypeLabel('holiday'), 'Holiday');
  });

  test('known calendar event types use readable labels', () {
    expect(calendarEventTypeLabel('ptm'), 'Parent meeting');
    expect(calendarEventTypeLabel('exam'), 'Exam');
    expect(calendarEventTypeLabel('trip'), 'School trip');
    expect(calendarEventTypeLabel('deadline'), 'Deadline');
    expect(calendarEventTypeLabel(null), 'School event');
  });
}

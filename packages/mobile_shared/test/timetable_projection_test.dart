import 'package:flutter_test/flutter_test.dart';
import 'package:school_erp_mobile_shared/src/timetable_projection.dart';

void main() {
  final entries = [
    {'weekday': 3, 'period': 2, 'subjectName': 'Science'},
    {'weekday': 1, 'period': 2, 'subjectName': 'English'},
    {'weekday': 1, 'period': 1, 'subjectName': 'Mathematics'},
  ];

  test('today view filters to the selected weekday and orders periods', () {
    final visible = timetableEntriesForView(entries, weekly: false, weekday: 1);

    expect(visible.map((entry) => entry['subjectName']), [
      'Mathematics',
      'English',
    ]);
  });

  test('week view orders days and periods and applies its display limit', () {
    final visible = timetableEntriesForView(
      entries,
      weekly: true,
      weekday: 4,
      limit: 2,
    );

    expect(visible.map((entry) => entry['subjectName']), [
      'Mathematics',
      'English',
    ]);
  });

  test('weekday labels are readable and cover the school week', () {
    expect(timetableWeekdayLabel(1), 'Monday');
    expect(timetableWeekdayLabel(6), 'Saturday');
    expect(timetableWeekdayLabel(0), 'Day 0');
  });

  test('last-sync label distinguishes fresh, stale and unavailable data', () {
    final fresh = DateTime.now().toUtc().subtract(const Duration(minutes: 5));
    expect(
      timetableSyncLabel(fresh.toIso8601String()),
      startsWith('Last synced'),
    );
    expect(
      timetableSyncLabel('2000-01-01T00:00:00.000Z'),
      startsWith('Timetable may be stale'),
    );
    expect(timetableSyncLabel(null), 'Timetable sync time unavailable');
  });
}

String calendarEventTypeLabel(Object? value) {
  final type = value?.toString() ?? '';
  return switch (type) {
    'closure' => 'School closure',
    'holiday' => 'Holiday',
    'exam' => 'Exam',
    'trip' => 'School trip',
    'deadline' => 'Deadline',
    'event' => 'Event',
    'ptm' => 'Parent meeting',
    '' => 'School event',
    _ => type.replaceAll('_', ' '),
  };
}

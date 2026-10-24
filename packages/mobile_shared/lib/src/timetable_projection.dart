List<Map<String, dynamic>> timetableEntriesForView(
  Iterable<Map<String, dynamic>> entries, {
  required bool weekly,
  required int weekday,
  int limit = 30,
}) {
  final ordered =
      entries.toList()..sort((left, right) {
        final dayOrder = (int.tryParse(left['weekday']?.toString() ?? '') ?? 0)
            .compareTo(int.tryParse(right['weekday']?.toString() ?? '') ?? 0);
        return dayOrder != 0
            ? dayOrder
            : (int.tryParse(left['period']?.toString() ?? '') ?? 0).compareTo(
              int.tryParse(right['period']?.toString() ?? '') ?? 0,
            );
      });
  final visible =
      weekly
          ? ordered
          : ordered
              .where(
                (entry) =>
                    int.tryParse(entry['weekday']?.toString() ?? '') == weekday,
              )
              .toList();
  return visible.take(limit).toList();
}

String timetableWeekdayLabel(int weekday) => switch (weekday) {
  1 => 'Monday',
  2 => 'Tuesday',
  3 => 'Wednesday',
  4 => 'Thursday',
  5 => 'Friday',
  6 => 'Saturday',
  7 => 'Sunday',
  _ => 'Day $weekday',
};

String timetableSyncLabel(Object? value) {
  final syncedAt = DateTime.tryParse(value?.toString() ?? '');
  if (syncedAt == null) return 'Timetable sync time unavailable';
  final age = DateTime.now().toUtc().difference(syncedAt.toUtc());
  final local = syncedAt.toLocal();
  final date = '${local.day}/${local.month}/${local.year}';
  final hour = local.hour % 12 == 0 ? 12 : local.hour % 12;
  final minute = local.minute.toString().padLeft(2, '0');
  final time = '$date at $hour:$minute ${local.hour >= 12 ? 'PM' : 'AM'}';
  return '${age > const Duration(hours: 24) ? 'Timetable may be stale · ' : ''}Last synced $time';
}

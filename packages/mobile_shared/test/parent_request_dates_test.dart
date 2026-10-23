import 'package:flutter_test/flutter_test.dart';
import 'package:school_erp_mobile_shared/src/parent_request_dates.dart';

void main() {
  group('optional parent request dates', () {
    test('accepts either date or both dates as blank', () {
      expect(validateOptionalIsoDate('', label: 'start date'), isNull);
      expect(
        validateOptionalRequestDateRange(startsOn: '2026-10-23', endsOn: ''),
        isNull,
      );
      expect(
        validateOptionalRequestDateRange(startsOn: '', endsOn: '2026-10-24'),
        isNull,
      );
      expect(
        validateOptionalRequestDateRange(startsOn: '', endsOn: ''),
        isNull,
      );
    });

    test('rejects malformed and impossible dates', () {
      expect(
        validateOptionalIsoDate('23/10/2026', label: 'start date'),
        isNotNull,
      );
      expect(
        validateOptionalIsoDate('2026-02-30', label: 'start date'),
        isNotNull,
      );
      expect(
        validateOptionalIsoDate('2026-10-23', label: 'start date'),
        isNull,
      );
    });

    test('rejects an end date earlier than a supplied start date', () {
      expect(
        validateOptionalRequestDateRange(
          startsOn: '2026-10-24',
          endsOn: '2026-10-23',
        ),
        'End date must be on or after the start date.',
      );
      expect(
        validateOptionalRequestDateRange(
          startsOn: '2026-10-23',
          endsOn: '2026-10-24',
        ),
        isNull,
      );
    });
  });
}

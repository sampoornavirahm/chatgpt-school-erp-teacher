import 'package:flutter_test/flutter_test.dart';
import 'package:school_erp_mobile_shared/src/parent_feature_flags.dart';

void main() {
  group('ParentFeatureFlags', () {
    test('defaults every optional parent module to off', () {
      expect(ParentFeatureFlags.fromWire(null).courses, isFalse);
      expect(ParentFeatureFlags.fromWire(null).transport, isFalse);
      expect(ParentFeatureFlags.fromWire(null).ai, isFalse);
    });

    test('enables only explicit true values from the server contract', () {
      final flags = ParentFeatureFlags.fromWire({
        'courses': true,
        'transport': false,
        'ai': 'true',
        'unknown': true,
      });

      expect(flags.courses, isTrue);
      expect(flags.transport, isFalse);
      expect(flags.ai, isFalse);
    });
  });
}

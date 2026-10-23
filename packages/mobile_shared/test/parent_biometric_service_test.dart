import 'package:flutter_test/flutter_test.dart';
import 'package:school_erp_mobile_shared/src/parent_biometric_service.dart';

void main() {
  group('ParentBiometricService', () {
    test('will not enable when the phone has no enrolled biometrics', () async {
      final adapter = _FakeBiometricAdapter(available: false, result: true);
      final service = ParentBiometricService(adapter);

      expect(await service.enableOnThisDevice(), isFalse);
      expect(adapter.authenticationCount, 0);
    });

    test('enables only after the phone authenticates successfully', () async {
      final accepted = _FakeBiometricAdapter(available: true, result: true);
      final rejected = _FakeBiometricAdapter(available: true, result: false);

      expect(
        await ParentBiometricService(accepted).enableOnThisDevice(),
        isTrue,
      );
      expect(
        await ParentBiometricService(rejected).enableOnThisDevice(),
        isFalse,
      );
      expect(accepted.authenticationCount, 1);
      expect(rejected.authenticationCount, 1);
    });

    test(
      'failed device authentication never unlocks the saved session',
      () async {
        final adapter = _FakeBiometricAdapter(available: true, result: false);

        expect(
          await ParentBiometricService(adapter).unlockOnThisDevice(),
          isFalse,
        );
        expect(adapter.authenticationCount, 1);
      },
    );
  });
}

class _FakeBiometricAdapter implements ParentBiometricAdapter {
  _FakeBiometricAdapter({required this.available, required this.result});

  final bool available;
  final bool result;
  int authenticationCount = 0;

  @override
  Future<bool> get isAvailable async => available;

  @override
  Future<bool> authenticate(String reason) async {
    authenticationCount++;
    return result;
  }
}

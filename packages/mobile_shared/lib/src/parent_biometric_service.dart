import 'package:local_auth/local_auth.dart';

abstract interface class ParentBiometricAdapter {
  Future<bool> get isAvailable;

  Future<bool> authenticate(String reason);
}

class PlatformParentBiometricAdapter implements ParentBiometricAdapter {
  PlatformParentBiometricAdapter([LocalAuthentication? auth])
    : _auth = auth ?? LocalAuthentication();

  final LocalAuthentication _auth;

  @override
  Future<bool> get isAvailable async {
    try {
      return await _auth.canCheckBiometrics &&
          (await _auth.getAvailableBiometrics()).isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate(String reason) async {
    try {
      return await _auth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (_) {
      return false;
    }
  }
}

class ParentBiometricService {
  const ParentBiometricService(this._adapter);

  final ParentBiometricAdapter _adapter;

  Future<bool> get isAvailable => _adapter.isAvailable;

  Future<bool> enableOnThisDevice() async {
    if (!await _adapter.isAvailable) return false;
    return _adapter.authenticate(
      'Enable biometric unlock for the Parent app on this phone.',
    );
  }

  Future<bool> unlockOnThisDevice() => _adapter.authenticate(
    'Unlock your saved Parent app session on this phone.',
  );
}

import 'dart:typed_data';

import 'package:x25519/x25519.dart' as x;

/// X25519 keypair: 32-byte private (clamped) and 32-byte public.
class X25519KeyPair {
  final Uint8List privateKey;
  final Uint8List publicKey;
  X25519KeyPair({required this.privateKey, required this.publicKey});
}

/// Generate a fresh X25519 keypair using a secure RNG.
X25519KeyPair x25519GenerateKeyPair() {
  final kp = x.generateKeyPair();
  return X25519KeyPair(
    privateKey: Uint8List.fromList(kp.privateKey),
    publicKey: Uint8List.fromList(kp.publicKey),
  );
}

/// Compute X25519 shared secret = scalarMult(privateKey, publicKey).
/// Returns 32 bytes. Throws if [publicKey] is a low-order point.
Uint8List x25519ShareSecret({
  required Uint8List privateKey,
  required Uint8List publicKey,
}) {
  return x.X25519(privateKey, publicKey);
}

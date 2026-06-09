/// Sealed error hierarchy for the SeeOnce app.
sealed class SeeOnceError implements Exception {
  final String message;
  const SeeOnceError(this.message);

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when RSA / AES crypto operations fail.
final class CryptoError extends SeeOnceError {
  const CryptoError(super.message);
}

/// Thrown when a pairing code cannot be decoded / encoded.
final class PairingCodeError extends SeeOnceError {
  const PairingCodeError(super.message);
}

/// Thrown when an image exceeds the allowed size limit after compression.
final class ImageTooLargeError extends SeeOnceError {
  const ImageTooLargeError(super.message);
}

/// Thrown when the WebRTC connection is not established.
final class ConnectionError extends SeeOnceError {
  const ConnectionError(super.message);
}

/// Thrown when a received image envelope cannot be decrypted.
final class DecryptionError extends SeeOnceError {
  const DecryptionError(super.message);
}

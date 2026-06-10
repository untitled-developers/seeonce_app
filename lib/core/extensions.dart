import 'dart:typed_data';

extension Uint8ListZero on Uint8List {
  /// Overwrites every byte with zero.  Call after sensitive data is no longer needed.
  void zero() => fillRange(0, length, 0);
}

extension StringTruncate on String {
  /// Returns the first [maxLength] characters followed by '…' if longer.
  String truncate(int maxLength) =>
      length <= maxLength ? this : '${substring(0, maxLength)}…';
}

extension DateTimeFormat on DateTime {
  /// Returns a human-readable "HH:mm" string in local time.
  String toTimeString() {
    final local = toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

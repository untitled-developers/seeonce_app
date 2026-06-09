import 'package:hive_flutter/hive_flutter.dart';
import '../../core/constants.dart';

class CompressionSettings {
  int maxDimension;
  int jpegQuality;

  CompressionSettings({
    required this.maxDimension,
    required this.jpegQuality,
  });
}

/// Top-level settings object aggregating all user preferences.
class AppSettings {
  final CompressionSettings compression;
  final bool notificationsEnabled;

  /// Name shown to peers when pairing. Empty means "not set" — a random
  /// fallback is generated at pairing time.
  final String displayName;

  const AppSettings({
    required this.compression,
    required this.notificationsEnabled,
    this.displayName = '',
  });

  AppSettings copyWith({
    CompressionSettings? compression,
    bool? notificationsEnabled,
    String? displayName,
  }) =>
      AppSettings(
        compression: compression ?? this.compression,
        notificationsEnabled: notificationsEnabled ?? this.notificationsEnabled,
        displayName: displayName ?? this.displayName,
      );
}

class SettingsRepository {
  static const String _compressionKey = 'compression_settings';
  static const String _notificationsKey = 'notifications_enabled';
  static const String _displayNameKey = 'display_name';

  Future<AppSettings> getSettings() async {
    final box = Hive.box(AppConstants.settingsBoxName);

    final map = box.get(_compressionKey);
    final compression = CompressionSettings(
      maxDimension: map?['maxDimension'] as int? ?? 1080,
      jpegQuality: map?['jpegQuality'] as int? ?? 80,
    );

    final notificationsEnabled =
        box.get(_notificationsKey, defaultValue: true) as bool;
    final displayName = box.get(_displayNameKey, defaultValue: '') as String;

    return AppSettings(
      compression: compression,
      notificationsEnabled: notificationsEnabled,
      displayName: displayName,
    );
  }

  Future<void> saveSettings(AppSettings settings) async {
    final box = Hive.box(AppConstants.settingsBoxName);
    await box.put(_compressionKey, {
      'maxDimension': settings.compression.maxDimension,
      'jpegQuality': settings.compression.jpegQuality,
    });
    await box.put(_notificationsKey, settings.notificationsEnabled);
    await box.put(_displayNameKey, settings.displayName);
  }
}

import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/repositories/settings_repository.dart';

class SettingsNotifier extends StateNotifier<AsyncValue<AppSettings>> {
  final SettingsRepository _repo;

  SettingsNotifier(this._repo) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final settings = await _repo.getSettings();
      state = AsyncValue.data(settings);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> updateCompression({
    required int maxDimension,
    required int jpegQuality,
  }) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final updated = current.copyWith(
      compression: CompressionSettings(
        maxDimension: maxDimension,
        jpegQuality: jpegQuality,
      ),
    );
    await _repo.saveSettings(updated);
    state = AsyncValue.data(updated);
  }

  Future<void> setNotificationsEnabled(bool enabled) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final updated = current.copyWith(notificationsEnabled: enabled);
    await _repo.saveSettings(updated);
    state = AsyncValue.data(updated);
  }

  Future<void> setDisplayName(String name) async {
    final current = state.valueOrNull;
    if (current == null) return;
    final updated = current.copyWith(displayName: name.trim());
    await _repo.saveSettings(updated);
    state = AsyncValue.data(updated);
  }
}

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository();
});

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AsyncValue<AppSettings>>((ref) {
  return SettingsNotifier(ref.watch(settingsRepositoryProvider));
});

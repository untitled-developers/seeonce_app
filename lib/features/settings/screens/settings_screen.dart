import 'package:flutter/material.dart';
import 'package:settings_ui/settings_ui.dart';
import '../../../data/repositories/settings_repository.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _repo = SettingsRepository();
  AppSettings? _settings;

  /// Sensible photo long-edge presets; larger = sharper but slower to send.
  static const _dimensionChoices = [720, 1080, 1440, 2160];

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final s = await _repo.getSettings();
    if (mounted) setState(() => _settings = s);
  }

  Future<void> _save(AppSettings updated) async {
    await _repo.saveSettings(updated);
    if (mounted) setState(() => _settings = updated);
  }

  Future<void> _editDisplayName() async {
    final controller = TextEditingController(text: _settings!.displayName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Device name'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 30,
          decoration: const InputDecoration(
            hintText: 'Shown to contacts when pairing',
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('Save')),
        ],
      ),
    );
    controller.dispose();
    if (name == null) return;
    await _save(_settings!.copyWith(displayName: name));
  }

  Future<void> _pickMaxDimension() async {
    final current = _settings!.compression.maxDimension;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Max image dimension'),
        children: [
          RadioGroup<int>(
            groupValue: current,
            onChanged: (v) => Navigator.pop(ctx, v),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final d in _dimensionChoices)
                  RadioListTile<int>(title: Text('$d px'), value: d),
              ],
            ),
          ),
        ],
      ),
    );
    if (picked == null) return;
    await _save(_settings!.copyWith(
      compression: CompressionSettings(
        maxDimension: picked,
        jpegQuality: _settings!.compression.jpegQuality,
      ),
    ));
  }

  Future<void> _pickJpegQuality() async {
    var quality = _settings!.compression.jpegQuality;
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('JPEG quality'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('$quality%',
                  style: Theme.of(ctx).textTheme.headlineSmall),
              Slider(
                value: quality.toDouble(),
                min: 40,
                max: 100,
                divisions: 12,
                label: '$quality%',
                onChanged: (v) =>
                    setDialogState(() => quality = v.round()),
              ),
              const Text(
                'Higher quality means larger transfers.',
                style: TextStyle(color: Colors.grey, fontSize: 12),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, quality),
                child: const Text('Save')),
          ],
        ),
      ),
    );
    if (picked == null) return;
    await _save(_settings!.copyWith(
      compression: CompressionSettings(
        maxDimension: _settings!.compression.maxDimension,
        jpegQuality: picked,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_settings == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final displayName = _settings!.displayName;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SettingsList(
        darkTheme: SettingsThemeData(
          settingsListBackground: Theme.of(context).scaffoldBackgroundColor,
        ),
        sections: [
          SettingsSection(
            title: const Text('Profile'),
            tiles: [
              SettingsTile.navigation(
                leading: const Icon(Icons.badge_outlined),
                title: const Text('Device Name'),
                value: Text(displayName.isEmpty ? 'Not set' : displayName),
                description: const Text(
                    'Shown to contacts when you pair with them.'),
                onPressed: (_) => _editDisplayName(),
              ),
            ],
          ),
          SettingsSection(
            title: const Text('Image Compression'),
            tiles: [
              SettingsTile.navigation(
                leading: const Icon(Icons.photo_size_select_large),
                title: const Text('Max Dimension'),
                value: Text('${_settings!.compression.maxDimension} px'),
                onPressed: (_) => _pickMaxDimension(),
              ),
              SettingsTile.navigation(
                leading: const Icon(Icons.high_quality_outlined),
                title: const Text('JPEG Quality'),
                value: Text('${_settings!.compression.jpegQuality}%'),
                onPressed: (_) => _pickJpegQuality(),
              ),
            ],
          ),
          SettingsSection(
            title: const Text('Notifications'),
            tiles: [
              SettingsTile.switchTile(
                leading: const Icon(Icons.notifications_outlined),
                title: const Text('Enable Notifications'),
                initialValue: _settings!.notificationsEnabled,
                onToggle: (val) =>
                    _save(_settings!.copyWith(notificationsEnabled: val)),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

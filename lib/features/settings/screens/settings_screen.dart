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

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final s = await _repo.getSettings();
    setState(() => _settings = s);
  }

  @override
  Widget build(BuildContext context) {
    if (_settings == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Settings')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SettingsList(
        darkTheme: SettingsThemeData(
          settingsListBackground: Theme.of(context).scaffoldBackgroundColor,
        ),
        sections: [
          SettingsSection(
            title: const Text('Image Compression'),
            tiles: [
              SettingsTile.navigation(
                title: const Text('Max Dimension'),
                value: Text('${_settings!.compression.maxDimension} px'),
                onPressed: (context) {
                  // In a full app, show a dialog to change this
                },
              ),
              SettingsTile.navigation(
                title: const Text('JPEG Quality'),
                value: Text('${_settings!.compression.jpegQuality}%'),
                onPressed: (context) {
                  // In a full app, show a dialog to change this
                },
              ),
            ],
          ),
          SettingsSection(
            title: const Text('Notifications'),
            tiles: [
              SettingsTile.switchTile(
                title: const Text('Enable Notifications'),
                initialValue: _settings!.notificationsEnabled,
                onToggle: (val) async {
                  final newSettings = AppSettings(
                    compression: _settings!.compression,
                    notificationsEnabled: val,
                  );
                  await _repo.saveSettings(newSettings);
                  setState(() => _settings = newSettings);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

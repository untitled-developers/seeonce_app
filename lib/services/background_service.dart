import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';

/// Entry point for the foreground-service isolate. The actual connection work
/// (ConnectionSupervisor, LocalReconnectService, WebRTC) runs in the *main*
/// isolate; this foreground service exists purely to keep the app's process
/// alive in the background on Android so that work keeps running. The handler
/// is therefore intentionally a no-op.
@pragma('vm:entry-point')
void startCallback() {
  FlutterForegroundTask.setTaskHandler(_KeepAliveTaskHandler());
}

class _KeepAliveTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}

  @override
  void onRepeatEvent(DateTime timestamp) {}

  @override
  Future<void> onDestroy(DateTime timestamp) async {}
}

/// Thin wrapper around flutter_foreground_task.
///
/// Android only: iOS has no general long-running background service, so all
/// methods are no-ops there (the app stays connected only while foregrounded
/// and reconnects on resume).
class BackgroundService {
  static final BackgroundService instance = BackgroundService._();
  BackgroundService._();

  bool _initialized = false;

  void init() {
    if (_initialized || !Platform.isAndroid) return;
    _initialized = true;
    FlutterForegroundTask.init(
      androidNotificationOptions: AndroidNotificationOptions(
        channelId: 'seeonce_connection',
        channelName: 'Connection',
        channelDescription: 'Keeps your encrypted chats connected.',
        onlyAlertOnce: true,
      ),
      iosNotificationOptions: const IOSNotificationOptions(
        showNotification: false,
        playSound: false,
      ),
      foregroundTaskOptions: ForegroundTaskOptions(
        // No periodic event: the main isolate does the work; we only need the
        // process kept alive.
        eventAction: ForegroundTaskEventAction.nothing(),
        autoRunOnBoot: false,
        allowWakeLock: true,
        allowWifiLock: true,
      ),
    );
  }

  /// Requests the permissions the service needs (Android 13+ notification +
  /// battery-optimization exemption). Safe to call repeatedly.
  Future<void> requestPermissions() async {
    if (!Platform.isAndroid) return;
    final perm = await FlutterForegroundTask.checkNotificationPermission();
    if (perm != NotificationPermission.granted) {
      await FlutterForegroundTask.requestNotificationPermission();
    }
    if (!await FlutterForegroundTask.isIgnoringBatteryOptimizations) {
      await FlutterForegroundTask.requestIgnoreBatteryOptimization();
    }
  }

  Future<void> start() async {
    if (!Platform.isAndroid) return;
    init();
    if (await FlutterForegroundTask.isRunningService) return;
    final result = await FlutterForegroundTask.startService(
      serviceId: 256,
      notificationTitle: 'SeeOnce connected',
      notificationText: 'Keeping your encrypted chats connected.',
      callback: startCallback,
    );
    if (result is ServiceRequestFailure && kDebugMode) {
      debugPrint('[BackgroundService] start failed: ${result.error}');
    }
  }

  Future<void> stop() async {
    if (!Platform.isAndroid) return;
    if (await FlutterForegroundTask.isRunningService) {
      await FlutterForegroundTask.stopService();
    }
  }
}

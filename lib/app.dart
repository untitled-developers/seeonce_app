import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:no_screenshot/no_screenshot.dart';

import 'core/theme.dart';

import 'crypto/key_store.dart';
import 'data/repositories/peer_repository.dart';
import 'messaging/incoming_message_router.dart';
import 'notifications/notification_service.dart';
import 'rtc/connection_supervisor.dart';
import 'rtc/local_reconnect_service.dart';
import 'services/background_service.dart';
import 'features/conversation/screens/conversation_screen.dart';
import 'features/conversation/screens/image_viewer_screen.dart';
import 'features/conversation/screens/video_viewer_screen.dart';
import 'features/diagnostics/screens/connection_logs_screen.dart';
import 'features/pairing/screens/pairing_screen.dart';
import 'features/pairing/screens/scan_code_screen.dart';
import 'features/pairing/screens/show_code_screen.dart';
import 'features/peers/screens/peers_screen.dart';
import 'features/settings/screens/settings_screen.dart';
import 'data/models/image_message.dart';
import 'data/models/video_message.dart';

final _router = GoRouter(
  initialLocation: '/',
  observers: [routeObserver],
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) => const PeersScreen(),
    ),
    GoRoute(
      path: '/pairing',
      builder: (context, state) => const PairingScreen(),
      routes: [
        GoRoute(
          path: 'show-code',
          builder: (context, state) => const ShowCodeScreen(),
        ),
        GoRoute(
          path: 'scan-code',
          builder: (context, state) => const ScanCodeScreen(),
        ),
      ],
    ),
    GoRoute(
      path: '/conversation/:peerId',
      builder: (context, state) => ConversationScreen(peerId: state.pathParameters['peerId']!),
      routes: [
        GoRoute(
          path: 'view-image/:messageId',
          builder: (context, state) {
            final msg = state.extra as ImageMessage;
            return ImageViewerScreen(
              peerId: state.pathParameters['peerId']!,
              message: msg,
            );
          },
        ),
        GoRoute(
          path: 'view-video/:messageId',
          builder: (context, state) {
            final msg = state.extra as VideoMessage;
            return VideoViewerScreen(
              peerId: state.pathParameters['peerId']!,
              message: msg,
            );
          },
        ),
      ],
    ),
    GoRoute(
      path: '/settings',
      builder: (context, state) => const SettingsScreen(),
    ),
    GoRoute(
      path: '/logs',
      builder: (context, state) => const ConnectionLogsScreen(),
    ),
  ],
);

class SeeOnceApp extends ConsumerStatefulWidget {
  const SeeOnceApp({super.key});

  @override
  ConsumerState<SeeOnceApp> createState() => _SeeOnceAppState();
}

class _SeeOnceAppState extends ConsumerState<SeeOnceApp>
    with WidgetsBindingObserver {
  final _noScreenshot = NoScreenshot.instance;
  late final Future<void> _bootstrap;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _noScreenshot.screenshotOff();
    _bootstrap = _initialize();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // On return to foreground, immediately retry any dropped connections
    // instead of waiting out the supervisor's backoff windows.
    if (state == AppLifecycleState.resumed) {
      ConnectionSupervisor.instance.resumeNow();
    }
  }

  /// Work that must finish before the user can interact with the app, but that
  /// is too slow to run on the path to the first frame. Runs once.
  Future<void> _initialize() async {
    // RSA-4096 keygen happens off the UI isolate (see KeyStore); first launch
    // can take many seconds, so we gate the UI behind it rather than freezing.
    await KeyStore.instance.ensureKeysExist();
    final repo = PeerRepository();
    // App-wide receiver: owns every channel's onMessage, routes payloads into
    // the conversation store and raises notifications for chats not on screen.
    IncomingMessageRouter.instance.start(ref);
    // Start listening for reconnect offers so any screen can answer. Keys must
    // already exist (it computes our own key hash), hence the ordering here.
    unawaited(LocalReconnectService.instance.start(peerRepository: repo));
    // Supervise connections: auto-reconnect dropped peers with backoff.
    ConnectionSupervisor.instance.start(peerRepository: repo);

    // Android only: keep the process alive in the background so the supervisor
    // and WebRTC connections keep running, but only once there is at least one
    // paired peer worth staying connected for.
    BackgroundService.instance.init();
    final peers = await repo.getAllPeers();
    if (peers.isNotEmpty) {
      await BackgroundService.instance.requestPermissions();
      await BackgroundService.instance.start();
    }

    // Tapping a message notification opens that peer's conversation — both
    // while running and when the tap cold-launched the app.
    NotificationService.instance.onNotificationTap =
        (peerId) => _router.push('/conversation/$peerId');
    final launchPeerId = await NotificationService.instance.getLaunchPeerId();
    if (launchPeerId != null && peers.any((p) => p.id == launchPeerId)) {
      _router.push('/conversation/$launchPeerId');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      title: 'SeeOnce',
      themeMode: ThemeMode.dark,
      darkTheme: buildAppTheme(),
      routerConfig: _router,
      // Overlay a setup screen until bootstrap finishes. MaterialApp.builder
      // sits below the app's Directionality/MediaQuery, so a plain widget here
      // is safe.
      builder: (context, child) {
        return FutureBuilder<void>(
          future: _bootstrap,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const _SetupScreen();
            }
            if (snapshot.hasError) {
              return _SetupScreen(error: snapshot.error.toString());
            }
            return child ?? const SizedBox.shrink();
          },
        );
      },
    );
  }
}

/// Shown while encryption keys are being generated on first launch, or if that
/// setup fails.
class _SetupScreen extends StatelessWidget {
  final String? error;
  const _SetupScreen({this.error});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (error == null) ...[
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                const Text(
                  'Setting up encryption…',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 16),
                ),
                const SizedBox(height: 8),
                const Text(
                  'This only happens once and may take a moment.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppColors.textMuted, fontSize: 13),
                ),
              ] else ...[
                const Icon(Icons.error_outline,
                    color: AppColors.error, size: 40),
                const SizedBox(height: 16),
                const Text(
                  'Setup failed',
                  style: TextStyle(color: AppColors.textPrimary, fontSize: 16),
                ),
                const SizedBox(height: 8),
                Text(
                  error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppColors.textMuted, fontSize: 12),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

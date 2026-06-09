import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class NotificationService {
  static final NotificationService instance = NotificationService._internal();
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  
  static const _channelId = 'seeonce_images';
  static const _channelName = 'Received Images';
  static const _msgChannelId = 'seeonce_messages';
  static const _msgChannelName = 'Received Messages';

  Future<void> initialize() async {
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    
    const initSettings = InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    );
    
    await _plugin.initialize(
      initSettings,
      onDidReceiveNotificationResponse: (response) {
        // Handle notification tap
        // response.payload contains peerId
        // The router should be designed to handle this (e.g., via global key or provider)
      },
    );
  }

  Future<bool> requestPermission() async {
    bool granted = false;
    
    final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    if (androidPlugin != null) {
      granted = await androidPlugin.requestNotificationsPermission() ?? false;
    }
    
    final iosPlugin = _plugin.resolvePlatformSpecificImplementation<
        IOSFlutterLocalNotificationsPlugin>();
    if (iosPlugin != null) {
      granted = await iosPlugin.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      ) ?? false;
    }
    
    return granted;
  }

  Future<void> showImageReceivedNotification({
    required String senderName,
    required String messageId,
    required String peerId,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: true,
      playSound: true,
    );
    
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    
    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );
    
    await _plugin.show(
      messageId.hashCode,
      "New image",
      "📷 New image from $senderName",
      details,
      payload: peerId, // Used to navigate on tap
    );
  }

  Future<void> showVideoReceivedNotification({
    required String senderName,
    required String messageId,
    required String peerId,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _channelId,
      _channelName,
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: true,
      playSound: true,
    );
    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );
    const details =
        NotificationDetails(android: androidDetails, iOS: iosDetails);
    await _plugin.show(
      messageId.hashCode,
      "New video",
      "🎬 New video from $senderName",
      details,
      payload: peerId,
    );
  }

  /// Notifies of a received text message. Deliberately omits the message body:
  /// content must not leak to the lock screen / notification shade.
  Future<void> showTextReceivedNotification({
    required String senderName,
    required String messageId,
    required String peerId,
  }) async {
    const androidDetails = AndroidNotificationDetails(
      _msgChannelId,
      _msgChannelName,
      importance: Importance.high,
      priority: Priority.high,
      enableVibration: true,
      playSound: true,
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const details = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _plugin.show(
      messageId.hashCode,
      "New message",
      "💬 New message from $senderName",
      details,
      payload: peerId, // Used to navigate on tap
    );
  }
}

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'data/datasources/hive_datasource.dart';
import 'notifications/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Fast setup that must complete before any UI.
  await HiveDatasource.init();
  await NotificationService.instance.initialize();
  await NotificationService.instance.requestPermission();

  // Key generation (potentially many seconds on first launch), phantom-peer
  // cleanup and LAN reconnect are deferred to the bootstrap gate inside
  // SeeOnceApp so they run off the UI thread without blocking the first frame.
  runApp(const ProviderScope(child: SeeOnceApp()));
}

import 'package:hive/hive.dart';

part 'peer.g.dart';

@HiveType(typeId: 0)
class Peer extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  String displayName;

  @HiveField(2)
  final String publicKeyPem;

  @HiveField(3)
  final DateTime pairedAt;

  // NOT persisted:
  bool isOnline = false;

  Peer({
    required this.id,
    required this.displayName,
    required this.publicKeyPem,
    required this.pairedAt,
  });
}

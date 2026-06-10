import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:seeonce_app/data/models/peer.dart';
import 'package:seeonce_app/data/repositories/peer_repository.dart';
import 'package:seeonce_app/core/constants.dart';
import 'dart:io';

void main() {
  late PeerRepository repo;
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('hive_test_');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(0)) {
      Hive.registerAdapter(PeerAdapter());
    }
    await Hive.openBox<Peer>(AppConstants.peersBoxName);
    repo = PeerRepository();
  });

  tearDown(() async {
    await Hive.deleteBoxFromDisk(AppConstants.peersBoxName);
    await Hive.close();
    await tempDir.delete(recursive: true);
  });

  Peer makePeer(String id) => Peer(
        id: id,
        displayName: 'Peer $id',
        publicKeyPem: 'pem-$id',
        pairedAt: DateTime(2024, 1, 1),
      );

  group('PeerRepository', () {
    test('savePeer stores peer and getAllPeers returns it', () async {
      final peer = makePeer('p1');
      await repo.savePeer(peer);
      final all = await repo.getAllPeers();
      expect(all.length, equals(1));
      expect(all.first.id, equals('p1'));
    });

    test('getPeerById returns null for unknown id', () async {
      final result = await repo.getPeerById('nonexistent');
      expect(result, isNull);
    });

    test('getPeerById returns correct peer', () async {
      await repo.savePeer(makePeer('p1'));
      await repo.savePeer(makePeer('p2'));
      final found = await repo.getPeerById('p2');
      expect(found, isNotNull);
      expect(found!.displayName, equals('Peer p2'));
    });

    test('deletePeer removes peer', () async {
      await repo.savePeer(makePeer('p1'));
      await repo.deletePeer('p1');
      expect(await repo.getPeerById('p1'), isNull);
    });

    test('watchPeers emits updated list on change', () async {
      // Collect all emitted values into a list
      final emitted = <List<Peer>>[];
      final subscription = repo.watchPeers().listen(emitted.add);

      // Give the initial emission time to arrive
      await Future.delayed(const Duration(milliseconds: 50));
      expect(emitted.isNotEmpty, isTrue);
      expect(emitted.last, isEmpty);

      await repo.savePeer(makePeer('p1'));
      await Future.delayed(const Duration(milliseconds: 50));

      expect(emitted.last.length, equals(1));

      await subscription.cancel();
    });
  });
}

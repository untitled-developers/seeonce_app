import 'package:hive_flutter/hive_flutter.dart';
import '../../core/constants.dart';
import '../models/peer.dart';

class PeerRepository {
  Box<Peer> get _box => Hive.box<Peer>(AppConstants.peersBoxName);

  Future<List<Peer>> getAllPeers() async {
    return _box.values.toList();
  }

  Future<void> savePeer(Peer peer) async {
    await _box.put(peer.id, peer);
  }

  Future<Peer?> findPeerByPublicKey(String publicKeyPem) async {
    try {
      return _box.values.firstWhere((p) => p.publicKeyPem == publicKeyPem);
    } catch (_) {
      return null;
    }
  }

  Future<void> deletePeer(String peerId) async {
    await _box.delete(peerId);
  }

  Future<Peer?> getPeerById(String peerId) async {
    return _box.get(peerId);
  }

  Stream<List<Peer>> watchPeers() {
    // emit initial value, then listen for changes
    return Stream.value(_box.values.toList())
        .cast<List<Peer>>()
        .asyncExpand((initial) async* {
      yield initial;
      yield* _box.watch().map((event) => _box.values.toList());
    });
  }
}

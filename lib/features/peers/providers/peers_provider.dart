import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/peer.dart';
import '../../../data/repositories/peer_repository.dart';

final peerRepositoryProvider = Provider<PeerRepository>((ref) {
  return PeerRepository();
});

final peersProvider = StreamProvider<List<Peer>>((ref) {
  final repo = ref.watch(peerRepositoryProvider);
  return repo.watchPeers();
});

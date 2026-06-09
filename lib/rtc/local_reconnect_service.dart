import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:pointycastle/export.dart';

import '../crypto/key_store.dart';
import '../crypto/rsa_cipher.dart';
import '../data/models/peer.dart';
import '../data/repositories/peer_repository.dart';
import '../signaling/ice_candidate_bundler.dart';
import 'peer_connection_pool.dart';
import 'rtc_manager.dart';

/// Diagnostic logging that is compiled out of release builds. Reconnect logs
/// include peer display names / ids / key hashes, so they must never reach
/// production logcat.
void _log(String message) {
  if (kDebugMode) debugPrint(message);
}

/// An in-flight answer to a peer's reconnect offer. The offer SDP is kept so a
/// re-broadcast of the *same* offer (we send each offer to several broadcast
/// addresses) is recognised and ignored, while a genuinely new offer from a
/// retry replaces the stale session.
class _AnswerSession {
  final String offerSdp;
  final RTCPeerConnection pc;
  _AnswerSession(this.offerSdp, this.pc);
}

/// Automatically re-establishes WebRTC connections to known peers on the
/// local network after an app restart, without requiring a new QR scan.
///
/// No key exchange is performed — both sides already know who they are talking
/// to (matched by SHA-256 key hash). The connection is registered directly with
/// the peer's real stored ID, preventing phantom/duplicate peer entries.
class LocalReconnectService {
  static final LocalReconnectService instance = LocalReconnectService._();
  LocalReconnectService._();

  static const int _port = 54321;

  RawDatagramSocket? _socket;
  PeerRepository? _peerRepository;
  String? _ownKeyHash;
  bool _started = false;

  /// Active outgoing offers, keyed by target peer's key hash.
  final _pendingByTarget = <String, RTCPeerConnection>{};

  /// Active incoming answers, keyed by the sender peer's key hash, so duplicate
  /// offer datagrams don't spawn (and leak) a second answer connection.
  final _answeringByPeer = <String, _AnswerSession>{};

  /// Peer ids with a reconnect attempt currently in flight. Drives the
  /// "Reconnecting…" indicator in the UI (peer list + open conversation).
  final _reconnecting = <String>{};
  final _reconnectTimers = <String, Timer>{};
  final _activityController = StreamController<void>.broadcast();

  /// How long a single attempt is surfaced as "reconnecting" before falling
  /// back to plain "offline" (until the supervisor's next retry). Comfortably
  /// longer than a normal LAN reconnect, shorter than the supervisor's max
  /// backoff, so a stuck attempt doesn't spin forever.
  static const _attemptTimeout = Duration(seconds: 15);

  /// How long an opened channel may take to complete the mutual auth handshake
  /// before it is torn down. Without this a peer that opens a channel but never
  /// answers the challenge would leave the connection dangling forever.
  static const _authTimeout = Duration(seconds: 10);

  /// Fires whenever the set of in-flight reconnect attempts changes.
  Stream<void> get onReconnectActivity => _activityController.stream;

  /// True while an automatic or manual reconnect attempt for [peerId] is live.
  bool isReconnecting(String peerId) => _reconnecting.contains(peerId);

  void _markReconnecting(String peerId) {
    final isNew = _reconnecting.add(peerId);
    _reconnectTimers[peerId]?.cancel();
    _reconnectTimers[peerId] = Timer(_attemptTimeout, () {
      _clearReconnecting(peerId);
    });
    if (isNew) _activityController.add(null);
  }

  void _clearReconnecting(String peerId) {
    _reconnectTimers.remove(peerId)?.cancel();
    if (_reconnecting.remove(peerId)) _activityController.add(null);
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  /// Bind the UDP socket and send offers to all known offline peers.
  /// Call from main() after Hive is initialized.
  Future<void> start({required PeerRepository peerRepository}) async {
    if (_started) return;
    _started = true;
    _peerRepository = peerRepository;

    try {
      final ownPublicKey = await KeyStore.instance.getOwnPublicKey();
      final ownPem = KeyStore.instance.exportPublicKeyPem(ownPublicKey);
      _ownKeyHash = _keyHash(ownPem);
      _log('[Reconnect] Own key hash: $_ownKeyHash');
    } catch (e, st) {
      _log('[Reconnect] Failed to compute own key hash: $e\n$st');
      _started = false;
      return;
    }

    if (!await _ensureSocket()) {
      // Bind failed (e.g. port momentarily in use). _ensureSocket is retried
      // on every reconnect attempt, so this is not fatal — just degraded.
      return;
    }

    try {
      final peers = await peerRepository.getAllPeers();
      _log('[Reconnect] Known peers: ${peers.length}');
      final offline = peers
          .where((p) => !PeerConnectionPool.instance.isOnline(p.id))
          .toList();
      _log(
          '[Reconnect] Sending offers to ${offline.length} offline peer(s)');
      for (final peer in offline) {
        _sendOffer(peer); // fire-and-forget
      }
    } catch (e, st) {
      _log(
          '[Reconnect] Failed to load peers for initial offers: $e\n$st');
    }
  }

  /// Binds (or re-binds) the UDP socket. Returns true when a listening socket
  /// is available. Called lazily so a failed bind at startup self-heals on the
  /// supervisor's next reconnect sweep instead of disabling reconnect until
  /// the next app launch.
  Future<bool> _ensureSocket() async {
    if (_socket != null) return true;
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        _port,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      socket.listen(_onDatagram);
      _socket = socket;
      _log('[Reconnect] UDP socket bound on port $_port');
      return true;
    } catch (e, st) {
      _log('[Reconnect] Socket bind failed: $e\n$st');
      return false;
    }
  }

  /// Manually trigger reconnect for a single offline peer (e.g. from UI button).
  Future<void> reconnectPeer(Peer peer) async {
    _log(
        '[Reconnect] Manual reconnect requested for ${peer.displayName}');
    if (!await _ensureSocket()) {
      _log('[Reconnect] Socket not ready — reconnect aborted');
      return;
    }
    if (PeerConnectionPool.instance.isOnline(peer.id)) {
      _log(
          '[Reconnect] ${peer.displayName} is already online — skipping');
      return;
    }
    await _sendOffer(peer);
  }

  Future<void> stop() async {
    _socket?.close();
    _socket = null;
    for (final pc in _pendingByTarget.values) {
      try {
        await pc.close();
      } catch (e) {
        _log('[Reconnect] stop: pc.close error: $e');
      }
    }
    _pendingByTarget.clear();
    for (final session in _answeringByPeer.values) {
      try {
        await session.pc.close();
      } catch (e) {
        _log('[Reconnect] stop: answer pc.close error: $e');
      }
    }
    _answeringByPeer.clear();
    for (final t in _reconnectTimers.values) {
      t.cancel();
    }
    _reconnectTimers.clear();
    final hadActivity = _reconnecting.isNotEmpty;
    _reconnecting.clear();
    if (hadActivity) _activityController.add(null);
    _started = false;
    _log('[Reconnect] Stopped');
  }

  // ── Mutual authentication ──────────────────────────────────────────────────

  /// Wire/protocol version of the reconnect auth handshake. v2 adds DTLS
  /// channel binding (see [_authenticateChannel]); it is incompatible with v1
  /// peers, which forces a re-pair when only one side has upgraded.
  static const int _authProtocolVersion = 2;

  /// Proves both peers hold the private key matching their stored public key,
  /// *and* that the authenticated peer is the one on the other end of this
  /// exact DTLS connection — not a relay — before the channel is trusted.
  ///
  /// Reconnect offers/answers travel unauthenticated over LAN UDP broadcast, so
  /// without this an attacker could spoof a known peer's presence or relay the
  /// handshake between two victims. Each side sends a fresh random nonce; the
  /// partner signs `nonce || channelBinding` (RSASSA/SHA-256) and we verify it
  /// against the peer's stored public key.
  ///
  /// The channel binding is a SHA-256 over the two DTLS certificate
  /// fingerprints (ours + the peer's, in canonical order). A direct connection
  /// yields the same binding on both ends; a relay must terminate DTLS with its
  /// own certificate on each leg, so the fingerprints — and the binding — no
  /// longer match, and the signature fails to verify. Confidentiality is
  /// already guaranteed by end-to-end encryption; this adds authenticity and
  /// relay resistance.
  ///
  /// The whole exchange must finish within [_authTimeout]; otherwise the
  /// channel and connection are closed so a silent partner cannot leave a
  /// half-trusted link (and its resources) dangling.
  Future<void> _authenticateChannel(RTCDataChannel dc, RTCPeerConnection pc,
      Peer peer, void Function() onSuccess) async {
    final RSAPrivateKey ownPriv;
    final RSAPublicKey peerPub;
    try {
      ownPriv = await KeyStore.instance.getOwnPrivateKey();
      peerPub = KeyStore.instance.importPublicKeyPem(peer.publicKeyPem);
    } catch (e) {
      _log('[Reconnect] auth setup failed for ${peer.displayName}: $e');
      unawaited(_closeQuietly(dc, pc));
      return;
    }

    // Our view of the DTLS channel binding. Both ends must agree on this for a
    // direct (non-relayed) connection.
    final cb = await _channelBinding(pc);
    final cbBytes = utf8.encode(cb);

    final rnd = Random.secure();
    final myNonce =
        Uint8List.fromList(List.generate(32, (_) => rnd.nextInt(256)));
    var done = false;

    final timeout = Timer(_authTimeout, () {
      if (done) return;
      done = true;
      _log('[Reconnect] ⏱ Auth timed out for ${peer.displayName} '
          '— closing channel');
      dc.onMessage = null;
      unawaited(_closeQuietly(dc, pc));
    });

    void fail(String why) {
      if (done) return;
      done = true;
      timeout.cancel();
      _log('[Reconnect] ❌ Auth failed for ${peer.displayName} ($why) '
          '— refusing to register');
      dc.onMessage = null;
      unawaited(_closeQuietly(dc, pc));
    }

    dc.onMessage = (msg) {
      if (msg.isBinary) return;
      try {
        final m = jsonDecode(msg.text) as Map<String, dynamic>;
        switch (m['type']) {
          case 'auth_challenge':
            final theirNonce = base64Decode(m['nonce'] as String);
            // Sign their nonce bound to our view of the channel.
            final toSign = Uint8List.fromList([...theirNonce, ...cbBytes]);
            final sig = RsaCipher.signWithPrivateKey(ownPriv, toSign);
            dc.send(RTCDataChannelMessage(jsonEncode({
              'type': 'auth_response',
              'sig': base64Encode(sig),
              'cb': cb,
              'v': _authProtocolVersion,
            })));
            break;
          case 'auth_response':
            if (done) return;
            // Reject anything that isn't the channel-bound v2 handshake (e.g.
            // an unupgraded v1 peer, or a relay that stripped the binding).
            if ((m['v'] as int?) != _authProtocolVersion) {
              fail('unsupported handshake version');
              return;
            }
            // Relay check: both ends must observe the same DTLS fingerprints.
            if ((m['cb'] as String?) != cb) {
              fail('channel binding mismatch');
              return;
            }
            final sig = base64Decode(m['sig'] as String);
            final signed = Uint8List.fromList([...myNonce, ...cbBytes]);
            if (RsaCipher.verifyWithPublicKey(peerPub, signed, sig)) {
              done = true;
              timeout.cancel();
              _log('[Reconnect] ✅ Authenticated ${peer.displayName}');
              dc.onMessage = null; // hand the channel back to the app layer
              onSuccess();
            } else {
              fail('signature mismatch');
            }
            break;
        }
      } catch (e) {
        _log('[Reconnect] auth message error: $e');
      }
    };

    dc.send(RTCDataChannelMessage(jsonEncode({
      'type': 'auth_challenge',
      'nonce': base64Encode(myNonce),
      'v': _authProtocolVersion,
    })));
  }

  /// Extracts the DTLS fingerprint from an SDP's `a=fingerprint` line.
  static String? _fingerprintFromSdp(String? sdp) {
    if (sdp == null) return null;
    final m =
        RegExp(r'a=fingerprint:\S+\s+([0-9A-Fa-f:]+)').firstMatch(sdp);
    return m?.group(1)?.toUpperCase();
  }

  /// Channel-binding tag for [pc]: SHA-256 over the local and remote DTLS
  /// fingerprints in canonical (sorted) order, so both ends derive the same
  /// value for a direct connection. Returns an empty string if the fingerprints
  /// can't be read, degrading to no binding rather than breaking reconnect
  /// (a relay can't force this path: a working DTLS connection always carries
  /// fingerprints).
  static Future<String> _channelBinding(RTCPeerConnection pc) async {
    try {
      final local = await pc.getLocalDescription();
      final remote = await pc.getRemoteDescription();
      final lf = _fingerprintFromSdp(local?.sdp);
      final rf = _fingerprintFromSdp(remote?.sdp);
      if (lf == null || rf == null) return '';
      final ordered = [lf, rf]..sort();
      final digest = SHA256Digest();
      final bytes = Uint8List.fromList(utf8.encode(ordered.join('|')));
      digest.update(bytes, 0, bytes.length);
      final out = Uint8List(digest.digestSize);
      digest.doFinal(out, 0);
      return base64Encode(out);
    } catch (e) {
      _log('[Reconnect] channel-binding computation failed: $e');
      return '';
    }
  }

  Future<void> _closeQuietly(RTCDataChannel? dc, RTCPeerConnection? pc) async {
    if (dc != null) {
      try {
        await dc.close();
      } catch (_) {}
    }
    if (pc != null) {
      try {
        await pc.close();
      } catch (_) {}
    }
  }

  // ── Key hash ───────────────────────────────────────────────────────────────

  static String _keyHash(String pem) {
    final digest = SHA256Digest();
    final bytes = Uint8List.fromList(utf8.encode(pem));
    digest.update(bytes, 0, bytes.length);
    final out = Uint8List(digest.digestSize);
    digest.doFinal(out, 0);
    // Full 256-bit hash. The previous 64-bit truncation left only ~8 bytes of
    // identifier, weak against collisions/spoofing on the local network.
    return out.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ── Initiator: send offer ──────────────────────────────────────────────────

  Future<void> _sendOffer(Peer targetPeer) async {
    final toPeerKeyHash = _keyHash(targetPeer.publicKeyPem);
    _log(
        '[Reconnect] _sendOffer → ${targetPeer.displayName} (targetHash=$toPeerKeyHash)');
    _markReconnecting(targetPeer.id);

    // Close and replace any stale pending offer
    final stale = _pendingByTarget.remove(toPeerKeyHash);
    if (stale != null) {
      _log('[Reconnect] Closing stale offer for ${targetPeer.displayName}');
      try {
        await stale.close();
      } catch (e) {
        _log('[Reconnect] stale pc.close error: $e');
      }
    }

    try {
      // LAN-only (no STUN): both peers are on this subnet by construction, and
      // host-only gathering completes in milliseconds instead of waiting up to
      // the bundler's hard deadline for a STUN round-trip.
      final pc = await RtcManager.instance.createPeerConnection(lanOnly: true);
      _log('[Reconnect] PeerConnection created for ${targetPeer.displayName}');

      final dc = await RtcManager.instance.createDataChannel(pc);

      dc.onDataChannelState = (state) {
        _log(
            '[Reconnect] DC state → $state (initiator → ${targetPeer.displayName})');
        if (state == RTCDataChannelState.RTCDataChannelOpen) {
          _pendingByTarget.remove(toPeerKeyHash);
          // Register only after the peer proves possession of its private key.
          _authenticateChannel(dc, pc, targetPeer, () {
            PeerConnectionPool.instance.register(targetPeer.id, pc, dc);
            _clearReconnecting(targetPeer.id);
            _log(
                '[Reconnect] ✅ Reconnected (initiator) to ${targetPeer.displayName} id=${targetPeer.id}');
          });
        }
      };

      pc.onConnectionState = (s) {
        _log(
            '[Reconnect] ConnectionState → $s (initiator → ${targetPeer.displayName})');
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          // This handler only lives until registration (register() replaces
          // it), so a failure here is always pre-trust: drop the attempt and
          // free the connection instead of leaking it.
          _pendingByTarget.remove(toPeerKeyHash);
          _clearReconnecting(targetPeer.id);
          unawaited(_closeQuietly(dc, pc));
          _log(
              '[Reconnect] Connection failed/disconnected for ${targetPeer.displayName}');
        }
      };
      pc.onIceConnectionState = (s) {
        _log(
            '[Reconnect] ICE state → $s (initiator → ${targetPeer.displayName})');
      };

      final bundler = IceCandidateBundler();
      pc.onIceCandidate = bundler.onCandidate;

      final offer = await pc.createOffer();
      await pc.setLocalDescription(offer);
      _log('[Reconnect] Offer created, waiting for ICE candidates...');

      final candidates = await bundler.candidates;
      _log(
          '[Reconnect] ICE gathering done: ${candidates.length} host candidate(s)');

      _pendingByTarget[toPeerKeyHash] = pc;

      await _broadcast({
        'type': 'reconnect_offer',
        'from_key_hash': _ownKeyHash,
        'to_key_hash': toPeerKeyHash,
        'sdp': offer.sdp,
        'ic': candidates.map((c) => jsonEncode(c.toMap())).toList(),
      });

      _log(
          '[Reconnect] ✉ Offer broadcast for ${targetPeer.displayName} with ${candidates.length} ICE candidate(s)');
    } catch (e, st) {
      _log(
          '[Reconnect] _sendOffer failed for ${targetPeer.displayName}: $e\n$st');
      _pendingByTarget.remove(toPeerKeyHash);
      _clearReconnecting(targetPeer.id);
    }
  }

  // ── Datagram handler ───────────────────────────────────────────────────────

  void _onDatagram(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final dg = _socket?.receive();
    if (dg == null) return;

    try {
      final msg = jsonDecode(utf8.decode(dg.data)) as Map<String, dynamic>;
      final type = msg['type'] as String?;
      if (type == 'reconnect_offer') {
        _log(
            '[Reconnect] Received reconnect_offer from ${dg.address.address}');
        _handleIncomingOffer(msg, dg.address);
      } else if (type == 'reconnect_answer') {
        _log(
            '[Reconnect] Received reconnect_answer from ${dg.address.address}');
        _handleIncomingAnswer(msg);
      }
    } catch (e, st) {
      _log('[Reconnect] _onDatagram parse error: $e\n$st');
    }
  }

  // ── Answerer: handle incoming offer ───────────────────────────────────────

  Future<void> _handleIncomingOffer(
    Map<String, dynamic> msg,
    InternetAddress senderAddress,
  ) async {
    final fromKeyHash = msg['from_key_hash'] as String?;
    final toKeyHash = msg['to_key_hash'] as String?;
    final sdp = msg['sdp'] as String?;
    final icList = (msg['ic'] as List?)?.cast<String>() ?? [];

    if (_ownKeyHash == null) {
      _log('[Reconnect] _ownKeyHash not set yet — ignoring offer');
      return;
    }
    if (toKeyHash != _ownKeyHash) {
      _log(
          '[Reconnect] Offer not for us (to=$toKeyHash, ours=$_ownKeyHash) — ignoring');
      return;
    }
    if (fromKeyHash == null || fromKeyHash == _ownKeyHash) {
      _log('[Reconnect] Offer is our own echo — ignoring');
      return;
    }
    if (sdp == null) {
      _log('[Reconnect] Offer missing sdp — ignoring');
      return;
    }

    // Each offer is sent to several broadcast addresses, so the same datagram
    // routinely arrives more than once. Answering twice would replace (and
    // break) the connection the initiator is already completing.
    final existing = _answeringByPeer[fromKeyHash];
    if (existing != null) {
      if (existing.offerSdp == sdp) {
        _log('[Reconnect] Duplicate offer datagram — already answering');
        return;
      }
      // A genuinely new offer (initiator retried): drop the stale session.
      _log('[Reconnect] New offer supersedes in-flight answer — replacing');
      _answeringByPeer.remove(fromKeyHash);
      unawaited(_closeQuietly(null, existing.pc));
    }

    final senderPeer = await _findPeerByKeyHash(fromKeyHash);
    if (senderPeer == null) {
      _log(
          '[Reconnect] Offer from unknown key hash $fromKeyHash — ignoring');
      return;
    }

    _log(
        '[Reconnect] Offer is from known peer ${senderPeer.displayName} (id=${senderPeer.id}) — processing');
    _markReconnecting(senderPeer.id);

    // Tiebreaker: both devices restarted simultaneously
    if (_pendingByTarget.containsKey(fromKeyHash)) {
      if (_ownKeyHash!.compareTo(fromKeyHash) < 0) {
        _log('[Reconnect] Tiebreaker: our offer wins — ignoring theirs');
        return;
      }
      _log('[Reconnect] Tiebreaker: their offer wins — cancelling ours');
      final ours = _pendingByTarget.remove(fromKeyHash);
      try {
        await ours?.close();
      } catch (e) {
        _log('[Reconnect] tiebreaker pc.close error: $e');
      }
    }

    try {
      final pc = await RtcManager.instance.createPeerConnection(lanOnly: true);
      _answeringByPeer[fromKeyHash] = _AnswerSession(sdp, pc);
      _log(
          '[Reconnect] PeerConnection created (answerer for ${senderPeer.displayName})');

      pc.onDataChannel = (dc) {
        _log(
            '[Reconnect] onDataChannel fired (answerer for ${senderPeer.displayName})');
        dc.onDataChannelState = (state) {
          _log(
              '[Reconnect] DC state → $state (answerer ← ${senderPeer.displayName})');
          if (state == RTCDataChannelState.RTCDataChannelOpen) {
            // Register only after mutual private-key proof.
            _authenticateChannel(dc, pc, senderPeer, () {
              _answeringByPeer.remove(fromKeyHash);
              PeerConnectionPool.instance.register(senderPeer.id, pc, dc);
              _clearReconnecting(senderPeer.id);
              _log(
                  '[Reconnect] ✅ Reconnected (answerer) to ${senderPeer.displayName} id=${senderPeer.id}');
            });
          }
        };
      };

      pc.onConnectionState = (s) {
        _log(
            '[Reconnect] ConnectionState → $s (answerer ← ${senderPeer.displayName})');
        if (s == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            s == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          // Pre-registration failure (register() replaces this handler):
          // free the session instead of leaking it.
          final session = _answeringByPeer[fromKeyHash];
          if (session != null && identical(session.pc, pc)) {
            _answeringByPeer.remove(fromKeyHash);
            unawaited(_closeQuietly(null, pc));
          }
          _clearReconnecting(senderPeer.id);
        }
      };
      pc.onIceConnectionState = (s) {
        _log(
            '[Reconnect] ICE state → $s (answerer ← ${senderPeer.displayName})');
      };

      final bundler = IceCandidateBundler();
      pc.onIceCandidate = bundler.onCandidate;

      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      _log(
          '[Reconnect] Remote description set, adding ${icList.length} ICE candidate(s)');

      for (final icJson in icList) {
        try {
          final m = jsonDecode(icJson) as Map<String, dynamic>;
          await pc.addCandidate(RTCIceCandidate(
            m['candidate'] as String?,
            m['sdpMid'] as String?,
            m['sdpMLineIndex'] as int?,
          ));
        } catch (e, st) {
          _log('[Reconnect] addCandidate error: $e\n$st');
        }
      }

      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);
      _log('[Reconnect] Answer created, waiting for ICE candidates...');

      final candidates = await bundler.candidates;
      _log(
          '[Reconnect] ICE gathering done: ${candidates.length} host candidate(s)');

      _unicast(
        {
          'type': 'reconnect_answer',
          'from_key_hash': _ownKeyHash,
          'to_key_hash': fromKeyHash,
          'sdp': answer.sdp,
          'ic': candidates.map((c) => jsonEncode(c.toMap())).toList(),
        },
        senderAddress,
      );

      _log(
          '[Reconnect] ✉ Answer sent to ${senderPeer.displayName} at ${senderAddress.address}');
    } catch (e, st) {
      _log(
          '[Reconnect] _handleIncomingOffer failed for ${senderPeer.displayName}: $e\n$st');
      final session = _answeringByPeer.remove(fromKeyHash);
      if (session != null) unawaited(_closeQuietly(null, session.pc));
      _clearReconnecting(senderPeer.id);
    }
  }

  // ── Initiator: handle incoming answer ─────────────────────────────────────

  Future<void> _handleIncomingAnswer(Map<String, dynamic> msg) async {
    final fromKeyHash = msg['from_key_hash'] as String?;
    final toKeyHash = msg['to_key_hash'] as String?;
    final sdp = msg['sdp'] as String?;
    final icList = (msg['ic'] as List?)?.cast<String>() ?? [];

    if (toKeyHash != _ownKeyHash) {
      _log('[Reconnect] Answer not for us — ignoring');
      return;
    }
    if (fromKeyHash == null || sdp == null) {
      _log('[Reconnect] Answer missing fromKeyHash or sdp — ignoring');
      return;
    }

    final pending = _pendingByTarget[fromKeyHash];
    if (pending == null) {
      _log(
          '[Reconnect] Answer from hash=$fromKeyHash but no pending offer — ignoring');
      return;
    }

    _log('[Reconnect] Processing answer from hash=$fromKeyHash');
    try {
      await pending.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      _log(
          '[Reconnect] Remote description set from answer, adding ${icList.length} ICE candidate(s)');

      for (final icJson in icList) {
        try {
          final m = jsonDecode(icJson) as Map<String, dynamic>;
          await pending.addCandidate(RTCIceCandidate(
            m['candidate'] as String?,
            m['sdpMid'] as String?,
            m['sdpMLineIndex'] as int?,
          ));
        } catch (e, st) {
          _log('[Reconnect] addCandidate (answer) error: $e\n$st');
        }
      }

      _pendingByTarget.remove(fromKeyHash);
      _log('[Reconnect] Answer processed, ICE connecting...');
    } catch (e, st) {
      _log('[Reconnect] _handleIncomingAnswer failed: $e\n$st');
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  Future<Peer?> _findPeerByKeyHash(String keyHash) async {
    try {
      final peers = await _peerRepository?.getAllPeers() ?? [];
      for (final p in peers) {
        if (_keyHash(p.publicKeyPem) == keyHash) return p;
      }
      _log('[Reconnect] _findPeerByKeyHash: no match for $keyHash');
      return null;
    } catch (e, st) {
      _log('[Reconnect] _findPeerByKeyHash error: $e\n$st');
      return null;
    }
  }

  /// Sends [payload] to the global broadcast address and to each interface's
  /// directed broadcast (assuming a /24, which covers typical home/office
  /// LANs). Many routers and APs silently drop 255.255.255.255, so relying on
  /// it alone made reconnect fail on those networks.
  Future<void> _broadcast(Map<String, dynamic> payload) async {
    _send(payload, InternetAddress('255.255.255.255'), _port);
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      final sent = <String>{};
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          final directed = '${parts[0]}.${parts[1]}.${parts[2]}.255';
          if (sent.add(directed)) {
            _send(payload, InternetAddress(directed), _port);
          }
        }
      }
    } catch (e) {
      _log('[Reconnect] directed broadcast enumeration failed: $e');
    }
  }

  void _unicast(Map<String, dynamic> payload, InternetAddress address) {
    _send(payload, address, _port);
  }

  void _send(Map<String, dynamic> payload, InternetAddress address, int port) {
    try {
      final bytes = utf8.encode(jsonEncode(payload));
      _socket?.send(bytes, address, port);
    } catch (e, st) {
      _log('[Reconnect] _send failed: $e\n$st');
    }
  }
}

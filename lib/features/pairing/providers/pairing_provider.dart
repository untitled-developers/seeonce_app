import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../../core/errors.dart';
import '../../../services/background_service.dart';
import '../../../rtc/key_exchange_handler.dart';
import '../../../rtc/peer_connection_pool.dart';
import '../../../rtc/rtc_manager.dart';
import '../../../signaling/ice_candidate_bundler.dart';
import '../../../signaling/signaling_service.dart';
import '../../../data/models/peer.dart';
import '../../peers/providers/peers_provider.dart';

// ── State ──────────────────────────────────────────────────────────────────

class PairingState {
  /// True while any async operation is in progress.
  final bool isGenerating;

  /// Human-readable description of the current async step (e.g. "Connecting…").
  final String? statusMessage;

  /// The offer QR code for the Initiator to display (Step 1).
  final String? ownOfferCode;

  /// The answer QR code for the Responder to display (Step 2).
  final String? ownAnswerCode;

  /// Set to the last error message on failure.
  final String? error;

  /// True once the WebRTC connection is up and key exchange has completed.
  final bool isPaired;

  const PairingState({
    this.isGenerating = false,
    this.statusMessage,
    this.ownOfferCode,
    this.ownAnswerCode,
    this.error,
    this.isPaired = false,
  });

  PairingState copyWith({
    bool? isGenerating,
    String? statusMessage,
    String? ownOfferCode,
    String? ownAnswerCode,
    String? error,
    bool? isPaired,
    bool clearStatusMessage = false,
    bool clearError = false,
    bool clearOfferCode = false,
    bool clearAnswerCode = false,
  }) =>
      PairingState(
        isGenerating: isGenerating ?? this.isGenerating,
        statusMessage:
            clearStatusMessage ? null : (statusMessage ?? this.statusMessage),
        ownOfferCode:
            clearOfferCode ? null : (ownOfferCode ?? this.ownOfferCode),
        ownAnswerCode:
            clearAnswerCode ? null : (ownAnswerCode ?? this.ownAnswerCode),
        error: clearError ? null : (error ?? this.error),
        isPaired: isPaired ?? this.isPaired,
      );
}

// ── Notifier ────────────────────────────────────────────────────────────────

class PairingNotifier extends StateNotifier<PairingState> {
  final Ref ref;

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  IceCandidateBundler? _bundler;
  KeyExchangeHandler? _kex;
  Timer? _connectionTimeout;

  PairingNotifier(this.ref) : super(const PairingState());

  /// Turns an exception into a short, user-presentable message without leaking
  /// internal/platform details or stack traces.
  String _friendly(Object e) {
    if (e is SeeOnceError) return e.message;
    final s = e.toString();
    const prefix = 'Exception: ';
    return s.startsWith(prefix) ? s.substring(prefix.length) : s;
  }

  // ── Step 1: Initiator generates offer ─────────────────────────────────────
  //
  //   QR code contains: peerId + displayName + SDP offer + host & srflx
  //   candidates (srflx enables cross-network pairing via STUN).
  //   No encryption keys are in the code; they are exchanged once the DC opens.

  Future<void> generateOffer() async {
    state = state.copyWith(
      isGenerating: true,
      statusMessage: 'Generating connection code…',
      clearError: true,
      clearOfferCode: true,
    );
    try {
      final ownPeerId = const Uuid().v4();
      final displayName = 'Me_${const Uuid().v4().substring(0, 4)}';

      _kex = KeyExchangeHandler(
          ownPeerId: ownPeerId, ownDisplayName: displayName);

      _pc = await RtcManager.instance.createPeerConnection();
      _dc = await RtcManager.instance.createDataChannel(_pc!);

      // ── Key exchange happens automatically when the DC opens ──────────────
      // This fires after the partner calls processAnswer() and the WebRTC
      // ICE negotiation succeeds — completely transparent to the user.
      _dc!.onDataChannelState = (s) {
        if (!mounted) return;
        if (s == RTCDataChannelState.RTCDataChannelOpen) {
          state = state.copyWith(
              isGenerating: true,
              statusMessage: 'Exchanging encryption keys…');
          _kex!.sendKey(_dc!);
        }
      };
      _dc!.onMessage = (msg) {
        if (!msg.isBinary) _handleKeyExchange(msg.text, _dc!);
      };

      // ICE gathering (host + srflx, up to ~5 s for the STUN round-trip)
      _bundler = IceCandidateBundler();
      _pc!.onIceCandidate = _bundler!.onCandidate;

      final offer = await _pc!.createOffer();
      await _pc!.setLocalDescription(offer);
      final candidates = await _bundler!.candidates;

      final offerCode = SignalingService.instance.createOfferCode(
        ownPeerId: ownPeerId,
        displayName: displayName,
        sdp: offer.sdp ?? '',
        bundledCandidates: candidates,
      );

      state = state.copyWith(
        isGenerating: false,
        ownOfferCode: offerCode,
        clearError: true,
        clearStatusMessage: true,
      );
    } catch (e) {
      state = state.copyWith(
        isGenerating: false,
        error: _friendly(e),
        clearOfferCode: true,
        clearStatusMessage: true,
      );
    }
  }

  // ── Step 2: Responder scans offer, generates answer ───────────────────────
  //
  //   Decodes the offer, sets up WebRTC, creates the answer code.
  //   Key exchange is configured via onDataChannel — it fires once the
  //   initiator calls processAnswer() and connectivity is established.

  Future<void> processOffer(String offerCode) async {
    state = state.copyWith(
      isGenerating: true,
      statusMessage: 'Processing offer…',
      clearError: true,
      clearAnswerCode: true,
    );
    try {
      final ownPeerId = const Uuid().v4();
      final displayName = 'Me_${const Uuid().v4().substring(0, 4)}';

      _kex = KeyExchangeHandler(
          ownPeerId: ownPeerId, ownDisplayName: displayName);
      _pc = await RtcManager.instance.createPeerConnection();

      // The initiator creates the data channel; we receive it here once the
      // WebRTC connection is established (after the initiator calls processAnswer).
      _pc!.onDataChannel = (dc) {
        if (!mounted) return;
        _dc = dc;
        _configureDcKeyExchange(dc);
        // If the DC is already open when we receive it, send immediately.
        if (dc.state == RTCDataChannelState.RTCDataChannelOpen) {
          state = state.copyWith(
              isGenerating: true,
              statusMessage: 'Exchanging encryption keys…');
          _kex!.sendKey(dc);
        }
      };

      // ICE gathering
      _bundler = IceCandidateBundler();
      _pc!.onIceCandidate = _bundler!.onCandidate;

      // Decode offer, apply remote SDP + candidates
      final payload = SignalingService.instance.decode(offerCode);
      if (payload.step != 'offer') throw Exception('Not an offer code');

      await _pc!
          .setRemoteDescription(RTCSessionDescription(payload.sdp, 'offer'));
      for (final cJson in payload.iceCandidates) {
        final m = jsonDecode(cJson) as Map<String, dynamic>;
        await _pc!.addCandidate(RTCIceCandidate(
            m['candidate'] as String?,
            m['sdpMid'] as String?,
            m['sdpMLineIndex'] as int?));
      }

      state = state.copyWith(statusMessage: 'Generating answer…');
      final answer = await _pc!.createAnswer();
      await _pc!.setLocalDescription(answer);
      final candidates = await _bundler!.candidates;

      final answerCode = SignalingService.instance.createAnswerCode(
        ownPeerId: ownPeerId,
        displayName: displayName,
        sdp: answer.sdp ?? '',
        bundledCandidates: candidates,
      );

      // Show the answer code. isPaired will be set by the key exchange callback
      // once the initiator scans this code and WebRTC connects.
      state = state.copyWith(
        isGenerating: false,
        ownAnswerCode: answerCode,
        clearError: true,
        clearStatusMessage: true,
      );
    } catch (e) {
      state = state.copyWith(
        isGenerating: false,
        error: _friendly(e),
        clearStatusMessage: true,
      );
    }
  }

  // ── Step 3: Initiator scans answer, completes handshake ───────────────────
  //
  //   Sets the remote description so ICE can match. The data channel then
  //   opens, triggering key exchange set up in generateOffer(). No further
  //   action is needed — isPaired is set by the key exchange callback.

  Future<void> processAnswer(String answerCode) async {
    state = state.copyWith(
      isGenerating: true,
      statusMessage: 'Connecting…',
      clearError: true,
    );
    try {
      if (_pc == null || _kex == null) {
        throw Exception(
            'No active offer found. Please generate a new code and try again.');
      }

      final payload = SignalingService.instance.decode(answerCode);
      if (payload.step != 'answer') throw Exception('Not an answer code');

      await _pc!
          .setRemoteDescription(RTCSessionDescription(payload.sdp, 'answer'));
      for (final cJson in payload.iceCandidates) {
        final m = jsonDecode(cJson) as Map<String, dynamic>;
        await _pc!.addCandidate(RTCIceCandidate(
            m['candidate'] as String?,
            m['sdpMid'] as String?,
            m['sdpMLineIndex'] as int?));
      }

      // isGenerating stays true — the key exchange callback (set in generateOffer)
      // will set isPaired=true when the DC opens and keys have been swapped.
      // A safety timeout prevents hanging forever.
      _scheduleConnectionTimeout();
    } catch (e) {
      state = state.copyWith(
        isGenerating: false,
        error: _friendly(e),
        clearStatusMessage: true,
      );
    }
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  /// Attaches key-exchange listeners to a [dc] received via [onDataChannel]
  /// (Responder path). Mirrors the setup done in [generateOffer] for the
  /// Initiator path.
  void _configureDcKeyExchange(RTCDataChannel dc) {
    dc.onDataChannelState = (s) {
      if (!mounted) return;
      if (s == RTCDataChannelState.RTCDataChannelOpen) {
        state = state.copyWith(
            isGenerating: true,
            statusMessage: 'Exchanging encryption keys…');
        _kex!.sendKey(dc);
      }
    };
    dc.onMessage = (msg) {
      if (!msg.isBinary) _handleKeyExchange(msg.text, dc);
    };
  }

  /// Called when any text message arrives on the data channel.
  /// Filters for key-exchange messages and finalises pairing if found.
  Future<void> _handleKeyExchange(String text, RTCDataChannel dc) async {
    if (!mounted) return;
    final peer = _kex?.onMessage(text);
    if (peer == null) return; // Not a key-exchange message; pass through.

    try {
      final repo = ref.read(peerRepositoryProvider);

      // If we already have a peer with this public key (e.g. after app restart),
      // reuse that peer entry so we don't create duplicates.
      final existing = await repo.findPeerByPublicKey(peer.publicKeyPem);
      final effectivePeer = existing != null
          ? Peer(
              id: existing.id,
              displayName: existing.displayName,
              publicKeyPem: existing.publicKeyPem,
              pairedAt: existing.pairedAt,
            )
          : peer;

      await repo.savePeer(effectivePeer);
      if (!mounted) return;
      if (_pc != null) {
        PeerConnectionPool.instance.register(effectivePeer.id, _pc!, dc);
      }
      _connectionTimeout?.cancel();
      // Now that we have a peer, keep the app connected in the background
      // (Android). Requests notification + battery-opt permission, then starts
      // the foreground service. No-op on iOS.
      unawaited(BackgroundService.instance
          .requestPermissions()
          .then((_) => BackgroundService.instance.start()));
      state = state.copyWith(
        isGenerating: false,
        isPaired: true,
        clearError: true,
        clearStatusMessage: true,
      );
    } catch (e) {
      if (!mounted) return;
      state = state.copyWith(
        isGenerating: false,
        error: 'Pairing failed: ${_friendly(e)}',
        clearStatusMessage: true,
      );
    }
  }

  /// Fails gracefully if the WebRTC connection never establishes within 30 s.
  /// Cancelable, so a successful pairing (or reset/dispose) stops it firing a
  /// spurious "timed out" error later.
  void _scheduleConnectionTimeout() {
    _connectionTimeout?.cancel();
    _connectionTimeout = Timer(const Duration(seconds: 30), () {
      if (!mounted || state.isPaired || !state.isGenerating) return;
      state = state.copyWith(
        isGenerating: false,
        clearStatusMessage: true,
        error: 'Connection timed out.\n'
            'Try again with both devices on the same Wi-Fi. Across different '
            'networks a direct connection is not always possible (for example '
            'on mobile data).',
      );
    });
  }

  void reset() {
    _connectionTimeout?.cancel();
    _connectionTimeout = null;
    state = const PairingState();
    _pc?.close();
    _pc = null;
    _dc = null;
    _bundler = null;
    _kex = null;
  }

  @override
  void dispose() {
    _connectionTimeout?.cancel();
    _pc?.close();
    super.dispose();
  }
}

// ── Provider ────────────────────────────────────────────────────────────────

final pairingProvider =
    StateNotifierProvider<PairingNotifier, PairingState>((ref) {
  return PairingNotifier(ref);
});

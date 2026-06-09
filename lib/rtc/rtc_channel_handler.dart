import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../core/constants.dart';

class _ChunkBuffer {
  final int totalChunks;
  final DateTime createdAt;
  final Map<int, Uint8List> chunks = {};
  int _receivedBytes = 0;

  _ChunkBuffer(this.totalChunks, this.createdAt);

  /// Adds a chunk if [index] is in range and not already present. Returns the
  /// new cumulative byte count, or -1 if the chunk was rejected.
  int addChunk(int index, Uint8List data) {
    if (index < 0 || index >= totalChunks) return -1; // out of range
    if (chunks.containsKey(index)) return _receivedBytes; // duplicate, ignore
    chunks[index] = data;
    _receivedBytes += data.length;
    return _receivedBytes;
  }

  int get receivedBytes => _receivedBytes;

  // Because addChunk only accepts unique in-range indices, having the full
  // count means every index in [0, totalChunks) is present.
  bool get isComplete => chunks.length == totalChunks;

  Uint8List assemble() {
    final builder = BytesBuilder();
    for (var i = 0; i < totalChunks; i++) {
      final chunk = chunks[i];
      if (chunk == null) {
        // Should be unreachable when isComplete is true, but never assert on
        // attacker-influenced data.
        throw StateError('Missing chunk $i during assembly');
      }
      builder.add(chunk);
    }
    return builder.toBytes();
  }
}

class RtcChannelHandler {
  final StreamController<Uint8List> _incomingPayloads =
      StreamController.broadcast();
  Stream<Uint8List> get incomingPayloads => _incomingPayloads.stream;

  final Map<String, _ChunkBuffer> _buffers = {};
  final Duration _bufferTtl;
  final int _maxPayloadBytes;
  Timer? _sweepTimer;

  RtcChannelHandler({Duration? bufferTtl, int? maxPayloadBytes})
      : _bufferTtl = bufferTtl ?? AppConstants.chunkBufferTtl,
        _maxPayloadBytes = maxPayloadBytes ?? AppConstants.maxPayloadBytes {
    // Periodically drop incomplete buffers from peers that never finish.
    _sweepTimer = Timer.periodic(_bufferTtl, (_) => sweepStaleBuffers());
  }

  Future<void> sendEncryptedPayload({
    required RTCDataChannel dc,
    required Uint8List encryptedPayload,
    required String messageId,
    required String senderId,
  }) async {
    final chunkSize = AppConstants.dataChannelChunkSize;
    final totalChunks = (encryptedPayload.length / chunkSize).ceil();

    // 1. Send Header
    final header = {
      'messageId': messageId,
      'totalChunks': totalChunks,
      'type': 'header',
    };
    await dc.send(RTCDataChannelMessage(jsonEncode(header)));

    // 2. Send Chunks
    for (var i = 0; i < totalChunks; i++) {
      final start = i * chunkSize;
      final end = (start + chunkSize > encryptedPayload.length)
          ? encryptedPayload.length
          : start + chunkSize;

      final chunkData = encryptedPayload.sublist(start, end);

      // Frame layout: [messageIdLength(1)][messageId(bytes)][chunkIndex(4)][chunkData]
      final msgIdBytes = utf8.encode(messageId);
      final builder = BytesBuilder();
      builder.addByte(msgIdBytes.length);
      builder.add(msgIdBytes);

      final indexData = ByteData(4);
      indexData.setInt32(0, i, Endian.big);
      builder.add(indexData.buffer.asUint8List());

      builder.add(chunkData);

      // Basic flow control: wait if buffer gets too large
      if (dc.bufferedAmount != null && dc.bufferedAmount! > 1024 * 1024 * 8) {
        // > 8MB
        await Future.delayed(const Duration(milliseconds: 100));
      }

      await dc.send(RTCDataChannelMessage.fromBinary(builder.toBytes()));
    }
  }

  void onMessage(RTCDataChannelMessage message) {
    if (!message.isBinary) {
      _handleTextMessage(message.text);
      return;
    }
    _handleBinaryChunk(message.binary);
  }

  void _handleTextMessage(String text) {
    try {
      final map = jsonDecode(text);
      if (map is Map && map['type'] == 'header') {
        final msgId = map['messageId'];
        final totalChunks = map['totalChunks'];
        // Validate everything coming off the wire before allocating anything.
        if (msgId is! String || msgId.isEmpty || totalChunks is! int) {
          return;
        }
        if (totalChunks <= 0 || totalChunks > AppConstants.maxChunks) {
          if (kDebugMode) {
            debugPrint('[RtcChannel] Rejecting header: totalChunks='
                '$totalChunks (max ${AppConstants.maxChunks})');
          }
          return;
        }
        _buffers[msgId] = _ChunkBuffer(totalChunks, DateTime.now());
      } else {
        // Some other JSON (e.g. an unpair control message). Emit as bytes.
        _incomingPayloads.add(Uint8List.fromList(utf8.encode(text)));
      }
    } catch (_) {
      // Not JSON / malformed — ignore.
    }
  }

  void _handleBinaryChunk(Uint8List bytes) {
    // Minimum frame is: 1 (len) + msgIdLength + 4 (index). Guard every read.
    if (bytes.length < 1 + 4) return;

    final msgIdLength = bytes[0];
    final headerLen = 1 + msgIdLength + 4;
    if (msgIdLength == 0 || bytes.length < headerLen) return;

    final String msgId;
    try {
      msgId = utf8.decode(bytes.sublist(1, 1 + msgIdLength));
    } catch (_) {
      return; // invalid utf8 in id
    }

    final buffer = _buffers[msgId];
    if (buffer == null) return; // unknown / already-completed / swept message

    final indexData = ByteData.sublistView(bytes, 1 + msgIdLength, headerLen);
    final chunkIndex = indexData.getInt32(0, Endian.big);
    final chunkData = bytes.sublist(headerLen);

    final received = buffer.addChunk(chunkIndex, chunkData);
    if (received < 0) {
      if (kDebugMode) {
        debugPrint('[RtcChannel] Dropping out-of-range chunk $chunkIndex '
            'for $msgId (totalChunks=${buffer.totalChunks})');
      }
      return;
    }
    if (received > _maxPayloadBytes) {
      // A peer is trying to exhaust memory — abandon the whole message.
      if (kDebugMode) {
        debugPrint('[RtcChannel] Payload for $msgId exceeded '
            '$_maxPayloadBytes bytes — dropping');
      }
      _buffers.remove(msgId);
      return;
    }

    if (buffer.isComplete) {
      _buffers.remove(msgId);
      try {
        _incomingPayloads.add(buffer.assemble());
      } catch (e) {
        if (kDebugMode) debugPrint('[RtcChannel] assemble failed: $e');
      }
    }
  }

  /// Drops incomplete buffers older than the configured TTL. Exposed for tests;
  /// also run periodically by an internal timer.
  @visibleForTesting
  void sweepStaleBuffers() {
    final now = DateTime.now();
    _buffers.removeWhere(
        (_, buf) => now.difference(buf.createdAt) >= _bufferTtl);
  }

  @visibleForTesting
  int get pendingBufferCount => _buffers.length;

  void dispose() {
    _sweepTimer?.cancel();
    _sweepTimer = null;
    _buffers.clear();
    _incomingPayloads.close();
  }
}

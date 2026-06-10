import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:seeonce_app/rtc/rtc_channel_handler.dart';
import 'package:seeonce_app/core/constants.dart';
import 'package:seeonce_app/core/errors.dart';

/// Minimal fake channel for exercising the send path without WebRTC.
class _FakeDc implements RTCDataChannel {
  _FakeDc({this.channelState = RTCDataChannelState.RTCDataChannelOpen});
  final RTCDataChannelState channelState;
  final List<RTCDataChannelMessage> sent = [];
  @override
  Future<void> send(RTCDataChannelMessage message) async => sent.add(message);
  @override
  int? get bufferedAmount => 0;
  @override
  RTCDataChannelState? get state => channelState;
  @override
  noSuchMethod(Invocation invocation) => null;
}

/// Builds the binary chunk message that [RtcChannelHandler.sendEncryptedPayload]
/// would produce, without needing a real [RTCDataChannel].
RTCDataChannelMessage buildChunkMessage({
  required String messageId,
  required int chunkIndex,
  required Uint8List chunkData,
}) {
  final msgIdBytes = utf8.encode(messageId);
  final builder = BytesBuilder();
  builder.addByte(msgIdBytes.length);
  builder.add(msgIdBytes);
  final indexData = ByteData(4)..setInt32(0, chunkIndex, Endian.big);
  builder.add(indexData.buffer.asUint8List());
  builder.add(chunkData);
  return RTCDataChannelMessage.fromBinary(builder.toBytes());
}

/// Builds the text header message.
RTCDataChannelMessage buildHeaderMessage({
  required String messageId,
  required int totalChunks,
}) {
  final header = jsonEncode({
    'messageId': messageId,
    'totalChunks': totalChunks,
    'type': 'header',
  });
  return RTCDataChannelMessage(header);
}

/// Splits [data] into chunks of [chunkSize] and returns all messages
/// (header + chunks) in send order.
List<RTCDataChannelMessage> buildMessages(
  Uint8List data,
  String messageId, {
  int chunkSize = AppConstants.dataChannelChunkSize,
}) {
  final totalChunks = (data.length / chunkSize).ceil();
  final messages = <RTCDataChannelMessage>[
    buildHeaderMessage(messageId: messageId, totalChunks: totalChunks),
  ];
  for (var i = 0; i < totalChunks; i++) {
    final start = i * chunkSize;
    final end =
        (start + chunkSize > data.length) ? data.length : start + chunkSize;
    messages.add(buildChunkMessage(
      messageId: messageId,
      chunkIndex: i,
      chunkData: data.sublist(start, end),
    ));
  }
  return messages;
}

void main() {
  group('RtcChannelHandler — onMessage reassembly', () {
    late RtcChannelHandler handler;

    setUp(() {
      handler = RtcChannelHandler();
    });

    tearDown(() {
      handler.dispose();
    });

    test('single-chunk payload reassembled correctly', () async {
      final data = Uint8List.fromList([1, 2, 3, 4, 5]);
      const msgId = 'single-chunk';
      final messages = buildMessages(data, msgId);

      final resultFuture = handler.incomingPayloads.first;
      for (final msg in messages) {
        handler.onMessage(msg);
      }
      final result = await resultFuture;
      expect(result, equals(data));
    });

    test('200 KB payload chunked and reassembled identically', () async {
      final data =
          Uint8List.fromList(List.generate(200 * 1024, (i) => i % 256));
      const msgId = 'large-payload';
      final messages = buildMessages(data, msgId);

      // ceil(200*1024 / 16384) = 13 chunks + 1 header = 14 messages
      expect(messages.length, equals(14));

      final resultFuture = handler.incomingPayloads.first;
      for (final msg in messages) {
        handler.onMessage(msg);
      }
      final result = await resultFuture;
      expect(result, equals(data));
    });

    test('chunk count matches ceil(size / chunkSize)', () {
      const chunkSize = AppConstants.dataChannelChunkSize;
      const payloadSize = 50000;
      final expectedChunks = (payloadSize / chunkSize).ceil();

      final data = Uint8List(payloadSize);
      final messages = buildMessages(data, 'id', chunkSize: chunkSize);

      // 1 header + N chunks
      expect(messages.length, equals(1 + expectedChunks));
    });

    test('two interleaved messages are both reassembled', () async {
      final data1 = Uint8List.fromList(List.generate(100, (i) => i));
      final data2 = Uint8List.fromList(List.generate(200, (i) => 255 - i));

      final msgs1 = buildMessages(data1, 'msg1');
      final msgs2 = buildMessages(data2, 'msg2');

      // Interleave: header1, header2, chunk1_0, chunk2_0
      final interleaved = [msgs1[0], msgs2[0], msgs1[1], msgs2[1]];

      final results = <Uint8List>[];
      handler.incomingPayloads.listen(results.add);

      for (final msg in interleaved) {
        handler.onMessage(msg);
      }

      // Give the stream time to emit
      await Future.delayed(Duration.zero);

      expect(results.length, equals(2));
    });
  });

  group('RtcChannelHandler — malformed/malicious input', () {
    late RtcChannelHandler handler;

    setUp(() {
      handler = RtcChannelHandler();
    });

    tearDown(() {
      handler.dispose();
    });

    test('header declaring more than maxChunks is rejected (no buffer)', () {
      handler.onMessage(buildHeaderMessage(
        messageId: 'evil',
        totalChunks: AppConstants.maxChunks + 1,
      ));
      expect(handler.pendingBufferCount, equals(0));
    });

    test('header with non-positive totalChunks is rejected', () {
      handler.onMessage(buildHeaderMessage(messageId: 'z', totalChunks: 0));
      handler.onMessage(buildHeaderMessage(messageId: 'n', totalChunks: -5));
      expect(handler.pendingBufferCount, equals(0));
    });

    test('truncated binary frame does not throw and emits nothing', () async {
      var emitted = false;
      handler.incomingPayloads.listen((_) => emitted = true);

      // 3 bytes: shorter than the minimum header (1 + 4).
      handler.onMessage(
          RTCDataChannelMessage.fromBinary(Uint8List.fromList([2, 65, 66])));
      // Frame claims msgIdLength=200 but is far shorter.
      final bogus = BytesBuilder()
        ..addByte(200)
        ..add(utf8.encode('ab'));
      handler.onMessage(
          RTCDataChannelMessage.fromBinary(bogus.toBytes()));

      await Future.delayed(Duration.zero);
      expect(emitted, isFalse);
    });

    test('out-of-range chunk index is dropped, message never completes',
        () async {
      var emitted = false;
      handler.incomingPayloads.listen((_) => emitted = true);

      handler.onMessage(buildHeaderMessage(messageId: 'm', totalChunks: 2));
      // Index 5 is out of range for a 2-chunk message.
      handler.onMessage(buildChunkMessage(
        messageId: 'm',
        chunkIndex: 5,
        chunkData: Uint8List.fromList([1, 2, 3]),
      ));

      await Future.delayed(Duration.zero);
      expect(emitted, isFalse);
    });

    test('duplicate chunk index does not corrupt or double-complete', () async {
      final results = <Uint8List>[];
      handler.incomingPayloads.listen(results.add);

      handler.onMessage(buildHeaderMessage(messageId: 'd', totalChunks: 2));
      final a = Uint8List.fromList([10, 11]);
      final b = Uint8List.fromList([20, 21]);
      handler.onMessage(
          buildChunkMessage(messageId: 'd', chunkIndex: 0, chunkData: a));
      // Duplicate of index 0 — must be ignored, not overwrite or count twice.
      handler.onMessage(buildChunkMessage(
          messageId: 'd', chunkIndex: 0, chunkData: Uint8List.fromList([99])));
      handler.onMessage(
          buildChunkMessage(messageId: 'd', chunkIndex: 1, chunkData: b));

      await Future.delayed(Duration.zero);
      expect(results.length, equals(1));
      expect(results.first, equals(Uint8List.fromList([10, 11, 20, 21])));
    });

    test('payload exceeding the max size is abandoned', () async {
      // Tiny cap so we do not allocate real megabytes in the test.
      final h = RtcChannelHandler(maxPayloadBytes: 8);
      var emitted = false;
      h.incomingPayloads.listen((_) => emitted = true);

      h.onMessage(buildHeaderMessage(messageId: 'big', totalChunks: 2));
      h.onMessage(buildChunkMessage(
        messageId: 'big',
        chunkIndex: 0,
        chunkData: Uint8List.fromList(List.filled(16, 7)), // already over cap
      ));

      await Future.delayed(Duration.zero);
      expect(emitted, isFalse);
      expect(h.pendingBufferCount, equals(0));
      h.dispose();
    });

    test('sending on a non-open channel fails fast with ConnectionError',
        () async {
      final h = RtcChannelHandler();
      final dc =
          _FakeDc(channelState: RTCDataChannelState.RTCDataChannelClosed);
      await expectLater(
        h.sendEncryptedPayload(
          dc: dc,
          encryptedPayload: Uint8List.fromList([1, 2, 3]),
          messageId: 'm',
          senderId: 's',
        ),
        throwsA(isA<ConnectionError>()),
      );
      expect(dc.sent, isEmpty, reason: 'nothing should be queued on a dead dc');
      h.dispose();
    });

    test('stale incomplete buffers are swept', () {
      final h = RtcChannelHandler(bufferTtl: Duration.zero);
      h.onMessage(buildHeaderMessage(messageId: 'stale', totalChunks: 3));
      h.onMessage(buildChunkMessage(
          messageId: 'stale', chunkIndex: 0, chunkData: Uint8List(2)));
      expect(h.pendingBufferCount, equals(1));

      h.sweepStaleBuffers(); // ttl is zero, so the buffer is immediately stale
      expect(h.pendingBufferCount, equals(0));
      h.dispose();
    });
  });
}

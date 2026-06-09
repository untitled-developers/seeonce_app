import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';
import 'package:seeonce_app/crypto/hybrid_cipher.dart';
import 'package:seeonce_app/data/models/text_envelope.dart';
import 'package:seeonce_app/data/models/text_message.dart';
import 'package:seeonce_app/features/conversation/providers/conversation_provider.dart';

AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey> _testKeyPair() {
  final secureRandom = FortunaRandom();
  secureRandom.seed(
      KeyParameter(Uint8List.fromList(List.generate(32, (i) => i * 7 + 13))));
  final keyGen = RSAKeyGenerator()
    ..init(ParametersWithRandom(
      RSAKeyGeneratorParameters(BigInt.parse('65537'), 1024, 12),
      secureRandom,
    ));
  final pair = keyGen.generateKeyPair();
  return AsymmetricKeyPair<RSAPublicKey, RSAPrivateKey>(
    pair.publicKey as RSAPublicKey,
    pair.privateKey as RSAPrivateKey,
  );
}

void main() {
  group('TextMessage expiry', () {
    const ttl = Duration(minutes: 30);
    final base = DateTime.utc(2026, 1, 1, 12, 0, 0);

    TextMessage at(DateTime localAt) => TextMessage(
        messageId: 'm', senderId: 's', text: 'hi', localAt: localAt, isMine: false);

    test('not expired within the TTL window', () {
      final msg = at(base);
      expect(msg.isExpired(base.add(const Duration(minutes: 29)), ttl), isFalse);
    });

    test('expired once past the TTL', () {
      final msg = at(base);
      expect(
          msg.isExpired(base.add(const Duration(minutes: 30, seconds: 1)), ttl),
          isTrue);
    });
  });

  group('ConversationNotifier ordering', () {
    test('orders by local timestamp regardless of insertion/sender order', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(conversationProvider.notifier);

      final base = DateTime.now();
      TextMessage m(String id, int sec, bool mine) => TextMessage(
            messageId: id,
            senderId: mine ? 'me' : 'peer',
            text: id,
            localAt: base.add(Duration(seconds: sec)),
            isMine: mine,
          );

      // Add out of order, mixing mine/theirs.
      notifier.addOutgoingText('p', m('second', 2, true));
      notifier.onTextReceived('p', m('first', 0, false));
      notifier.onTextReceived('p', m('third', 5, false));

      final ids = container
          .read(conversationProvider)
          .messagesByPeer['p']!
          .map((e) => e.messageId)
          .toList();
      expect(ids, equals(['first', 'second', 'third']));
    });
  });

  group('TextEnvelope encryption', () {
    late RSAPublicKey publicKey;
    late RSAPrivateKey privateKey;

    setUpAll(() {
      final pair = _testKeyPair();
      publicKey = pair.publicKey;
      privateKey = pair.privateKey;
    });

    test('encrypt -> envelope JSON -> decrypt round-trips the message', () async {
      const original = 'Hello, see once! مرحبا 👋';
      final encrypted = await HybridCipher.encrypt(
          publicKey, Uint8List.fromList(utf8.encode(original)));

      final envelope = TextEnvelope(
        messageId: 'id-1',
        senderId: 'peer-1',
        encryptedKey: base64Encode(encrypted.encryptedKey),
        iv: base64Encode(encrypted.iv),
        ciphertext: base64Encode(encrypted.ciphertext),
        sentAt: DateTime.utc(2026, 1, 1).toIso8601String(),
      );

      // Serialise and parse back, as it would travel over the channel.
      final parsed = TextEnvelope.fromJson(
          jsonDecode(jsonEncode(envelope.toJson())) as Map<String, dynamic>);
      expect(parsed.type, equals('text'));

      final decrypted = await HybridCipher.decrypt(
        privateKey,
        base64Decode(parsed.encryptedKey),
        base64Decode(parsed.iv),
        base64Decode(parsed.ciphertext),
      );
      expect(utf8.decode(decrypted), equals(original));
    });
  });
}

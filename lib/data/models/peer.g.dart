// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'peer.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class PeerAdapter extends TypeAdapter<Peer> {
  @override
  final int typeId = 0;

  @override
  Peer read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Peer(
      id: fields[0] as String,
      displayName: fields[1] as String,
      publicKeyPem: fields[2] as String,
      pairedAt: fields[3] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, Peer obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.displayName)
      ..writeByte(2)
      ..write(obj.publicKeyPem)
      ..writeByte(3)
      ..write(obj.pairedAt);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PeerAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

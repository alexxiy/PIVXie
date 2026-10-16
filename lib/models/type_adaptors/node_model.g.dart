// GENERATED CODE - DO NOT MODIFY BY HAND

part of '../node_model.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class NodeModelAdapter extends TypeAdapter<NodeModel> {
  @override
  final int typeId = 12;

  @override
  NodeModel read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return NodeModel(
      host: fields[1] as String,
      port: fields[2] as int,
      name: fields[3] as String,
      id: fields[0] as String,
      useSSL: fields[4] as bool,
      coinName: fields[7] as String,
      torEnabled: fields[11] as bool? ?? true,
      clearnetEnabled: fields[12] as bool? ?? true,
      isPrimary: fields[14] as bool? ?? false,
    );
  }

  @override
  void write(BinaryWriter writer, NodeModel obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.host)
      ..writeByte(2)
      ..write(obj.port)
      ..writeByte(3)
      ..write(obj.name)
      ..writeByte(4)
      ..write(obj.useSSL)
      ..writeByte(7)
      ..write(obj.coinName)
      ..writeByte(11)
      ..write(obj.torEnabled)
      ..writeByte(12)
      ..write(obj.clearnetEnabled)
      ..writeByte(14)
      ..write(obj.isPrimary);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NodeModelAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

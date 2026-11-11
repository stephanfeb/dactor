import 'dart:typed_data';

import 'package:dactor/dactor.dart';

/// Thrown when a message is sent to another node and its type has no codec.
class UnregisteredMessageType implements Exception {
  final Type type;
  const UnregisteredMessageType(this.type);

  @override
  String toString() => 'UnregisteredMessageType: no codec is registered for '
      '$type, so it cannot be sent to another node';
}

/// Thrown when a frame names a message type or version this node has no
/// decoder for.
class UnknownMessageType implements Exception {
  final String typeId;
  final int version;
  const UnknownMessageType(this.typeId, this.version);

  @override
  String toString() =>
      'UnknownMessageType: no decoder for "$typeId" version $version';
}

/// What a codec may use while it encodes or decodes one message.
abstract interface class CodecContext {
  /// The wire form of [ref]. Works for local and remote references alike;
  /// a local one is turned into a reference other nodes can use.
  Object? encodeRef(ActorRef ref);

  /// The reference behind a value made by [encodeRef].
  ActorRef decodeRef(Object? data);

  /// The wire form of a value of any registered or plain type, for
  /// messages that contain other messages.
  Object? encodeValue(Object? value);

  /// The value behind a result of [encodeValue].
  Object? decodeValue(Object? data);
}

class _Codec {
  final String typeId;
  final int version;
  final Object? Function(Object? value, CodecContext context) encode;
  final Object? Function(Object? data, CodecContext context) decode;
  _Codec(this.typeId, this.version, this.encode, this.decode);
}

/// Maps message types to their wire forms.
///
/// The wire form of a message is a tree of plain values: null, bool, int,
/// double, String, `Uint8List`, and lists and maps of those. Messages that
/// are plain values already need no codec. Every other type that is to
/// cross to another node must be registered, by its exact class:
///
/// ```dart
/// codecs.register<OrderPlaced>('OrderPlaced',
///     encode: (m, _) => {1: m.orderId, 2: m.amount},
///     decode: (data, _) {
///       final map = data as Map;
///       return OrderPlaced(map[1] as String, map[2] as double);
///     });
/// ```
///
/// To change a type's shape, register the new shape under a higher
/// [version] and keep the old one registered with [registerDecoder], so
/// that nodes still running the old code can be understood.
class CodecRegistry {
  final _byType = <Type, _Codec>{};
  final _byId = <(String, int), _Codec>{};

  /// Registers how [T] is written and read. Replaces an earlier
  /// registration of [T] for writing; decoders for other versions stay.
  void register<T>(
    String typeId, {
    int version = 1,
    required Object? Function(T value, CodecContext context) encode,
    required T Function(Object? data, CodecContext context) decode,
  }) {
    if (typeId.isEmpty || typeId.startsWith('@')) {
      throw ArgumentError.value(
          typeId, 'typeId', 'must not be empty or start with @');
    }
    _add<T>(typeId, version, encode, decode);
  }

  /// Registers how to read an older [version] of a type, without changing
  /// how it is written.
  void registerDecoder(String typeId, int version,
      Object? Function(Object? data, CodecContext context) decode) {
    _byId[(typeId, version)] = _Codec(typeId, version, (_, __) {
      throw StateError('"$typeId" version $version can only be decoded');
    }, decode);
  }

  void _add<T>(
      String typeId,
      int version,
      Object? Function(T value, CodecContext context) encode,
      T Function(Object? data, CodecContext context) decode) {
    final codec = _Codec(
        typeId, version, (value, ctx) => encode(value as T, ctx), decode);
    _byType[T] = codec;
    _byId[(typeId, version)] = codec;
  }

  /// Whether [value] needs no codec.
  static bool isPlain(Object? value, [int depth = 0]) {
    if (depth > 64) return false;
    return switch (value) {
      null || bool() || int() || double() || String() || Uint8List() => true,
      List<Object?> list => list.every((item) => isPlain(item, depth + 1)),
      Map<Object?, Object?> map => map.entries.every((entry) =>
          isPlain(entry.key, depth + 1) && isPlain(entry.value, depth + 1)),
      _ => false,
    };
  }

  /// The wire form of [value]: its type id, version and data. The type id
  /// is empty for a plain value.
  (String, int, Object?) encode(Object? value, CodecContext context) {
    if (value is ActorRef) return ('@ref', 1, context.encodeRef(value));
    if (value is CallFailure) return ('@callFailure', 1, '${value.error}');
    final codec = _byType[value.runtimeType];
    if (codec != null) {
      return (codec.typeId, codec.version, codec.encode(value, context));
    }
    if (isPlain(value)) return ('', 1, value);
    throw UnregisteredMessageType(value.runtimeType);
  }

  Object? decode(
      String typeId, int version, Object? data, CodecContext context) {
    switch (typeId) {
      case '':
        return data;
      case '@ref':
        return context.decodeRef(data);
      case '@callFailure':
        return CallFailure(RemoteActorError(data as String));
    }
    final codec = _byId[(typeId, version)];
    if (codec == null) throw UnknownMessageType(typeId, version);
    return codec.decode(data, context);
  }
}

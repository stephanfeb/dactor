import 'dart:convert';
import 'dart:typed_data';

/// A small CBOR (RFC 8949) encoder and decoder, covering what dactor's wire
/// format uses: null, booleans, integers, doubles, text, bytes, lists and
/// maps.
///
/// Encoding is deterministic for a given value: integers take their shortest
/// form, doubles are always 64-bit, map entries keep insertion order.
///
/// Decoding accepts any well-formed definite-length CBOR built from those
/// types, plus 16- and 32-bit floats and tags (the tag is dropped). It
/// rejects indefinite lengths, and it never trusts a length it has not
/// checked against the bytes that are actually there, so hostile input
/// cannot make it allocate more than the input's own size.

Uint8List cborEncode(Object? value) {
  final out = BytesBuilder(copy: false);
  _encode(value, out, 0);
  return out.takeBytes();
}

/// Decodes one value that must span all of [bytes].
Object? cborDecode(Uint8List bytes, {int maxDepth = 64}) {
  final reader = _Reader(bytes, maxDepth);
  final value = reader.read(0);
  if (reader.offset != bytes.length) {
    throw const FormatException('Trailing bytes after CBOR value');
  }
  return value;
}

void _head(BytesBuilder out, int major, int value) {
  final m = major << 5;
  if (value < 24) {
    out.addByte(m | value);
  } else if (value < 0x100) {
    out
      ..addByte(m | 24)
      ..addByte(value);
  } else if (value < 0x10000) {
    out
      ..addByte(m | 25)
      ..addByte(value >> 8)
      ..addByte(value & 0xff);
  } else if (value < 0x100000000) {
    out.addByte(m | 26);
    for (var shift = 24; shift >= 0; shift -= 8) {
      out.addByte((value >> shift) & 0xff);
    }
  } else {
    out.addByte(m | 27);
    for (var shift = 56; shift >= 0; shift -= 8) {
      out.addByte((value >> shift) & 0xff);
    }
  }
}

void _encode(Object? value, BytesBuilder out, int depth) {
  if (depth > 64) throw ArgumentError('Value is nested too deeply to encode');
  switch (value) {
    case null:
      out.addByte(0xf6);
    case true:
      out.addByte(0xf5);
    case false:
      out.addByte(0xf4);
    case int n:
      // -1 - n for negatives; ~n is the same thing without overflow.
      n >= 0 ? _head(out, 0, n) : _head(out, 1, ~n);
    case double d:
      out.addByte(0xfb);
      out.add((ByteData(8)..setFloat64(0, d)).buffer.asUint8List());
    case String s:
      final bytes = utf8.encode(s);
      _head(out, 3, bytes.length);
      out.add(bytes);
    case Uint8List bytes:
      _head(out, 2, bytes.length);
      out.add(bytes);
    case List<Object?> list:
      _head(out, 4, list.length);
      for (final item in list) {
        _encode(item, out, depth + 1);
      }
    case Map<Object?, Object?> map:
      _head(out, 5, map.length);
      for (final entry in map.entries) {
        _encode(entry.key, out, depth + 1);
        _encode(entry.value, out, depth + 1);
      }
    default:
      throw ArgumentError.value(
          value, 'value', 'A ${value.runtimeType} has no CBOR form');
  }
}

class _Reader {
  final Uint8List bytes;
  final int maxDepth;
  late final ByteData data =
      ByteData.sublistView(bytes); // honours a view's offset
  int offset = 0;

  _Reader(this.bytes, this.maxDepth);

  int get remaining => bytes.length - offset;

  int byte() {
    if (offset >= bytes.length) throw const FormatException('Truncated CBOR');
    return bytes[offset++];
  }

  void need(int count) {
    if (count < 0 || count > remaining) {
      throw const FormatException('CBOR length exceeds the input');
    }
  }

  /// The argument of a head byte with additional information [info].
  int argument(int info) {
    if (info < 24) return info;
    switch (info) {
      case 24:
        return byte();
      case 25:
        need(2);
        final v = data.getUint16(offset);
        offset += 2;
        return v;
      case 26:
        need(4);
        final v = data.getUint32(offset);
        offset += 4;
        return v;
      case 27:
        need(8);
        final v = data.getInt64(offset);
        offset += 8;
        if (v < 0) {
          throw const FormatException('CBOR integer does not fit in 64 bits');
        }
        return v;
      default:
        throw const FormatException(
            'Indefinite-length or reserved CBOR is not supported');
    }
  }

  Object? read(int depth) {
    if (depth > maxDepth) {
      throw const FormatException('CBOR is nested too deeply');
    }
    final head = byte();
    final major = head >> 5;
    final info = head & 0x1f;
    switch (major) {
      case 0:
        return argument(info);
      case 1:
        return ~argument(info);
      case 2:
        final length = argument(info);
        need(length);
        final result = Uint8List.fromList(
            Uint8List.sublistView(bytes, offset, offset + length));
        offset += length;
        return result;
      case 3:
        final length = argument(info);
        need(length);
        final result =
            utf8.decode(Uint8List.sublistView(bytes, offset, offset + length));
        offset += length;
        return result;
      case 4:
        final length = argument(info);
        // Every item takes at least one byte.
        need(length);
        return [for (var i = 0; i < length; i++) read(depth + 1)];
      case 5:
        final length = argument(info);
        if (length > remaining ~/ 2) {
          throw const FormatException('CBOR length exceeds the input');
        }
        final map = <Object?, Object?>{};
        for (var i = 0; i < length; i++) {
          final key = read(depth + 1);
          map[key] = read(depth + 1);
        }
        return map;
      case 6:
        argument(info); // the tag itself
        return read(depth + 1);
      default:
        switch (info) {
          case 20:
            return false;
          case 21:
            return true;
          case 22 || 23:
            return null;
          case 25:
            need(2);
            final half = data.getUint16(offset);
            offset += 2;
            return _halfToDouble(half);
          case 26:
            need(4);
            final v = data.getFloat32(offset);
            offset += 4;
            return v;
          case 27:
            need(8);
            final v = data.getFloat64(offset);
            offset += 8;
            return v;
          default:
            throw FormatException('Unsupported CBOR simple value $info');
        }
    }
  }
}

double _halfToDouble(int half) {
  final exponent = (half >> 10) & 0x1f;
  final mantissa = half & 0x3ff;
  double value;
  if (exponent == 0) {
    value = mantissa * 5.960464477539063e-8; // 2^-24
  } else if (exponent != 31) {
    value = (mantissa + 1024) * 5.960464477539063e-8 * (1 << (exponent - 1));
  } else {
    value = mantissa == 0 ? double.infinity : double.nan;
  }
  return (half & 0x8000) != 0 ? -value : value;
}

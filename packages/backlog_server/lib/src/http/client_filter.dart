import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:backlog_api/backlog_api.dart';
import 'package:shelf/shelf.dart';

/// An address or a CIDR range of client addresses: `10.77.11.22`,
/// `10.77.0.0/16`, `::1`, `fd00::/8`.
final class AddressRange {
  AddressRange._(this._network, this._prefixLength);

  /// Throws [FormatException] on anything else than an IP address with an
  /// optional `/prefix`.
  factory AddressRange.parse(String text) {
    final [address, ...prefix] = text.trim().split('/');
    final parsed = InternetAddress.tryParse(address);
    if (parsed == null || prefix.length > 1) throw FormatException('Not an IP address or CIDR range: $text');
    final bits = parsed.rawAddress.length * 8;
    final length = prefix.isEmpty ? bits : int.tryParse(prefix.single);
    if (length == null || length < 0 || length > bits) throw FormatException('Bad prefix length in $text');
    return AddressRange._(parsed.rawAddress, length);
  }

  final Uint8List _network;
  final int _prefixLength;

  bool contains(InternetAddress address) {
    final raw = _unmapped(address.rawAddress);
    if (raw.length != _network.length) return false;
    for (var bit = 0; bit < _prefixLength; bit++) {
      final mask = 0x80 >> (bit % 8);
      if (raw[bit ~/ 8] & mask != _network[bit ~/ 8] & mask) return false;
    }
    return true;
  }

  /// `::ffff:10.0.0.1` (IPv4 on a dual-stack socket) as plain IPv4.
  static Uint8List _unmapped(Uint8List raw) {
    if (raw.length != 16) return raw;
    for (var i = 0; i < 10; i++) {
      if (raw[i] != 0) return raw;
    }
    if (raw[10] != 0xff || raw[11] != 0xff) return raw;
    return Uint8List.sublistView(raw, 12);
  }
}

/// Answers 403 to clients outside [allowed]. Requests without connection
/// info (in-memory tests) pass.
Middleware allowClients(List<AddressRange> allowed) =>
    (inner) => (request) {
      final connection = request.context['shelf.io.connection_info'];
      if (connection is! HttpConnectionInfo || allowed.any((range) => range.contains(connection.remoteAddress))) {
        return inner(request);
      }
      return Response(
        403,
        body: jsonEncode(
          BacklogApiException(403, 'forbidden', 'Client ${connection.remoteAddress.address} is not allowed.').toJson(),
        ),
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    };

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../../infrastructure/backlog_layout.dart';
import '../../items/domain/item_id.dart';
import '../domain/claim.dart';

/// Claims as `.locks/<id>.lock` JSON files.
///
/// Acquiring relies on exclusive file creation (O_EXCL), which the OS makes
/// atomic, so it is safe for agents running in parallel on one machine. It is
/// not meant for network file systems; a multi-user server needs a store on
/// top of a database instead.
final class FileSystemClaimStore implements ClaimStore {
  FileSystemClaimStore(this._layout, {required this.defaultLease});

  final BacklogLayout _layout;

  /// Assumed for lock files that cannot be read (e.g. caught mid-write).
  final Duration defaultLease;
  final _random = Random();

  @override
  Future<List<Claim>> all() async {
    final dir = Directory(_layout.locksDir);
    if (!await dir.exists()) return const [];
    final claims = <Claim>[];
    await for (final entity in dir.list()) {
      final name = p.basename(entity.path);
      if (entity is! File || !name.endsWith('.lock')) continue;
      final ItemId id;
      try {
        id = ItemId(name.substring(0, name.length - '.lock'.length));
      } on Exception {
        continue;
      }
      final claim = await _read(id, entity);
      if (claim != null) claims.add(claim);
    }
    return claims..sort((a, b) => a.itemId.compareTo(b.itemId));
  }

  @override
  Future<Claim?> find(ItemId id) => _read(id, _file(id));

  @override
  Future<bool> tryAcquire(Claim claim) async {
    final file = _file(claim.itemId);
    await file.parent.create(recursive: true);
    try {
      await file.create(exclusive: true);
    } on FileSystemException {
      if (await file.exists()) return false;
      rethrow;
    }
    await file.writeAsString(_encode(claim), flush: true);
    return true;
  }

  @override
  Future<bool> tryReplace(Claim expired, Claim replacement) async {
    final file = _file(expired.itemId);
    // Moving the lock aside is atomic: of several agents taking over the same
    // expired claim, only one rename succeeds.
    final aside = File('${file.path}.${pid}_${_random.nextInt(1 << 32)}.stale');
    try {
      await file.rename(aside.path);
    } on FileSystemException {
      return false;
    }
    final moved = await _read(expired.itemId, aside);
    if (moved == null || !moved.sameAs(expired)) {
      // We moved a lock someone created after we looked; put it back.
      if (!await file.exists()) await aside.rename(file.path);
      return false;
    }
    await aside.delete();
    return tryAcquire(replacement);
  }

  @override
  Future<void> refresh(Claim claim) => writeAtomically(_file(claim.itemId), _encode(claim));

  @override
  Future<void> remove(ItemId id) async {
    final file = _file(id);
    if (await file.exists()) await file.delete();
  }

  File _file(ItemId id) => File(p.join(_layout.locksDir, '${id.value}.lock'));

  Future<Claim?> _read(ItemId id, File file) async {
    final String text;
    final DateTime modified;
    try {
      text = await file.readAsString();
      modified = await file.lastModified();
    } on FileSystemException {
      return null;
    }
    try {
      final json = jsonDecode(text) as Map<String, Object?>;
      return Claim(
        itemId: id,
        agent: json['agent'] as String,
        claimedAt: DateTime.parse(json['claimed_at'] as String),
        heartbeatAt: DateTime.parse(json['heartbeat_at'] as String),
        lease: Duration(minutes: (json['lease_minutes'] as num).toInt()),
      );
    } on Object {
      // Created but not written yet, or edited by hand: still a claim.
      return Claim(itemId: id, agent: '(unknown)', claimedAt: modified, heartbeatAt: modified, lease: defaultLease);
    }
  }

  static String _encode(Claim claim) =>
      '${const JsonEncoder.withIndent('  ').convert({'item': claim.itemId.value, 'agent': claim.agent, 'claimed_at': claim.claimedAt.toUtc().toIso8601String(), 'heartbeat_at': claim.heartbeatAt.toUtc().toIso8601String(), 'lease_minutes': claim.lease.inMinutes})}\n';
}

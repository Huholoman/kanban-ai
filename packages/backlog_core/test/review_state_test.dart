import 'dart:io';

import 'package:backlog_core/backlog_core.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('ReviewState', () {
    const ok = '### w3 · 2026-10-31 10:00:00 UTC · review ok @1a2b3c4d5e6f\n\nFine.\n';
    const changes = '### w3 · 2026-10-31 11:00:00 UTC · review changes @1a2b3c4d5e6f\n\n1. a\n2. b\n3. c\n';
    const noCommit = '### tobik · 2026-10-31 11:00:00 UTC · review changes\n\nFix it.\n';
    Item reviewed(String comments, {String? branch}) =>
        item('T-1', status: 'review', body: '## Discussion\n\n$comments').copyWith(branch: () => branch);
    BranchHead head(String commit, [int hour = 9]) =>
        BranchHead(commit: commit, committedAt: DateTime.utc(2026, 10, 31, hour));

    test('follows the latest review; newer commits on the branch make it stale', () {
      expect(ReviewState.of(item('T-1'), null), ReviewState.none);
      expect(ReviewState.of(reviewed(ok), null), ReviewState.ok);
      expect(ReviewState.of(reviewed('$ok\n$changes'), null), ReviewState.changes);
      expect(ReviewState.of(reviewed('$changes\n$ok'), head('1a2b3c4d5e6f00112233')), ReviewState.ok);
      expect(ReviewState.of(reviewed(changes), head('ffff3c4d5e6f00112233')), ReviewState.stale);
      // Without a commit in the review, the commit time decides.
      expect(ReviewState.of(reviewed(noCommit), head('ffff', 10)), ReviewState.changes);
      expect(ReviewState.of(reviewed(noCommit), head('ffff', 12)), ReviewState.stale);
      expect(ReviewState.parse('changes'), ReviewState.changes);
      expect(ReviewState.parse('nope'), ReviewState.none);
    });

    test('the snapshot looks up the head of the item\'s branch, a field and filters by it', () {
      final heads = {'agent/T-1': head('ffff'), 'feat/x': head('1a2b3c4d5e6f')};
      BacklogSnapshot snapshot(Item item) => BacklogSnapshot.build(
        items: [item],
        workflow: Workflow.standard(),
        now: DateTime.utc(2026, 10, 31, 12),
        branchHeads: heads,
      );
      final stale = snapshot(reviewed(changes)).items.single;
      expect((stale.review, stale.reviewFindings), (ReviewState.stale, 3));
      final current = snapshot(reviewed(changes, branch: 'feat/x')).items.single;
      expect((current.review, current.reviewFindings), (ReviewState.changes, 3));
      expect(ItemFields.valuesOf(current, 'review'), ['changes']);
      expect(snapshot(reviewed(ok, branch: 'feat/x')).items.single.reviewFindings, 0);
      expect(snapshotOf([item('T-2')]).items.single.review, ReviewState.none);
    });

    test('GitBranchHeads reads the branches of the first folder that is a repository', () async {
      final dir = await Directory.systemTemp.createTemp('branch_heads_');
      addTearDown(() => dir.delete(recursive: true));
      Future<String> git(List<String> args) async {
        final result = await Process.run('git', [
          '-c',
          'user.name=T',
          '-c',
          'user.email=t@example.com',
          ...args,
        ], workingDirectory: dir.path);
        expect(result.exitCode, 0, reason: '${result.stderr}');
        return '${result.stdout}'.trim();
      }

      await git(['init', '-q', '-b', 'main']);
      await git(['commit', '-q', '--allow-empty', '-m', 'one']);
      await git(['branch', 'agent/T-1']);
      await git(['tag', 'agent/T-1']); // an ambiguous short name does not matter
      final heads = await GitBranchHeads([p.join(dir.path, 'missing'), dir.path]).heads();
      expect(heads.keys, unorderedEquals(['main', 'agent/T-1']));
      expect(heads['agent/T-1']!.commit, await git(['rev-parse', 'HEAD']));
      expect(heads['main']!.committedAt.difference(DateTime.now()).inMinutes.abs(), lessThan(5));
      expect(await GitBranchHeads([p.join(dir.path, 'missing')]).heads(), isEmpty);
      final notGit = await Directory.systemTemp.createTemp('no_git_');
      addTearDown(() => notGit.delete(recursive: true));
      expect(await GitBranchHeads([notGit.path]).heads(), isEmpty);
    });
  });
}

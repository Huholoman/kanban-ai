import 'package:backlog_app/app/draft_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  setUp(() => SharedPreferencesAsyncPlatform.instance = InMemorySharedPreferencesAsync.empty());

  test('drafts are kept in the platform preferences and outlast the app', () async {
    final store = await draftStore();
    store.write('a/Q-1/reply', 'Half a thought');
    expect(store.read('a/Q-1/reply'), 'Half a thought');
    await pumpEventQueue();

    final reopened = await draftStore();
    expect(reopened.read('a/Q-1/reply'), 'Half a thought');
    reopened.write('a/Q-1/reply', ' ');
    expect(reopened.read('a/Q-1/reply'), isNull);
    await pumpEventQueue();
    expect((await draftStore()).read('a/Q-1/reply'), isNull);
  });
}

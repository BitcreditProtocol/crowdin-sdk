import 'dart:async';

import 'package:crowdin_sdk/src/real_time_preview/crowdin_preview_session.dart';
import 'package:crowdin_sdk/src/real_time_preview/crowdin_preview_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('starts disabled and deduplicates activation attempts', () async {
    final activation = Completer<void>();
    var startCalls = 0;
    final session = CrowdinPreviewSession(
      start: () {
        startCalls++;
        return activation.future;
      },
    );

    expect(session.state.value.status, CrowdinPreviewStatus.disabled);

    final first = session.enable();
    final second = session.enable();

    expect(identical(first, second), isTrue);
    expect(startCalls, 1);
    expect(session.state.value.status, CrowdinPreviewStatus.authenticating);

    activation.complete();
    await Future.wait([first, second]);

    expect(session.state.value.status, CrowdinPreviewStatus.connected);

    await session.enable();
    expect(startCalls, 1);
  });

  test('exposes failures and allows retrying', () async {
    var startCalls = 0;
    final session = CrowdinPreviewSession(
      start: () async {
        startCalls++;
        if (startCalls == 1) throw StateError('authentication failed');
      },
    );

    await expectLater(session.enable(), throwsStateError);

    expect(session.state.value.status, CrowdinPreviewStatus.error);
    expect(session.state.value.error, isA<StateError>());

    await session.enable();

    expect(startCalls, 2);
    expect(session.state.value.status, CrowdinPreviewStatus.connected);
  });

  test('reports connection errors after authentication', () {
    final session = CrowdinPreviewSession(start: () async {});

    session.markError(StateError('socket failed'));

    expect(session.state.value.status, CrowdinPreviewStatus.error);
    expect(session.state.value.error, isA<StateError>());
  });

  test('does not overwrite a connection error with stale activation', () async {
    final activation = Completer<void>();
    final session = CrowdinPreviewSession(start: () => activation.future);

    final enable = session.enable();
    session.markError(StateError('socket failed'));
    activation.complete();
    await enable;

    expect(session.state.value.status, CrowdinPreviewStatus.error);
  });

  test('cancels activation and ignores its eventual completion', () async {
    final activation = Completer<void>();
    var cancelCalls = 0;
    final session = CrowdinPreviewSession(
      start: () => activation.future,
      cancel: () async => cancelCalls++,
    );

    final enable = session.enable();
    await session.cancel();

    expect(cancelCalls, 1);
    expect(session.state.value.status, CrowdinPreviewStatus.disabled);

    activation.complete();
    await enable;

    expect(session.state.value.status, CrowdinPreviewStatus.disabled);
  });

  test(
    'reports subscription progress during activation and language changes',
    () async {
      final activation = Completer<void>();
      final session = CrowdinPreviewSession(start: () => activation.future);

      final enable = session.enable();
      session.updateSubscriptionProgress(
        languageCode: 'en',
        completed: 12,
        total: 60,
      );

      expect(session.state.value.status, CrowdinPreviewStatus.authenticating);
      expect(session.state.value.subscriptionLanguageCode, 'en');
      expect(session.state.value.subscriptionsCompleted, 12);
      expect(session.state.value.subscriptionsTotal, 60);

      activation.complete();
      await enable;

      session.updateSubscriptionProgress(
        languageCode: 'es',
        completed: 20,
        total: 60,
      );

      expect(session.state.value.status, CrowdinPreviewStatus.connected);
      expect(session.state.value.subscriptionLanguageCode, 'es');
      expect(session.state.value.isSubscribing, isTrue);

      session.markSubscriptionsReady();

      expect(session.state.value.status, CrowdinPreviewStatus.connected);
      expect(session.state.value.isSubscribing, isFalse);
    },
  );
}

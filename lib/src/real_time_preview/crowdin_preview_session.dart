import 'package:flutter/foundation.dart';

import 'crowdin_preview_state.dart';

class CrowdinPreviewSession {
  CrowdinPreviewSession({
    required Future<void> Function() start,
    Future<void> Function()? cancel,
  })  : _start = start,
        _cancel = cancel;

  final Future<void> Function() _start;
  final Future<void> Function()? _cancel;
  final ValueNotifier<CrowdinPreviewState> state =
      ValueNotifier(const CrowdinPreviewState.disabled());

  Future<void>? _activation;

  Future<void> enable() {
    if (state.value.status == CrowdinPreviewStatus.connected) {
      return Future.value();
    }

    final activation = _activation;
    if (activation != null) return activation;

    state.value = const CrowdinPreviewState.authenticating();

    late final Future<void> trackedActivation;
    trackedActivation = Future.sync(_start).then((_) {
      if (identical(_activation, trackedActivation)) {
        state.value = const CrowdinPreviewState.connected();
      }
    }).catchError((Object error) {
      if (identical(_activation, trackedActivation)) {
        state.value = CrowdinPreviewState.error(error);
      }
      throw error;
    }).whenComplete(() {
      if (identical(_activation, trackedActivation)) {
        _activation = null;
      }
    });
    _activation = trackedActivation;

    return trackedActivation;
  }

  Future<void> cancel() async {
    if (state.value.status != CrowdinPreviewStatus.authenticating) return;

    _activation = null;
    state.value = const CrowdinPreviewState.disabled();
    await _cancel?.call();
  }

  void markError(Object error) {
    _activation = null;
    state.value = CrowdinPreviewState.error(error);
  }

  void updateSubscriptionProgress({
    required String languageCode,
    required int completed,
    required int total,
  }) {
    final status = state.value.status;
    if (status != CrowdinPreviewStatus.authenticating &&
        status != CrowdinPreviewStatus.connected) {
      return;
    }

    state.value = CrowdinPreviewState.subscriptionProgress(
      status: status,
      languageCode: languageCode,
      completed: completed,
      total: total,
    );
  }

  void markSubscriptionsReady() {
    if (state.value.status == CrowdinPreviewStatus.connected) {
      state.value = const CrowdinPreviewState.connected();
    }
  }
}

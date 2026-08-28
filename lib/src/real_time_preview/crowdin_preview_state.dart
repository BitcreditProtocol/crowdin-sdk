import 'package:flutter/foundation.dart';

enum CrowdinPreviewStatus {
  disabled,
  authenticating,
  connected,
  error,
}

@immutable
class CrowdinPreviewState {
  const CrowdinPreviewState._(
    this.status, {
    this.error,
    this.subscriptionLanguageCode,
    this.subscriptionsCompleted,
    this.subscriptionsTotal,
  });

  const CrowdinPreviewState.disabled() : this._(CrowdinPreviewStatus.disabled);

  const CrowdinPreviewState.authenticating()
      : this._(CrowdinPreviewStatus.authenticating);

  const CrowdinPreviewState.connected()
      : this._(CrowdinPreviewStatus.connected);

  const CrowdinPreviewState.error(Object error)
      : this._(CrowdinPreviewStatus.error, error: error);

  const CrowdinPreviewState.subscriptionProgress({
    required CrowdinPreviewStatus status,
    required String languageCode,
    required int completed,
    required int total,
  }) : this._(
          status,
          subscriptionLanguageCode: languageCode,
          subscriptionsCompleted: completed,
          subscriptionsTotal: total,
        );

  final CrowdinPreviewStatus status;
  final Object? error;
  final String? subscriptionLanguageCode;
  final int? subscriptionsCompleted;
  final int? subscriptionsTotal;

  bool get isSubscribing =>
      subscriptionLanguageCode != null &&
      subscriptionsCompleted != null &&
      subscriptionsTotal != null;
}

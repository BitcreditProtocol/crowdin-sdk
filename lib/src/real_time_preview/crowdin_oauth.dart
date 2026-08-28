import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:crowdin_sdk/src/exceptions/crowdin_exceptions.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:url_launcher/url_launcher.dart';

import 'crowdin_auth_config.dart';

const String _kAuthorizationEndpoint =
    'https://accounts.crowdin.com/oauth/authorize';
const String _kTokenEndpoint = 'https://accounts.crowdin.com/oauth/token';
const Duration _kAuthorizationTimeout = Duration(minutes: 5);

class CrowdinOauth {
  final CrowdinAuthConfig config;

  CrowdinOauth(this.config);

  StreamSubscription? _sub;
  Future<oauth2.Credentials>? _authentication;
  Completer<oauth2.Credentials>? _completer;

  Future<oauth2.Credentials> authenticate() {
    return _authentication ??= _authenticate();
  }

  Future<oauth2.Credentials> _authenticate() async {
    final authorizationEndpoint = Uri.parse(_kAuthorizationEndpoint);
    final tokenEndpoint = Uri.parse(_kTokenEndpoint);
    final completer = Completer<oauth2.Credentials>();
    _completer = completer;

    final grant = oauth2.AuthorizationCodeGrant(
      config.clientId,
      authorizationEndpoint,
      tokenEndpoint,
      secret: config.clientSecret,
      basicAuth: false,
    );
    final authorizationUrl = grant.getAuthorizationUrl(
      Uri.parse(config.redirectUri),
      scopes: ['project.translation:read'],
    );

    void completeWithError(Object error, StackTrace stackTrace) {
      dispose();
      if (!completer.isCompleted) {
        completer.completeError(error, stackTrace);
      }
    }

    _sub = AppLinks().uriLinkStream.listen(
      (Uri uri) async {
        if (!uri.toString().startsWith(config.redirectUri)) return;

        try {
          final client =
              await grant.handleAuthorizationResponse(uri.queryParameters);
          dispose();
          if (!completer.isCompleted) {
            completer.complete(client.credentials);
          }
        } catch (error, stackTrace) {
          completeWithError(error, stackTrace);
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        completeWithError(error, stackTrace);
      },
    );

    try {
      final launched = await launchUrl(
        authorizationUrl,
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        throw CrowdinException('Could not open Crowdin authorization.');
      }
    } catch (error, stackTrace) {
      completeWithError(error, stackTrace);
    }

    try {
      return await completer.future.timeout(_kAuthorizationTimeout);
    } on TimeoutException {
      dispose();
      rethrow;
    } finally {
      if (identical(_completer, completer)) {
        _completer = null;
      }
    }
  }

  void cancel() {
    final completer = _completer;
    dispose();
    if (completer != null && !completer.isCompleted) {
      completer.completeError(
        CrowdinException('Crowdin authorization was canceled.'),
      );
    }
  }

  void dispose() {
    final subscription = _sub;
    _sub = null;
    if (subscription != null) {
      unawaited(subscription.cancel());
    }
  }
}

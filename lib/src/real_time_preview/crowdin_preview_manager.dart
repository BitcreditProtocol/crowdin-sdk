import 'dart:async';
import 'dart:convert';

import 'package:crowdin_sdk/crowdin_sdk.dart';
import 'package:crowdin_sdk/src/common/gen_l10n_types.dart';
import 'package:crowdin_sdk/src/crowdin_api.dart';
import 'package:crowdin_sdk/src/crowdin_logger.dart';
import 'package:crowdin_sdk/src/crowdin_mapper.dart';
import 'package:crowdin_sdk/src/exceptions/crowdin_exceptions.dart';
import 'package:flutter/cupertino.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'crowdin_oauth.dart';

class CrowdinPreviewManager {
  final CrowdinAuthConfig config;
  final String distributionHash;
  final List<String> mappingFilePaths;
  Function(String key)? _onTranslationUpdate;
  void Function(Object error, StackTrace stackTrace)? _onConnectionError;
  void Function(String languageCode, int completed, int total)?
      _onSubscriptionProgress;
  void Function()? _onSubscriptionsReady;

  CrowdinOauth? _auth;
  final CrowdinApi _api;
  final WebSocketChannel Function(Uri uri) _connectWebSocketFn;
  final CrowdinOauth Function(CrowdinAuthConfig config) _createAuth;
  late oauth2.Credentials _credentials;

  WebSocketChannel? _channel;
  StreamSubscription? _channelSubscription;
  Future<void>? _startFuture;
  int _startGeneration = 0;
  bool _connected = false;
  bool _intentionalClose = false;
  final Set<String> _subscribedEvents = {};
  final Set<String> _subscribedLanguageCodes = {};
  final Map<String, Future<void>> _subscriptionsInFlight = {};

  Map<String, String> finalMapping = {};

  _CrowdinMetadata? _metadata;

  CrowdinPreviewManager({
    required this.config,
    required this.distributionHash,
    required this.mappingFilePaths,
    @visibleForTesting CrowdinApi? api,
    @visibleForTesting WebSocketChannel Function(Uri uri)? connectWebSocket,
    @visibleForTesting
    CrowdinOauth Function(CrowdinAuthConfig config)? createAuth,
  })  : _api = api ?? CrowdinApi(),
        _connectWebSocketFn = connectWebSocket ?? WebSocketChannel.connect,
        _createAuth = createAuth ?? CrowdinOauth.new;

  AppResourceBundle? _previewArb;

  AppResourceBundle get previewArb {
    final previewArb = _previewArb;
    if (previewArb == null) {
      throw CrowdinException(
        'Translations must be loaded before enabling real-time preview.',
      );
    }
    return previewArb;
  }

  // set preview arb when locale changes
  void setPreviewArb(AppResourceBundle distributionArb) {
    _previewArb = distributionArb;

    if (_connected) {
      unawaited(
        _subscribeToAllTranslations().catchError(
          (Object error, StackTrace stackTrace) {
            _connected = false;
            _subscribedEvents.clear();
            _subscribedLanguageCodes.clear();
            _subscriptionsInFlight.clear();
            _onConnectionError?.call(error, stackTrace);
          },
        ),
      );
    }
  }

  Future<void> start({
    required Function(String key) onTranslationUpdate,
    required void Function(Object error, StackTrace stackTrace)
        onConnectionError,
    required void Function(String languageCode, int completed, int total)
        onSubscriptionProgress,
    required void Function() onSubscriptionsReady,
  }) {
    if (_connected) return Future.value();

    final startFuture = _startFuture;
    if (startFuture != null) return startFuture;

    final generation = ++_startGeneration;
    late final Future<void> trackedStart;
    trackedStart = _start(
      onTranslationUpdate: onTranslationUpdate,
      onConnectionError: onConnectionError,
      onSubscriptionProgress: onSubscriptionProgress,
      onSubscriptionsReady: onSubscriptionsReady,
      generation: generation,
    ).whenComplete(() {
      if (identical(_startFuture, trackedStart)) {
        _startFuture = null;
      }
    });
    _startFuture = trackedStart;

    return trackedStart;
  }

  Future<void> _start({
    required Function(String key) onTranslationUpdate,
    required void Function(Object error, StackTrace stackTrace)
        onConnectionError,
    required void Function(String languageCode, int completed, int total)
        onSubscriptionProgress,
    required void Function() onSubscriptionsReady,
    required int generation,
  }) async {
    _onTranslationUpdate = onTranslationUpdate;
    _onConnectionError = onConnectionError;
    _onSubscriptionProgress = onSubscriptionProgress;
    _onSubscriptionsReady = onSubscriptionsReady;

    if (finalMapping.isEmpty) {
      for (String path in mappingFilePaths) {
        var mappingData = await _api.getMapping(
          distributionHash: distributionHash,
          mappingFilePath: path,
        );
        _ensureStartIsActive(generation);
        if (mappingData != null) {
          finalMapping = getFinalMappingData(mappingData, finalMapping);
        }
      }
    }

    _auth?.dispose();
    final auth = _createAuth(config);
    _auth = auth;
    final credentials = await auth.authenticate();
    _ensureStartIsActive(generation);
    await _onAuthenticated(credentials, generation: generation);
  }

  void _ensureStartIsActive(int generation) {
    if (generation != _startGeneration) {
      throw CrowdinException('Crowdin preview activation was canceled.');
    }
  }

  Future<void> cancelStart() async {
    _startGeneration++;
    final startFuture = _startFuture;

    _auth?.cancel();
    _auth = null;
    _connected = false;
    _intentionalClose = true;
    _subscribedEvents.clear();
    _subscribedLanguageCodes.clear();
    _subscriptionsInFlight.clear();

    await _channelSubscription?.cancel();
    _channelSubscription = null;
    await _channel?.sink.close();
    _channel = null;

    if (startFuture != null) {
      try {
        await startFuture;
      } catch (_) {
        // Cancellation intentionally completes the in-flight activation.
      }
    }
  }

  // sort only needed key-value pairs
  Map<String, String> getFinalMappingData(
      Map<String, dynamic> mappingData, Map<String, String> currentMap) {
    var data = mappingData;
    Map<String, String> finalMappingData = currentMap;
    data.removeWhere((key, value) => key.startsWith('@'));
    data.forEach((key, value) {
      finalMappingData[key] = value.toString();
    });
    return finalMappingData;
  }

  Future<void> _onAuthenticated(
    oauth2.Credentials credentials, {
    required int generation,
  }) async {
    _credentials = credentials;
    await _getMetadata(credentials: credentials);
    _ensureStartIsActive(generation);
    await _connectWebSocket(
      credentials: credentials,
      generation: generation,
    );
  }

  Future<void> _getMetadata({required oauth2.Credentials credentials}) async {
    var metadataResp = await _api.getMetadata(
      accessToken: credentials.accessToken,
      distributionHash: distributionHash,
      organizationName: config.organizationName,
    );
    if (metadataResp != null) {
      var metadata = _CrowdinMetadata.fromJson(metadataResp);
      _metadata = metadata;
    } else {
      throw CrowdinException(
          "Can't receive metadata. Real-time preview will be unavailable");
    }
  }

  Future<void> _connectWebSocket({
    required oauth2.Credentials credentials,
    required int generation,
  }) async {
    await _channelSubscription?.cancel();
    await _channel?.sink.close();
    _subscribedEvents.clear();
    _subscribedLanguageCodes.clear();
    _subscriptionsInFlight.clear();
    _intentionalClose = false;

    final channel = _connectWebSocketFn(Uri.parse(_metadata!.wsUrl));
    _channel = channel;
    Stream crowdinStream = channel.stream;
    _channelSubscription = crowdinStream.listen(
      (message) {
        Map<String, dynamic> messageDecoded = jsonDecode(message);
        Map<String, dynamic> data = messageDecoded['data'];
        String event = messageDecoded['event'];
        final rawId = event.split(':').last;
        // WebSocket event format ends with "tr{<id>}" but finalMapping values
        // are plain "<id>" — strip the tr{...} wrapper so the lookup matches.
        String textId = rawId.startsWith('tr{') && rawId.endsWith('}')
            ? rawId.substring(3, rawId.length - 1)
            : rawId;
        CrowdinLogger.printLog(
          'Crowdin real-time preview update received for translation $textId',
        );
        updatePreviewArb(
          id: textId,
          text: data['text'] ?? '',
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        _connected = false;
        _subscribedEvents.clear();
        _subscribedLanguageCodes.clear();
        _subscriptionsInFlight.clear();
        _onConnectionError?.call(error, stackTrace);
      },
      onDone: () {
        if (_intentionalClose) return;
        _connected = false;
        _subscribedEvents.clear();
        _subscribedLanguageCodes.clear();
        _subscriptionsInFlight.clear();
        _onConnectionError?.call(
          CrowdinException(
            'Crowdin real-time preview connection closed unexpectedly.',
          ),
          StackTrace.current,
        );
      },
    );

    await _subscribeToAllTranslations(generation: generation);
    _ensureStartIsActive(generation);
    _connected = true;
  }

  Future<String?> _getWebsocketTicket({
    required oauth2.Credentials credentials,
    required String event,
  }) async {
    return _api.getWebsocketTicket(
      accessToken: credentials.accessToken,
      event: event,
      organizationName: config.organizationName,
    );
  }

  Future<void> _subscribeToAllTranslations({int? generation}) async {
    final previewArb = _previewArb;
    if (previewArb == null) {
      throw CrowdinException(
        'Translations must be loaded before enabling real-time preview.',
      );
    }

    final previewLocale = previewArb.locale;
    final langCode = CrowdinMapper.toCrowdinLanguageCode(
      Locale.fromSubtags(
        languageCode: previewLocale.languageCode,
        scriptCode: previewLocale.scriptCode,
        countryCode: previewLocale.countryCode,
      ),
    );
    if (_metadata == null) {
      CrowdinLogger.printLog(
          'Something went wrong when subscribing to translations for real-time preview. Metadata is not provided');
    } else {
      if (_subscribedLanguageCodes.contains(langCode)) {
        _onSubscriptionsReady?.call();
        return;
      }

      final inFlight = _subscriptionsInFlight[langCode];
      if (inFlight != null) return inFlight;

      late final Future<void> trackedSubscription;
      trackedSubscription = _subscribeToLanguage(
        langCode: langCode,
        generation: generation,
      ).whenComplete(() {
        if (identical(_subscriptionsInFlight[langCode], trackedSubscription)) {
          _subscriptionsInFlight.remove(langCode);
        }
      });
      _subscriptionsInFlight[langCode] = trackedSubscription;
      return trackedSubscription;
    }
  }

  Future<void> _subscribeToLanguage({
    required String langCode,
    int? generation,
  }) async {
    final metadata = _metadata!;
    final events = finalMapping.values
        .map(
          (id) =>
              'update-draft:${metadata.wsHash}:pr{${metadata.projectId}}:us{${metadata.userId}}:$langCode:tr{$id}',
        )
        .where((event) => !_subscribedEvents.contains(event))
        .toList();
    final total = events.length;
    var completed = 0;
    var allTicketsCreated = true;

    CrowdinLogger.printLog(
      'Subscribing to $total Crowdin real-time preview translations for $langCode',
    );
    _onSubscriptionProgress?.call(langCode, completed, total);

    for (final event in events) {
      final ticket =
          await _getWebsocketTicket(credentials: _credentials, event: event);
      if (generation != null) {
        _ensureStartIsActive(generation);
      }
      if (ticket != null) {
        final data = jsonEncode({
          'action': 'subscribe',
          'ticket': ticket,
          'event': event,
        });
        _channel?.sink.add(data);
        _subscribedEvents.add(event);
      } else {
        allTicketsCreated = false;
        CrowdinLogger.printLog(
          'Something went wrong when subscribing to real-time preview translations. WebSocket ticket is not provided',
        );
      }

      completed++;
      _onSubscriptionProgress?.call(langCode, completed, total);
    }

    if (!allTicketsCreated) {
      throw CrowdinException(
        'Crowdin real-time preview subscription failed for $langCode: '
        'could not create a WebSocket ticket for one or more translations.',
      );
    }

    _subscribedLanguageCodes.add(langCode);
    CrowdinLogger.printLog(
      'Crowdin real-time preview subscriptions ready for $langCode',
    );
    _onSubscriptionsReady?.call();
  }

  // update preview arb when translation change received
  @visibleForTesting
  void updatePreviewArb({
    required String id,
    required String text,
  }) {
    final previewArb = _previewArb;
    if (previewArb == null) return;

    final textKey = finalMapping.keys.cast<String?>().firstWhere(
          (key) => finalMapping[key] == id,
          orElse: () => null,
        );
    if (textKey == null) return;

    previewArb.resources[textKey] = text;
    if (_onTranslationUpdate != null) {
      _onTranslationUpdate!('');
    }
  }

  Future<void> dispose() async {
    _connected = false;
    _intentionalClose = true;
    _startFuture = null;
    _subscribedEvents.clear();
    _subscribedLanguageCodes.clear();
    _subscriptionsInFlight.clear();
    _auth?.dispose();
    await _channelSubscription?.cancel();
    await _channel?.sink.close();
    _channelSubscription = null;
    _channel = null;
  }
}

class _CrowdinMetadata {
  late String projectId;
  late String wsHash;
  late String userId;
  late String wsUrl;

  _CrowdinMetadata(
    this.projectId,
    this.wsHash,
    this.userId,
    this.wsUrl,
  );

  _CrowdinMetadata.fromJson(Map<String, dynamic> json) {
    projectId = json['data']['project']['id'] ?? '';
    wsHash = json['data']['project']['wsHash'] ?? '';
    userId = json['data']['user']['id'] ?? '';
    wsUrl = json['data']['wsUrl'] ?? '';
  }
}

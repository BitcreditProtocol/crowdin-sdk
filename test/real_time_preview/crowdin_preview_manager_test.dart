import 'dart:async';
import 'dart:convert';

import 'package:crowdin_sdk/crowdin_sdk.dart';
import 'package:crowdin_sdk/src/crowdin_api.dart';
import 'package:crowdin_sdk/src/real_time_preview/crowdin_oauth.dart';
import 'package:crowdin_sdk/src/real_time_preview/crowdin_preview_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:crowdin_sdk/src/common/gen_l10n_types.dart';
import 'package:oauth2/oauth2.dart' as oauth2;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:stream_channel/stream_channel.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../test_arb.dart';

class _FakeCrowdinApi extends CrowdinApi {
  @override
  Future<Map<String, dynamic>?> getMetadata({
    required String accessToken,
    required String distributionHash,
    String? organizationName,
  }) async {
    return {
      'data': {
        'project': {'id': '1', 'wsHash': 'hash'},
        'user': {'id': '2'},
        'wsUrl': 'wss://example.com/ws',
      },
    };
  }

  @override
  Future<String?> getWebsocketTicket({
    required String accessToken,
    required String event,
    String? organizationName,
  }) async {
    return 'ticket';
  }
}

class _FakeCrowdinOauth extends CrowdinOauth {
  _FakeCrowdinOauth(super.config);

  bool canceled = false;

  @override
  Future<oauth2.Credentials> authenticate() async {
    return oauth2.Credentials('access-token');
  }

  @override
  void cancel() {
    canceled = true;
  }

  @override
  void dispose() {}
}

class _FakeWebSocketSink implements WebSocketSink {
  final List<dynamic> sentMessages = [];

  @override
  void add(dynamic data) => sentMessages.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream stream) async {}

  @override
  Future close([int? closeCode, String? closeReason]) async {}

  @override
  Future get done => Future.value();
}

class _FakeWebSocketChannel extends StreamChannelMixin
    implements WebSocketChannel {
  final StreamController<dynamic> _incoming = StreamController.broadcast();

  @override
  final WebSocketSink sink = _FakeWebSocketSink();

  @override
  String? get protocol => null;

  @override
  int? get closeCode => null;

  @override
  String? get closeReason => null;

  @override
  Future<void> get ready => Future.value();

  @override
  Stream get stream => _incoming.stream;

  void emit(Map<String, dynamic> message) => _incoming.add(jsonEncode(message));

  void emitError(Object error) => _incoming.addError(error);

  Future<void> closeCleanly() => _incoming.close();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('CrowdinPreviewManager updatePreviewArb tests', () {
    late CrowdinPreviewManager crowdinPreviewManager;
    setUp(() async {
      WidgetsFlutterBinding.ensureInitialized();
      crowdinPreviewManager = CrowdinPreviewManager(
        config:
            CrowdinAuthConfig(clientId: '', clientSecret: '', redirectUri: ''),
        distributionHash: 'distributionHash',
        mappingFilePaths: ['mappingFilePath1', 'mappingFilePath2'],
      );
      crowdinPreviewManager.setPreviewArb(AppResourceBundle(testArb));
    });

    test('updatePreviewArb should update value in the previewArb', () {
      crowdinPreviewManager.finalMapping = {
        'example': 'id1',
        'hello': 'id2',
      };

      crowdinPreviewManager.updatePreviewArb(
        id: 'id1',
        text: 'New Text 1',
      );
      crowdinPreviewManager.updatePreviewArb(
        id: 'id2',
        text: 'New Text 2',
      );

      expect(crowdinPreviewManager.previewArb.resources['example'],
          equals('New Text 1'));
      expect(crowdinPreviewManager.previewArb.resources['hello'],
          equals('New Text 2'));
    });

    test('getFinalMappingData returns updated map if value exist', () {
      Map<String, String> currentMap = {
        'example': 'test_example',
      };
      var mappingData = testArb;

      var resultMap =
          crowdinPreviewManager.getFinalMappingData(mappingData, currentMap);
      expect(resultMap['example'], mappingData['example']);
    });
  });

  group('CrowdinPreviewManager getFinalMappingData tests', () {
    late CrowdinPreviewManager crowdinPreviewManager;
    var mappingData = testArb;
    setUp(() async {
      WidgetsFlutterBinding.ensureInitialized();
      crowdinPreviewManager = CrowdinPreviewManager(
        config:
            CrowdinAuthConfig(clientId: '', clientSecret: '', redirectUri: ''),
        distributionHash: 'distributionHash',
        mappingFilePaths: ['mappingFilePath1', 'mappingFilePath2'],
      );
    });
    test('getFinalMappingData returns updated map if value exist', () {
      Map<String, String> currentMap = {
        'example': 'test_example',
      };
      var resultMap =
          crowdinPreviewManager.getFinalMappingData(mappingData, currentMap);
      expect(resultMap['example'], mappingData['example']);
    });

    test('getFinalMappingData returns updated map with new values', () {
      Map<String, String> currentMap = {
        'example': 'test_example',
      };
      var resultMap =
          crowdinPreviewManager.getFinalMappingData(mappingData, currentMap);
      expect(resultMap['example'], mappingData['example']);
    });

    test('getFinalMappingData returns current map if mappingData is empty', () {
      Map<String, String> currentMap = {
        'example': 'test_example',
        'test_key': 'test_text'
      };
      Map<String, dynamic> mappingData = {};

      var resultMap =
          crowdinPreviewManager.getFinalMappingData(mappingData, currentMap);
      expect(resultMap, currentMap);
    });

    test('getFinalMappingData returns current map if mappingData is empty', () {
      Map<String, String> currentMap = {
        'example': 'test_example',
        'test_key': 'test_text'
      };
      Map<String, dynamic> mappingData = {'new_key': 'test_text'};

      var resultMap =
          crowdinPreviewManager.getFinalMappingData(mappingData, currentMap);
      expect(resultMap['new_key'], mappingData['new_key']);
    });
  });

  group('getText test with realTimePreview enabled', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await Crowdin.init(
          distributionHash: '',
          withRealTimeUpdates: true,
          authConfigurations: CrowdinAuthConfig(
            clientId: 'clientId',
            clientSecret: 'clientSecret',
            redirectUri: 'redirectUri',
          ));
      Crowdin.arb = AppResourceBundle(testPreviewArb);
      Crowdin.crowdinPreviewManager
          .setPreviewArb(AppResourceBundle(testPreviewArb));
    });
    test('should return values from previewArb', () async {
      String? simpleText = Crowdin.getText('en', 'example');

      String? zeroPluralResult =
          Crowdin.getText('en', 'nThings', {'count': 0, 'thing': 'test_thing'});

      String? pluralResult =
          Crowdin.getText('en', 'nThings', {'count': 1, 'thing': 'test_thing'});

      expect(simpleText, 'preview_Example');
      expect(zeroPluralResult, 'no preview_test_things');
      expect(pluralResult, '1 preview_test_things');
    });

    test('should return null if arb is null', () async {
      Crowdin.arb = null;

      String? result = Crowdin.getText('en', 'example');

      expect(result, isNull);
    });

    test('should return null if wrong key specified', () async {
      String? result = Crowdin.getText('en', 'wrong key');

      expect(result, isNull);
    });

    test('should return value if all arguments specified right', () async {
      String? result = Crowdin.getText('en', 'example');

      expect(result, 'preview_Example');
    });

    test('should return value with a single parameter', () async {
      String? result =
          Crowdin.getText('en', 'hello', {'userName': 'test name'});

      expect(result, 'preview_Hello test name');
    });

    test('should return value with a plurals', () async {
      String? zeroPluralResult =
          Crowdin.getText('en', 'nThings', {'count': 0, 'thing': 'test_thing'});
      String? pluralResult =
          Crowdin.getText('en', 'nThings', {'count': 1, 'thing': 'test_thing'});

      expect(zeroPluralResult, 'no preview_test_things');
      expect(pluralResult, '1 preview_test_things');
    });

    test('should return value with a count format param', () async {
      String? resultValue = Crowdin.getText('en', 'counter', {'value': 10});
      String? resultThousand =
          Crowdin.getText('en', 'counter', {'value': 1000});
      String? resultMillion =
          Crowdin.getText('en', 'counter', {'value': 1000000});
      String? resultBillion =
          Crowdin.getText('en', 'counter', {'value': 1000000000});
      String? resultTrillion =
          Crowdin.getText('en', 'counter', {'value': 1000000000000});

      expect(resultValue, 'preview_Counter: 10');
      expect(resultThousand, 'preview_Counter: 1 thousand');
      expect(resultMillion, 'preview_Counter: 1 million');
      expect(resultBillion, 'preview_Counter: 1 billion');
      expect(resultTrillion, 'preview_Counter: 1 trillion');
    });
  });

  group('CrowdinPreviewManager real-time connection lifecycle', () {
    late _FakeCrowdinApi fakeApi;
    late _FakeCrowdinOauth fakeOauth;
    late _FakeWebSocketChannel fakeChannel;
    late CrowdinPreviewManager manager;

    setUp(() {
      fakeApi = _FakeCrowdinApi();
      fakeChannel = _FakeWebSocketChannel();
      manager = CrowdinPreviewManager(
        config: CrowdinAuthConfig(
          clientId: 'clientId',
          clientSecret: 'clientSecret',
          redirectUri: 'redirectUri',
        ),
        distributionHash: 'distributionHash',
        mappingFilePaths: const [],
        api: fakeApi,
        connectWebSocket: (_) => fakeChannel,
        createAuth: (config) {
          fakeOauth = _FakeCrowdinOauth(config);
          return fakeOauth;
        },
      );
      manager.setPreviewArb(AppResourceBundle({
        '@@locale': 'en',
        'greeting': 'Hello',
      }));
    });

    Future<void> start() {
      return manager.start(
        onTranslationUpdate: (_) {},
        onConnectionError: (_, __) {},
        onSubscriptionProgress: (_, __, ___) {},
        onSubscriptionsReady: () {},
      );
    }

    test(
        'parses a tr{<id>} WebSocket event into the plain mapping id and updates the preview arb',
        () async {
      manager.finalMapping = {'greeting': '42'};

      await start();

      fakeChannel.emit({
        'event': 'update-draft:hash:pr{1}:us{2}:en:tr{42}',
        'data': {'text': 'Hola'},
      });
      await pumpEventQueue();

      expect(manager.previewArb.resources['greeting'], 'Hola');
    });

    test(
        'a clean unexpected socket close reports a connection error and allows retry',
        () async {
      Object? reportedError;
      var connectionErrorCalls = 0;

      Future<void> startAndTrackErrors() {
        return manager.start(
          onTranslationUpdate: (_) {},
          onConnectionError: (error, stackTrace) {
            connectionErrorCalls++;
            reportedError = error;
          },
          onSubscriptionProgress: (_, __, ___) {},
          onSubscriptionsReady: () {},
        );
      }

      await startAndTrackErrors();

      await fakeChannel.closeCleanly();
      await pumpEventQueue();

      expect(connectionErrorCalls, 1);
      expect(reportedError, isNotNull);

      // Retry: starting again should establish a fresh connection.
      final secondChannel = _FakeWebSocketChannel();
      manager = CrowdinPreviewManager(
        config: CrowdinAuthConfig(
          clientId: 'clientId',
          clientSecret: 'clientSecret',
          redirectUri: 'redirectUri',
        ),
        distributionHash: 'distributionHash',
        mappingFilePaths: const [],
        api: fakeApi,
        connectWebSocket: (_) => secondChannel,
        createAuth: (config) => _FakeCrowdinOauth(config),
      );
      manager.setPreviewArb(AppResourceBundle({
        '@@locale': 'en',
        'greeting': 'Hello',
      }));

      await expectLater(startAndTrackErrors(), completes);
    });

    test('intentional cancel does not report a connection error', () async {
      var connectionErrorCalls = 0;

      final startFuture = manager.start(
        onTranslationUpdate: (_) {},
        onConnectionError: (_, __) => connectionErrorCalls++,
        onSubscriptionProgress: (_, __, ___) {},
        onSubscriptionsReady: () {},
      );

      await startFuture;
      await manager.cancelStart();
      await pumpEventQueue();

      expect(connectionErrorCalls, 0);
      expect(fakeOauth.canceled, isTrue);
    });

    test('dispose does not report a connection error', () async {
      var connectionErrorCalls = 0;

      await manager.start(
        onTranslationUpdate: (_) {},
        onConnectionError: (_, __) => connectionErrorCalls++,
        onSubscriptionProgress: (_, __, ___) {},
        onSubscriptionsReady: () {},
      );

      await manager.dispose();
      await pumpEventQueue();

      expect(connectionErrorCalls, 0);
    });
  });
}

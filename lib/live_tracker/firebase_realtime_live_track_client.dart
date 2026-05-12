/*
 * Copyright (C) 2020-2025 HERE Europe B.V.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * SPDX-License-Identifier: Apache-2.0
 * License-Filename: LICENSE
 */

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:here_sdk/core.dart';

import '../common/app_identity.dart';

class FirebaseLiveTrackSession {
  FirebaseLiveTrackSession({
    required this.databaseUrl,
    required this.pathPrefix,
    required this.sessionId,
    required this.deviceId,
    required this.startedAt,
  });

  final String databaseUrl;
  final String pathPrefix;
  final String sessionId;
  final String deviceId;
  final DateTime startedAt;
}

class FirebaseRealtimeLiveTrackClient {
  static const String defaultPathPrefix = 'ocmLiveTracker';
  static const String _source = companionAppName;

  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10);

  Future<FirebaseLiveTrackSession> startSession({
    required String databaseUrl,
    required String pathPrefix,
    required String deviceId,
    String authToken = '',
    DateTime? startedAt,
  }) async {
    final DateTime startedAtUtc = startedAt?.toUtc() ?? DateTime.now().toUtc();
    final String safeDeviceId = _safeId(deviceId.isEmpty ? 'phone' : deviceId);
    final FirebaseLiveTrackSession session = FirebaseLiveTrackSession(
      databaseUrl: _normaliseDatabaseUrl(databaseUrl),
      pathPrefix: _normalisePathPrefix(pathPrefix),
      sessionId: _sessionId(startedAtUtc, safeDeviceId),
      deviceId: safeDeviceId,
      startedAt: startedAtUtc,
    );
    await writeSessionMetadata(
      session: session,
      authToken: authToken,
      status: 'active',
      sequence: 0,
      lastLocation: null,
    );
    return session;
  }

  Future<void> writeTrackPoint({
    required FirebaseLiveTrackSession session,
    required String authToken,
    required Map<String, dynamic> point,
    required int sequence,
    required DateTime sentAt,
  }) async {
    final DateTime sentAtUtc = sentAt.toUtc();
    final Map<String, dynamic> payload = {
      ...point,
      'sessionId': session.sessionId,
      'deviceId': session.deviceId,
      'source': _source,
      'seq': sequence,
      'sentAt': sentAtUtc.toIso8601String(),
      'sentAtMs': sentAtUtc.millisecondsSinceEpoch,
    };
    await _patch(
      databaseUrl: session.databaseUrl,
      authToken: authToken,
      path: session.pathPrefix,
      body: {
        'liveSessions/${session.sessionId}/status': 'active',
        'liveSessions/${session.sessionId}/updatedAt': sentAtUtc
            .toIso8601String(),
        'liveSessions/${session.sessionId}/updatedAtMs':
            sentAtUtc.millisecondsSinceEpoch,
        'liveSessions/${session.sessionId}/lastSequence': sequence,
        'liveSessions/${session.sessionId}/latest': payload,
      },
    );
  }

  Future<void> writeSessionMetadata({
    required FirebaseLiveTrackSession session,
    required String authToken,
    required String status,
    required int sequence,
    required Location? lastLocation,
  }) async {
    final DateTime now = DateTime.now().toUtc();
    final Map<String, dynamic> metadata = {
      'sessionId': session.sessionId,
      'deviceId': session.deviceId,
      'source': _source,
      'status': status,
      'startedAt': session.startedAt.toIso8601String(),
      'startedAtMs': session.startedAt.millisecondsSinceEpoch,
      'updatedAt': now.toIso8601String(),
      'updatedAtMs': now.millisecondsSinceEpoch,
      'lastSequence': sequence,
      'schemaVersion': 2,
    };
    final Map<String, dynamic>? latest = lastLocation == null
        ? null
        : _pointPayload(
            session: session,
            location: lastLocation,
            sequence: sequence,
            sentAt: now,
          );
    if (latest != null) {
      metadata['latest'] = latest;
    }
    await _patch(
      databaseUrl: session.databaseUrl,
      authToken: authToken,
      path: '${session.pathPrefix}/liveSessions/${session.sessionId}',
      body: metadata,
    );
  }

  Future<void> closeSession({
    required FirebaseLiveTrackSession session,
    required String authToken,
    required int sequence,
    Location? lastLocation,
  }) async {
    await writeSessionMetadata(
      session: session,
      authToken: authToken,
      status: 'closed',
      sequence: sequence,
      lastLocation: lastLocation,
    );
  }

  Map<String, dynamic> _pointPayload({
    required FirebaseLiveTrackSession session,
    required Location location,
    required int sequence,
    required DateTime sentAt,
  }) {
    return {
      'sessionId': session.sessionId,
      'deviceId': session.deviceId,
      'source': _source,
      'seq': sequence,
      'sentAt': sentAt.toIso8601String(),
      'sentAtMs': sentAt.millisecondsSinceEpoch,
      'lat': _finiteDouble(location.coordinates.latitude),
      'lng': _finiteDouble(location.coordinates.longitude),
      'altitudeM': _finiteDouble(location.coordinates.altitude),
      'accuracyM': _finiteDouble(location.horizontalAccuracyInMeters),
      'verticalAccuracyM': _finiteDouble(location.verticalAccuracyInMeters),
      'speedMps': _finiteDouble(location.speedInMetersPerSecond),
      'bearingDeg': _finiteDouble(location.bearingInDegrees),
      'bearingAccuracyDeg': _finiteDouble(location.bearingAccuracyInDegrees),
      'speedAccuracyMps': _finiteDouble(
        location.speedAccuracyInMetersPerSecond,
      ),
      'time': location.time?.toUtc().toIso8601String(),
      'timeMs': location.time?.toUtc().millisecondsSinceEpoch,
      'timestampSinceBootMs': location.timestampSinceBoot?.inMilliseconds,
      'gnssTimeMs': location.gnssTime?.inMilliseconds,
      'pitchDeg': _finiteDouble(location.pitchInDegrees),
      'laneIndex': location.laneIndex,
    }..removeWhere((_, value) => value == null);
  }

  double? _finiteDouble(double? value) {
    return value == null || !value.isFinite ? null : value;
  }

  Future<void> _patch({
    required String databaseUrl,
    required String authToken,
    required String path,
    required Map<String, dynamic> body,
  }) async {
    await _requestJson(
      method: 'PATCH',
      uri: _firebaseUri(
        databaseUrl: databaseUrl,
        path: path,
        authToken: authToken,
      ),
      body: body,
    );
  }

  Future<void> _requestJson({
    required String method,
    required Uri uri,
    required Map<String, dynamic> body,
  }) async {
    final HttpClientRequest request = await _httpClient
        .openUrl(method, uri)
        .timeout(const Duration(seconds: 10));
    request.headers.contentType = ContentType.json;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    request.add(utf8.encode(jsonEncode(body)));

    final HttpClientResponse response = await request.close().timeout(
      const Duration(seconds: 15),
    );
    final String text = await response.transform(utf8.decoder).join();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        '$method $uri failed: HTTP ${response.statusCode} $text',
        uri: uri,
      );
    }
  }

  Uri _firebaseUri({
    required String databaseUrl,
    required String path,
    required String authToken,
  }) {
    final Uri base = Uri.parse(_normaliseDatabaseUrl(databaseUrl));
    final String joinedPath =
        '${base.path.replaceFirst(RegExp(r'/+$'), '')}/${_normalisePathPrefix(path)}.json';
    final Map<String, String> queryParameters = {
      if (authToken.trim().isNotEmpty) 'auth': authToken.trim(),
    };
    return base.replace(
      path: joinedPath,
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
    );
  }

  String _normaliseDatabaseUrl(String value) {
    final String trimmed = value.trim().replaceFirst(RegExp(r'/+$'), '');
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null ||
        (uri.scheme != 'https' && uri.scheme != 'http') ||
        uri.host.isEmpty) {
      throw FormatException('Invalid Firebase database URL: $value');
    }
    return trimmed;
  }

  String _normalisePathPrefix(String value) {
    final String trimmed = value.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return trimmed.isEmpty ? defaultPathPrefix : trimmed;
  }

  String _sessionId(DateTime startedAt, String safeDeviceId) {
    final String timestamp = startedAt
        .toIso8601String()
        .replaceAll(RegExp(r'[-:.TZ]'), '')
        .substring(0, 14);
    final int suffix = Random().nextInt(0x10000);
    return '$timestamp-$safeDeviceId-${suffix.toRadixString(16).padLeft(4, '0')}';
  }

  String _safeId(String value) {
    final String safe = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return safe.isEmpty ? 'phone' : safe;
  }

  void close() {
    _httpClient.close(force: true);
  }
}

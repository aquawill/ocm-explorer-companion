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

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:here_sdk/core.dart';
import 'package:here_sdk/navigation.dart' as Navigation;
import 'package:here_sdk/routing.dart' as Routing;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../common/app_identity.dart';
import '../environment.dart';
import 'firebase_realtime_live_track_client.dart';
import 'gpx_track_recorder.dart';
import 'live_tracker_location_update.dart';
import 'live_tracker_segment_evidence_loader.dart';

enum LiveTrackerTarget { firebaseRealtime, localServer }

class LiveTrackerService extends ChangeNotifier {
  static const String _enabledKey = 'ocm_live_tracker_enabled';
  static const String _targetKey = 'ocm_live_tracker_target';
  static const String _serverUrlKey = 'ocm_live_tracker_server_url';
  static const String _tokenKey = 'ocm_live_tracker_token';
  static const String _deviceIdKey = 'ocm_live_tracker_device_id';
  static const String _minIntervalMsKey = 'ocm_live_tracker_min_interval_ms';
  static const String _firebaseDatabaseUrlKey =
      'ocm_live_tracker_firebase_database_url';
  static const String _firebasePathPrefixKey =
      'ocm_live_tracker_firebase_path_prefix';
  static const String _firebaseSessionIdKey =
      'ocm_live_tracker_firebase_session_id';
  static const String _firebaseStartedAtKey =
      'ocm_live_tracker_firebase_started_at';
  static const String _firebaseSequenceKey =
      'ocm_live_tracker_firebase_sequence';
  static const String _appendToPreviousGpxTrackKey =
      'ocm_live_tracker_append_to_previous_gpx_track';
  static const String _gpxTrackFilePathKey =
      'ocm_live_tracker_gpx_track_file_path';
  static const String _lastGpxTrackFilePathKey =
      'ocm_live_tracker_last_gpx_track_file_path';
  static const String firebaseDefaultPathPrefix =
      FirebaseRealtimeLiveTrackClient.defaultPathPrefix;

  final HttpClient _httpClient = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);
  static const MethodChannel _shareChannel = MethodChannel(
    'com.example.RefApp/share_channel',
  );
  final FirebaseRealtimeLiveTrackClient _firebaseClient =
      FirebaseRealtimeLiveTrackClient();
  final GpxTrackRecorder _gpxRecorder = GpxTrackRecorder();
  final LiveTrackerSegmentEvidenceLoader _segmentEvidenceLoader =
      LiveTrackerSegmentEvidenceLoader();

  SharedPreferences? _preferences;
  bool _enabled = false;
  LiveTrackerTarget _target = LiveTrackerTarget.firebaseRealtime;
  String _serverUrl = 'http://127.0.0.1:5500';
  String _token = '';
  String _deviceId = 'phone';
  int _minIntervalMs = 1000;
  String _firebaseDatabaseUrl = Environment.firebaseDatabaseUrl;
  String _firebasePathPrefix = Environment.firebasePathPrefix.trim().isEmpty
      ? firebaseDefaultPathPrefix
      : Environment.firebasePathPrefix;
  bool _appendToPreviousGpxTrack = false;
  String? _gpxTrackFilePath;
  String? _lastGpxTrackFilePath;
  String _statusText = 'Not configured';
  int _sentCount = 0;
  int _failedCount = 0;
  int _firebaseSequence = 0;
  DateTime? _lastObservedAt;
  DateTime? _lastSentAt;
  DateTime? _latestLocationObservedAt;
  LiveTrackerLocationUpdate? _latestLocationUpdate;
  Map<String, dynamic>? _latestLocationPayload;
  Map<String, dynamic>? _latestSegmentEvidence;
  Map<String, dynamic>? _latestMapMatchingDiagnostics;
  FirebaseLiveTrackSession? _firebaseSession;
  bool _loaded = false;

  LiveTrackerService() {
    load();
  }

  bool get enabled => _enabled;
  LiveTrackerTarget get target => _target;
  String get serverUrl => _serverUrl;
  String get token => _token;
  String get deviceId => _deviceId;
  int get minIntervalMs => _minIntervalMs;
  String get firebaseDatabaseUrl => _firebaseDatabaseUrl;
  String get firebasePathPrefix => _firebasePathPrefix;
  String? get firebaseSessionId => _firebaseSession?.sessionId;
  bool get hasBundledFirebaseDatabaseUrl =>
      Environment.firebaseDatabaseUrl.trim().isNotEmpty;
  bool get hasBundledFirebasePathPrefix =>
      Environment.firebasePathPrefix.trim().isNotEmpty;
  bool get appendToPreviousGpxTrack => _appendToPreviousGpxTrack;
  String? get gpxTrackFilePath => _gpxTrackFilePath;
  String? get lastGpxTrackFilePath => _lastGpxTrackFilePath;
  String? get exportableGpxTrackFilePath =>
      _gpxTrackFilePath ?? _lastGpxTrackFilePath;
  String get statusText => _statusText;
  int get sentCount => _sentCount;
  int get failedCount => _failedCount;
  DateTime? get latestLocationObservedAt => _latestLocationObservedAt;
  LiveTrackerLocationUpdate? get latestLocationUpdate => _latestLocationUpdate;
  Map<String, dynamic>? get latestLocationPayload => _latestLocationPayload;
  Map<String, dynamic>? get latestSegmentEvidence => _latestSegmentEvidence;
  Map<String, dynamic>? get latestMapMatchingDiagnostics =>
      _latestMapMatchingDiagnostics;

  Future<void> load() async {
    if (_loaded) {
      return;
    }
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    _preferences = preferences;
    _enabled = preferences.getBool(_enabledKey) ?? false;
    _target = _targetFromName(preferences.getString(_targetKey));
    _serverUrl = preferences.getString(_serverUrlKey) ?? _serverUrl;
    _token = preferences.getString(_tokenKey) ?? '';
    _deviceId = preferences.getString(_deviceIdKey) ?? _deviceId;
    _minIntervalMs = preferences.getInt(_minIntervalMsKey) ?? _minIntervalMs;
    _firebaseDatabaseUrl = hasBundledFirebaseDatabaseUrl
        ? Environment.firebaseDatabaseUrl
        : preferences.getString(_firebaseDatabaseUrlKey) ??
              _firebaseDatabaseUrl;
    _firebasePathPrefix = hasBundledFirebasePathPrefix
        ? Environment.firebasePathPrefix
        : preferences.getString(_firebasePathPrefixKey) ?? _firebasePathPrefix;
    _firebaseSequence = preferences.getInt(_firebaseSequenceKey) ?? 0;
    _firebaseSession = _restoreFirebaseSession(preferences);
    _appendToPreviousGpxTrack =
        preferences.getBool(_appendToPreviousGpxTrackKey) ?? false;
    _gpxTrackFilePath = preferences.getString(_gpxTrackFilePathKey);
    _lastGpxTrackFilePath = preferences.getString(_lastGpxTrackFilePathKey);
    final bool repairedStoredTracks = await _repairStoredGpxTracks();
    if (repairedStoredTracks) {
      await _save();
    }
    _loaded = true;
    _statusText = _enabled ? 'Ready' : 'Off';
    notifyListeners();
  }

  Future<void> configure({
    bool? enabled,
    LiveTrackerTarget? target,
    String? serverUrl,
    String? token,
    String? deviceId,
    int? minIntervalMs,
    String? firebaseDatabaseUrl,
    String? firebasePathPrefix,
    bool? appendToPreviousGpxTrack,
  }) async {
    await load();
    final String previousDeviceId = _deviceId;
    final String previousFirebaseDatabaseUrl = _firebaseDatabaseUrl;
    final String previousFirebasePathPrefix = _firebasePathPrefix;

    final bool nextEnabled = enabled ?? _enabled;
    final LiveTrackerTarget nextTarget = target ?? _target;
    final String nextServerUrl = _normaliseServerUrl(serverUrl ?? _serverUrl);
    final String nextToken = (token ?? _token).trim();
    final String nextDeviceId = _normaliseDeviceId(deviceId ?? _deviceId);
    final int nextMinIntervalMs = (minIntervalMs ?? _minIntervalMs)
        .clamp(250, 10000)
        .toInt();
    final String nextFirebaseDatabaseUrl = _normaliseServerUrl(
      firebaseDatabaseUrl ?? _firebaseDatabaseUrl,
    );
    final String nextFirebasePathPrefix = _normaliseFirebasePathPrefix(
      firebasePathPrefix ?? _firebasePathPrefix,
    );
    final bool firebaseSessionIdentityChanged =
        _firebaseSession != null &&
        (previousDeviceId != nextDeviceId ||
            previousFirebaseDatabaseUrl != nextFirebaseDatabaseUrl ||
            previousFirebasePathPrefix != nextFirebasePathPrefix ||
            nextTarget != LiveTrackerTarget.firebaseRealtime);

    _enabled = nextEnabled;
    _target = nextTarget;
    _serverUrl = nextServerUrl;
    _token = nextToken;
    _deviceId = nextDeviceId;
    _minIntervalMs = nextMinIntervalMs;
    _firebaseDatabaseUrl = nextFirebaseDatabaseUrl;
    _firebasePathPrefix = nextFirebasePathPrefix;
    _appendToPreviousGpxTrack =
        appendToPreviousGpxTrack ?? _appendToPreviousGpxTrack;
    if (firebaseSessionIdentityChanged) {
      await _resetFirebaseSessionForChangedIdentity();
    }
    _statusText = _enabled ? 'Ready' : 'Off';
    await _save();
    notifyListeners();
  }

  Future<void> setEnabled(bool enabled) async {
    await configure(enabled: enabled);
  }

  Future<void> ensureFirebaseSession() async {
    await load();
    if (_target != LiveTrackerTarget.firebaseRealtime) {
      return;
    }
    await _dropMissingActiveGpxTrackIfNeeded();
    if (_firebaseSession != null && _gpxTrackFilePath != null) {
      _enabled = true;
      _statusText = 'Firebase session ready: ${_firebaseSession!.sessionId}';
      await _save();
      notifyListeners();
      return;
    }
    await startFirebaseSession();
  }

  Future<void> startFirebaseSession() async {
    await load();
    await _dropMissingActiveGpxTrackIfNeeded();
    _statusText = 'Starting Firebase session...';
    notifyListeners();
    try {
      if (_firebaseDatabaseUrl.trim().isEmpty) {
        throw const FormatException('Firebase database URL is required');
      }
      if (!_appendToPreviousGpxTrack) {
        _firebaseSequence = 0;
      }
      _firebaseSession = await _firebaseClient.startSession(
        databaseUrl: _firebaseDatabaseUrl,
        pathPrefix: _firebasePathPrefix,
        deviceId: _deviceId,
      );
      final GpxTrackFile gpxTrackFile = await _gpxRecorder.startTrack(
        sessionId: _firebaseSession!.sessionId,
        deviceId: _deviceId,
        startedAt: _firebaseSession!.startedAt,
        appendToPrevious: _appendToPreviousGpxTrack,
        previousFilePath: _gpxTrackFilePath ?? _lastGpxTrackFilePath,
      );
      _gpxTrackFilePath = gpxTrackFile.path;
      _lastGpxTrackFilePath = gpxTrackFile.path;
      _target = LiveTrackerTarget.firebaseRealtime;
      _enabled = true;
      _sentCount = 0;
      _failedCount = 0;
      _lastSentAt = null;
      _statusText = 'Firebase session ready: ${_firebaseSession!.sessionId}';
      await _save();
    } catch (error) {
      _failedCount++;
      _enabled = false;
      _statusText = error.toString();
    }
    notifyListeners();
  }

  Future<void> stopFirebaseSession() async {
    await load();
    _enabled = false;
    final FirebaseLiveTrackSession? session = _firebaseSession;
    Object? stopError;
    if (session != null) {
      try {
        await _firebaseClient.closeSession(
          session: session,
          authToken: '',
          sequence: _firebaseSequence,
        );
      } catch (error) {
        stopError = error;
      }
    }
    final String? gpxTrackFilePath = _gpxTrackFilePath;
    if (await _dropMissingActiveGpxTrackIfNeeded(save: false)) {
      debugPrint(
        '[$liveTrackingFeatureName] Stopped with a stale GPX track reference.',
      );
    } else if (gpxTrackFilePath != null) {
      try {
        await _gpxRecorder.closeTrack(filePath: gpxTrackFilePath);
      } catch (error) {
        stopError ??= error;
      }
    }
    if (stopError != null) {
      _failedCount++;
      _statusText = stopError.toString();
      await _save();
      notifyListeners();
      return;
    }
    _firebaseSession = null;
    _firebaseSequence = 0;
    _gpxTrackFilePath = null;
    _lastSentAt = null;
    _appendToPreviousGpxTrack = false;
    _statusText = 'Firebase session stopped';
    await _save();
    notifyListeners();
  }

  Future<void> exportGpxTrack() async {
    await load();
    final String? filePath = exportableGpxTrackFilePath;
    if (filePath == null || filePath.trim().isEmpty) {
      throw const FileSystemException('No GPX file to export');
    }
    await _repairGpxTrack(filePath);
    final File source = File(filePath);
    if (!await source.exists()) {
      await _clearMissingGpxTrackReference(filePath);
      throw FileSystemException('GPX file does not exist', filePath);
    }
    final Directory temporaryDirectory = await getTemporaryDirectory();
    final File snapshot = File(
      '${temporaryDirectory.path}/${_fileNameFromPath(filePath)}',
    );
    await source.copy(snapshot.path);
    await _shareChannel.invokeMethod<void>('shareFile', {
      'path': snapshot.path,
      'mimeType': 'application/gpx+xml',
      'subject': '$liveTrackingFeatureName GPX',
      'text': _fileNameFromPath(snapshot.path),
    });
  }

  Future<void> sendRawLocation(Location location) async {
    await sendLocationUpdate(
      LiveTrackerLocationUpdate(rawLocation: location, matchedLocation: null),
    );
  }

  Future<void> sendLocationUpdate(LiveTrackerLocationUpdate update) async {
    final DateTime now = DateTime.now().toUtc();
    if (_lastObservedAt != null &&
        now.difference(_lastObservedAt!).inMilliseconds < _minIntervalMs) {
      return;
    }
    _lastObservedAt = now;

    final Map<String, dynamic>? segmentEvidence = _segmentEvidenceLoader
        .evidenceFor(update.matchedLocation);
    _latestLocationObservedAt = now;
    _latestLocationUpdate = update;
    _latestSegmentEvidence = segmentEvidence;
    _latestMapMatchingDiagnostics = update.mapMatchingDiagnostics;
    _latestLocationPayload = _payloadFor(
      update,
      now,
      segmentEvidence: segmentEvidence,
    );
    notifyListeners();

    if (!_enabled) {
      return;
    }

    if (_lastSentAt != null &&
        now.difference(_lastSentAt!).inMilliseconds < _minIntervalMs) {
      return;
    }
    _lastSentAt = now;

    if (_target == LiveTrackerTarget.firebaseRealtime) {
      await _sendToFirebase(update, segmentEvidence, now);
      return;
    }

    final Uri? endpoint = _endpointUri();
    if (endpoint == null) {
      _failedCount++;
      _statusText = 'Invalid server URL';
      notifyListeners();
      return;
    }

    try {
      final HttpClientRequest request = await _httpClient
          .postUrl(endpoint)
          .timeout(const Duration(seconds: 3));
      request.headers.contentType = ContentType.json;
      if (_token.isNotEmpty) {
        request.headers.set('X-OCM-Token', _token);
      }
      request.add(
        utf8.encode(
          jsonEncode(
            _payloadFor(update, now, segmentEvidence: segmentEvidence),
          ),
        ),
      );

      final HttpClientResponse response = await request.close().timeout(
        const Duration(seconds: 3),
      );
      await response.drain<void>();

      if (response.statusCode >= 200 && response.statusCode < 300) {
        _sentCount++;
        _statusText = 'Sent $_sentCount updates';
      } else {
        _failedCount++;
        _statusText = 'HTTP ${response.statusCode}';
      }
    } catch (error) {
      _failedCount++;
      _statusText = error.toString();
    }
    notifyListeners();
  }

  Future<void> _sendToFirebase(
    LiveTrackerLocationUpdate update,
    Map<String, dynamic>? segmentEvidence,
    DateTime sentAt,
  ) async {
    try {
      if (_firebaseDatabaseUrl.trim().isEmpty) {
        throw const FormatException('Firebase database URL is required');
      }
      await _dropMissingActiveGpxTrackIfNeeded();
      _firebaseSession ??= await _firebaseClient.startSession(
        databaseUrl: _firebaseDatabaseUrl,
        pathPrefix: _firebasePathPrefix,
        deviceId: _deviceId,
      );
      _gpxTrackFilePath ??= await _startGpxTrackForFirebaseSession(
        _firebaseSession!,
      );
      _firebaseSequence++;
      final Map<String, dynamic> firebasePoint = _payloadFor(
        update,
        sentAt,
        session: _firebaseSession,
        sequence: _firebaseSequence,
      );
      final Map<String, dynamic>? matchedLocation =
          firebasePoint['matched'] as Map<String, dynamic>?;
      final String? gpxTrackFilePath = _gpxTrackFilePath;
      if (gpxTrackFilePath != null) {
        await _gpxRecorder.appendLocation(
          filePath: gpxTrackFilePath,
          location: update.rawLocation,
          sequence: _firebaseSequence,
          sentAt: sentAt,
          matchedLocation: matchedLocation,
          segmentEvidence: segmentEvidence,
        );
      }
      await _firebaseClient.writeTrackPoint(
        session: _firebaseSession!,
        authToken: '',
        point: firebasePoint,
        sequence: _firebaseSequence,
        sentAt: sentAt,
      );
      _sentCount++;
      _statusText = 'Firebase: $_sentCount points';
      await _save();
    } catch (error) {
      _failedCount++;
      _statusText = error.toString();
    }
    notifyListeners();
  }

  Future<String?> _startGpxTrackForFirebaseSession(
    FirebaseLiveTrackSession session,
  ) async {
    final GpxTrackFile gpxTrackFile = await _gpxRecorder.startTrack(
      sessionId: session.sessionId,
      deviceId: _deviceId,
      startedAt: session.startedAt,
      appendToPrevious: _appendToPreviousGpxTrack,
      previousFilePath: _gpxTrackFilePath ?? _lastGpxTrackFilePath,
    );
    _lastGpxTrackFilePath = gpxTrackFile.path;
    return gpxTrackFile.path;
  }

  Map<String, dynamic> _payloadFor(
    LiveTrackerLocationUpdate update,
    DateTime sentAt, {
    FirebaseLiveTrackSession? session,
    int? sequence,
    Map<String, dynamic>? segmentEvidence,
  }) {
    final Map<String, dynamic> raw = _rawLocationPayload(update.rawLocation);
    final Map<String, dynamic>? matched = _matchedLocationPayload(
      update.matchedLocation,
    );
    final Map<String, dynamic> preferred = matched ?? raw;

    return {
      if (session != null) 'sessionId': session.sessionId,
      'deviceId': _deviceId,
      'source': companionAppName,
      if (sequence != null) 'seq': sequence,
      'sentAt': sentAt.toIso8601String(),
      'sentAtMs': sentAt.millisecondsSinceEpoch,
      'lat': preferred['lat'],
      'lng': preferred['lon'],
      'raw': raw,
      'matched': matched,
      if (segmentEvidence != null) 'segmentEvidence': segmentEvidence,
    }..removeWhere(
      (String key, Object? value) => value == null && key != 'matched',
    );
  }

  Map<String, dynamic> _rawLocationPayload(Location location) {
    return <String, dynamic>{
      'lat': _finiteDouble(location.coordinates.latitude),
      'lon': _finiteDouble(location.coordinates.longitude),
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
      'timestampSinceBootMs': location.timestampSinceBoot?.inMilliseconds,
      'gnssTimeMs': location.gnssTime?.inMilliseconds,
      'pitchDeg': _finiteDouble(location.pitchInDegrees),
      'laneIndex': location.laneIndex,
    }..removeWhere((key, value) => value == null);
  }

  Map<String, dynamic>? _matchedLocationPayload(
    Navigation.MapMatchedLocation? location,
  ) {
    if (location == null) {
      return null;
    }
    return <String, dynamic>{
      'lat': _finiteDouble(location.coordinates.latitude),
      'lon': _finiteDouble(location.coordinates.longitude),
      'altitudeM': _finiteDouble(location.coordinates.altitude),
      'bearingDeg': _finiteDouble(location.bearingInDegrees),
      'segmentReference': _segmentReferencePayload(location.segmentReference),
      'segmentOffsetCm': location.segmentOffsetInCentimeters,
      'confidence': _finiteDouble(location.confidence),
      'isDrivingInTheWrongWay': location.isDrivingInTheWrongWay,
      'accuracyM': _finiteDouble(location.horizontalAccuracyInMeters),
      'speedMps': _finiteDouble(location.speedInMetersPerSecond),
      'time': location.timestamp?.toUtc().toIso8601String(),
      'timeMs': location.timestamp?.toUtc().millisecondsSinceEpoch,
    }..removeWhere((key, value) => value == null);
  }

  Map<String, dynamic> _segmentReferencePayload(
    Routing.SegmentReference segmentReference,
  ) {
    return {
      'segmentId': segmentReference.segmentId,
      'travelDirection': _enumName(segmentReference.travelDirection),
      'offsetStart': _finiteDouble(segmentReference.offsetStart),
      'offsetEnd': _finiteDouble(segmentReference.offsetEnd),
      'tilePartitionId': segmentReference.tilePartitionId,
      'localId': segmentReference.localId,
    }..removeWhere((key, value) => value == null);
  }

  double? _finiteDouble(double? value) {
    return value == null || !value.isFinite ? null : value;
  }

  String _enumName(Object value) {
    final String text = value.toString();
    final int dot = text.lastIndexOf('.');
    return dot >= 0 ? text.substring(dot + 1) : text;
  }

  Uri? _endpointUri() {
    final String normalised = _normaliseServerUrl(_serverUrl);
    if (normalised.isEmpty) {
      return null;
    }
    final String endpoint = normalised.endsWith('/api/live-location')
        ? normalised
        : '$normalised/api/live-location';
    final Uri? uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return null;
    }
    return uri;
  }

  String _normaliseServerUrl(String value) =>
      value.trim().replaceFirst(RegExp(r'/+$'), '');

  String _normaliseDeviceId(String value) {
    final String trimmed = value.trim();
    return trimmed.isEmpty ? 'phone' : trimmed;
  }

  String _normaliseFirebasePathPrefix(String value) {
    final String trimmed = value.trim().replaceAll(RegExp(r'^/+|/+$'), '');
    return trimmed.isEmpty ? firebaseDefaultPathPrefix : trimmed;
  }

  String _fileNameFromPath(String filePath) {
    final List<String> parts = filePath.split(Platform.pathSeparator);
    return parts.isEmpty ? 'ocm-live-track.gpx' : parts.last;
  }

  LiveTrackerTarget _targetFromName(String? name) {
    return _targetFromNameOrNull(name) ?? LiveTrackerTarget.firebaseRealtime;
  }

  LiveTrackerTarget? _targetFromNameOrNull(String? name) {
    if (name == null || name.trim().isEmpty) {
      return null;
    }
    for (final LiveTrackerTarget target in LiveTrackerTarget.values) {
      if (target.name == name) {
        return target;
      }
    }
    return null;
  }

  FirebaseLiveTrackSession? _restoreFirebaseSession(
    SharedPreferences preferences,
  ) {
    final String databaseUrl =
        preferences.getString(_firebaseDatabaseUrlKey) ?? '';
    final String pathPrefix =
        preferences.getString(_firebasePathPrefixKey) ??
        firebaseDefaultPathPrefix;
    final String? sessionId = preferences.getString(_firebaseSessionIdKey);
    final String? startedAtText = preferences.getString(_firebaseStartedAtKey);
    if (databaseUrl.isEmpty || sessionId == null || startedAtText == null) {
      return null;
    }
    final DateTime? startedAt = DateTime.tryParse(startedAtText);
    if (startedAt == null) {
      return null;
    }
    return FirebaseLiveTrackSession(
      databaseUrl: databaseUrl,
      pathPrefix: pathPrefix,
      sessionId: sessionId,
      deviceId: _deviceId,
      startedAt: startedAt.toUtc(),
    );
  }

  Future<bool> _repairStoredGpxTracks() async {
    bool changed = false;
    changed = await _dropMissingActiveGpxTrackIfNeeded(save: false) || changed;
    final String? lastGpxTrackFilePath = _lastGpxTrackFilePath;
    if (lastGpxTrackFilePath != null &&
        lastGpxTrackFilePath.trim().isNotEmpty &&
        !await File(lastGpxTrackFilePath).exists()) {
      debugPrint(
        '[$liveTrackingFeatureName] Dropping stale last GPX track: $lastGpxTrackFilePath',
      );
      changed =
          await _clearMissingGpxTrackReference(
            lastGpxTrackFilePath,
            save: false,
          ) ||
          changed;
    }
    await _repairGpxTrack(_gpxTrackFilePath);
    if (_lastGpxTrackFilePath != _gpxTrackFilePath) {
      await _repairGpxTrack(_lastGpxTrackFilePath);
    }
    return changed;
  }

  Future<void> _repairGpxTrack(String? filePath) async {
    if (filePath == null || filePath.trim().isEmpty) {
      return;
    }
    try {
      await _gpxRecorder.closeTrack(filePath: filePath);
    } catch (error) {
      debugPrint(
        '[$liveTrackingFeatureName] GPX repair failed for $filePath: $error',
      );
    }
  }

  Future<void> _resetFirebaseSessionForChangedIdentity() async {
    final String? gpxTrackFilePath = _gpxTrackFilePath;
    _firebaseSession = null;
    _firebaseSequence = 0;
    _gpxTrackFilePath = null;
    _lastSentAt = null;
    _appendToPreviousGpxTrack = false;
    await _repairGpxTrack(gpxTrackFilePath);
  }

  Future<bool> _dropMissingActiveGpxTrackIfNeeded({bool save = true}) async {
    final String? gpxTrackFilePath = _gpxTrackFilePath;
    if (gpxTrackFilePath == null || gpxTrackFilePath.trim().isEmpty) {
      return false;
    }
    if (await File(gpxTrackFilePath).exists()) {
      return false;
    }
    debugPrint(
      '[$liveTrackingFeatureName] Dropping stale active GPX track: $gpxTrackFilePath',
    );
    return _clearMissingGpxTrackReference(gpxTrackFilePath, save: save);
  }

  Future<bool> _clearMissingGpxTrackReference(
    String filePath, {
    bool save = true,
  }) async {
    bool changed = false;
    if (_gpxTrackFilePath == filePath) {
      _firebaseSession = null;
      _firebaseSequence = 0;
      _gpxTrackFilePath = null;
      _lastSentAt = null;
      _appendToPreviousGpxTrack = false;
      changed = true;
    }
    if (_lastGpxTrackFilePath == filePath) {
      _lastGpxTrackFilePath = null;
      changed = true;
    }
    if (changed && save) {
      await _save();
    }
    return changed;
  }

  Future<void> _save() async {
    final SharedPreferences preferences =
        _preferences ?? await SharedPreferences.getInstance();
    _preferences = preferences;
    await preferences.setBool(_enabledKey, _enabled);
    await preferences.setString(_targetKey, _target.name);
    await preferences.setString(_serverUrlKey, _serverUrl);
    await preferences.setString(_tokenKey, _token);
    await preferences.setString(_deviceIdKey, _deviceId);
    await preferences.setInt(_minIntervalMsKey, _minIntervalMs);
    await preferences.setString(_firebaseDatabaseUrlKey, _firebaseDatabaseUrl);
    await preferences.setString(_firebasePathPrefixKey, _firebasePathPrefix);
    await preferences.setBool(
      _appendToPreviousGpxTrackKey,
      _appendToPreviousGpxTrack,
    );
    final String? gpxTrackFilePath = _gpxTrackFilePath;
    final String? lastGpxTrackFilePath = _lastGpxTrackFilePath;
    if (gpxTrackFilePath == null) {
      await preferences.remove(_gpxTrackFilePathKey);
    } else {
      await preferences.setString(_gpxTrackFilePathKey, gpxTrackFilePath);
    }
    if (lastGpxTrackFilePath == null) {
      await preferences.remove(_lastGpxTrackFilePathKey);
    } else {
      await preferences.setString(
        _lastGpxTrackFilePathKey,
        lastGpxTrackFilePath,
      );
    }
    final FirebaseLiveTrackSession? firebaseSession = _firebaseSession;
    if (firebaseSession == null) {
      await preferences.remove(_firebaseSessionIdKey);
      await preferences.remove(_firebaseStartedAtKey);
      await preferences.remove(_firebaseSequenceKey);
    } else {
      await preferences.setString(
        _firebaseSessionIdKey,
        firebaseSession.sessionId,
      );
      await preferences.setString(
        _firebaseStartedAtKey,
        firebaseSession.startedAt.toIso8601String(),
      );
      await preferences.setInt(_firebaseSequenceKey, _firebaseSequence);
    }
  }

  @override
  void dispose() {
    _httpClient.close(force: true);
    _firebaseClient.close();
    super.dispose();
  }
}

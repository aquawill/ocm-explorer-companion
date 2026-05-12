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

import 'package:flutter/material.dart';
import 'package:here_sdk/core.dart';
import 'package:here_sdk/core.engine.dart';
import 'package:here_sdk/location.dart';
import 'package:here_sdk/mapmatcher.dart' as MapMatcher;
import 'package:here_sdk/navigation.dart' as Navigation;
import 'package:here_sdk_reference_application_flutter/common/device_info.dart';
import 'package:here_sdk_reference_application_flutter/live_tracker/live_tracker_location_update.dart';
import 'package:here_sdk/routing.dart' as Routing;
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../common/application_preferences.dart';
import 'here_privacy_notice_handler.dart';

/// Class that implements logic for positioning. It asks for user consent, obtains the necessary permissions,
/// and provides current location updates.
/// The current implementation will only ask for user consent on Android devices.
class PositioningEngine {
  static const int _locationServicePeriodicDurationInSeconds = 3;
  static const int _androidApiLevel30 = 30;
  LocationEngine? _locationEngine;
  MapMatcher.MapMatcher? _liveTrackerMapMatcher;
  bool _liveTrackerBackgroundNavigationEnabled = false;
  int _liveTrackerMapMatchingSampleCount = 0;
  int _liveTrackerConsecutiveUnmatchedCount = 0;
  DateTime? _liveTrackerLastMatchedAt;
  DateTime? _liveTrackerLastMapMatchingDiagnosticLogAt;
  bool? _liveTrackerLastMapMatchingDiagnosticLogMatched;

  StreamController<Location> _locationUpdatesController =
      StreamController.broadcast();
  final _liveTrackerLocationUpdatesController =
      StreamController<LiveTrackerLocationUpdate>.broadcast();
  StreamController<LocationEngineStatus> _locationEngineStatusController =
      StreamController.broadcast();

  /// Initializes the location engine.
  Future initLocationEngine({required BuildContext context}) async {
    return _initialize(context);
  }

  /// Gets last known location.
  Location? get lastKnownLocation => _locationEngine?.lastKnownLocation;

  /// Gets the state of the location engine.
  bool get isLocationEngineStarted =>
      _locationEngine != null ? _locationEngine!.isStarted : false;

  /// Gets stream with location updates.
  Stream<Location> get getLocationUpdates => _locationUpdatesController.stream;

  /// Gets raw and map-matched location updates for live tracking.
  Stream<LiveTrackerLocationUpdate> get getLiveTrackerLocationUpdates =>
      _liveTrackerLocationUpdatesController.stream;

  /// Gets stream with location engine status updates.
  Stream<LocationEngineStatus> get getLocationEngineStatusUpdates =>
      _locationEngineStatusController.stream;

  /// Keeps the HERE SDK navigation stack active for OCM Live Tracking while the
  /// app is in the background. No route or UI rendering is started here.
  void setLiveTrackerBackgroundNavigationEnabled(bool enabled) {
    if (_liveTrackerBackgroundNavigationEnabled == enabled) {
      return;
    }

    _liveTrackerBackgroundNavigationEnabled = enabled;
    _applyLiveTrackerBackgroundNavigationMode();
  }

  /// Returns [true] by check if permission location service status is enabled.
  Future<bool> get _didLocationServicesEnabled =>
      Permission.location.serviceStatus.isEnabled;

  /// This flag helps to request the location permission, when location service status is enabled.
  bool _didLocationPermissionsRequested = false;

  Future<void> _initialize(BuildContext context) async {
    /// Important: This dialog is required to inform users about HERE SDK's privacy terms,
    /// and must be accepted before calling `confirmHEREPrivacyNoticeInclusion()` and initializing the LocationEngine.
    ///
    /// This check determines whether the HERE Privacy Notice dialog has already been shown.
    /// Defaults to false if the key does not exist (e.g., on first app launch).
    if (!Provider.of<AppPreferences>(
      context,
      listen: false,
    ).isHerePrivacyDialogShown) {
      // Show the dialog if it hasn't been shown before.
      await showHerePrivacyDialog(context);
    }

    final didLocationServicesEnabled = await _didLocationServicesEnabled;

    // Check location services status
    if (!didLocationServicesEnabled) {
      _locationEngineStatusController.add(LocationEngineStatus.notAllowed);
    } else if (didLocationServicesEnabled &&
        !await _requestLocationPermissions()) {
      _didLocationPermissionsRequested = true;
      // Request location permission on engine creation.
      _locationEngineStatusController.add(
        LocationEngineStatus.missingPermissions,
      );
    } else {
      await _createLocationEngineIfPermissionsGranted();
    }
    _checkLocationServicesPeriodically();
  }

  /// Periodically checks location services and permissions.
  /// Creates a location engine if all necessary permissions are
  /// granted and engine is not already created.
  void _checkLocationServicesPeriodically() {
    Future.delayed(
      Duration(seconds: _locationServicePeriodicDurationInSeconds),
      () async {
        await _checkLocationServicesStatus();
        _checkLocationServicesPeriodically();
      },
    );
  }

  /// Requests [Permission.location] and [Permission.locationAlways].
  /// Returns [true] if both [Permission.location] and [Permission.locationAlways]
  /// are granted, otherwise returns [false].
  ///
  /// Returns [false] if location services is not enabled.
  Future<bool> _requestLocationPermissions() async {
    if (await _didLocationServicesEnabled) {
      final PermissionStatus locationPermission = await Permission.location
          .request();
      PermissionStatus locationAlwaysPermission = await Permission
          .locationAlways
          .request();
      if (Platform.isAndroid &&
          await getAndroidApiVersion() >= _androidApiLevel30) {
        // Checking background location permission status again because result of request is denied even if user granted
        // this permission (on Android 11). It looks like a permission_handler plugin bug.
        locationAlwaysPermission = await Permission.locationAlways.status;
      }
      return locationPermission == PermissionStatus.granted &&
          locationAlwaysPermission == PermissionStatus.granted;
    } else {
      return false;
    }
  }

  /// Returns [true] if both [Permission.location] and [Permission.locationAlways]
  /// are granted, otherwise returns [false].
  ///
  /// Returns [false] if location services is not enabled.
  Future<bool> _didLocationPermissionsGranted() async {
    if (!await _didLocationServicesEnabled) {
      return false;
    }

    final bool isLocationPermissionGranted =
        await Permission.location.isGranted;
    if (Platform.isAndroid &&
        await getAndroidApiVersion() >= _androidApiLevel30) {
      // Checking background location permission status again because result of request is denied even if user granted
      // this permission (on Android 11). It looks like a permission_handler plugin bug.
      final bool isLocationAlwaysPermissionGranted =
          await Permission.locationAlways.status.isGranted;
      return isLocationPermissionGranted && isLocationAlwaysPermissionGranted;
    }
    return isLocationPermissionGranted;
  }

  void _createAndInitLocationEngine() {
    _locationEngine = LocationEngine();
    _locationUpdatesController.onCancel = () {
      if (!_liveTrackerBackgroundNavigationEnabled) {
        _locationEngine!.stop();
      }
    };
    _locationEngine!.setBackgroundLocationAllowed(
      _liveTrackerBackgroundNavigationEnabled,
    );
    _locationEngine!.setBackgroundLocationIndicatorVisible(
      _liveTrackerBackgroundNavigationEnabled,
    );
    _locationEngine!.setPauseLocationUpdatesAutomatically(
      !_liveTrackerBackgroundNavigationEnabled,
    );
    _locationEngine!.addLocationListener(
      LocationListener((location) {
        _locationUpdatesController.add(location);
        _publishLiveTrackerLocation(location);
      }),
    );
    _locationEngine!.addLocationStatusListener(
      LocationStatusListener(
        (status) => _locationEngineStatusController.add(status),
        (features) {},
      ),
    );

    /// Important: The HERE Privacy Notice must be shown and accepted by the user
    /// before starting the LocationEngine. Ensure the FTU/privacy screen is displayed
    /// at app start-up. This method must be called every time before starting the engine.
    _locationEngine!.confirmHEREPrivacyNoticeInclusion();
    _locationEngine!.startWithLocationAccuracy(LocationAccuracy.bestAvailable);
    _applyLiveTrackerBackgroundNavigationMode();
  }

  /// Restarts the location engine by stopping and starting it again.
  void restartLocationEngine() {
    _locationEngine
      ?..stop()
      ..setBackgroundLocationAllowed(true)
      ..setBackgroundLocationIndicatorVisible(true)
      ..setPauseLocationUpdatesAutomatically(false)
      ..confirmHEREPrivacyNoticeInclusion()
      ..startWithLocationAccuracy(LocationAccuracy.bestAvailable);
  }

  void _applyLiveTrackerBackgroundNavigationMode() {
    final LocationEngine? locationEngine = _locationEngine;
    if (locationEngine == null) {
      return;
    }

    if (_liveTrackerBackgroundNavigationEnabled) {
      locationEngine
        ..setBackgroundLocationAllowed(true)
        ..setBackgroundLocationIndicatorVisible(true)
        ..setPauseLocationUpdatesAutomatically(false)
        ..confirmHEREPrivacyNoticeInclusion();
      if (!locationEngine.isStarted) {
        locationEngine.startWithLocationAccuracy(
          LocationAccuracy.bestAvailable,
        );
      }
      return;
    }

    locationEngine
      ..setBackgroundLocationAllowed(false)
      ..setBackgroundLocationIndicatorVisible(false)
      ..setPauseLocationUpdatesAutomatically(true);
  }

  void _publishLiveTrackerLocation(Location location) {
    if (_liveTrackerLocationUpdatesController.isClosed) {
      return;
    }

    final DateTime observedAt = DateTime.now().toUtc();
    Object? matchError;
    StackTrace? matchStackTrace;
    Navigation.MapMatchedLocation? matchedLocation;
    try {
      matchedLocation = _liveTrackerMapMatcherForDiagnostics()?.match(location);
    } catch (error, stackTrace) {
      matchError = error;
      matchStackTrace = stackTrace;
    }

    final bool hasMatchedLocation = matchedLocation != null;
    _liveTrackerMapMatchingSampleCount++;
    if (hasMatchedLocation) {
      _liveTrackerConsecutiveUnmatchedCount = 0;
      _liveTrackerLastMatchedAt = observedAt;
    } else {
      _liveTrackerConsecutiveUnmatchedCount++;
    }

    final Map<String, dynamic> diagnostics = _mapMatchingDiagnosticsFor(
      rawLocation: location,
      matchedLocation: matchedLocation,
      observedAt: observedAt,
      matchError: matchError,
      matchStackTrace: matchStackTrace,
    );
    _logMapMatchingDiagnostics(diagnostics, hasMatchedLocation, observedAt);
    _liveTrackerLocationUpdatesController.add(
      LiveTrackerLocationUpdate(
        rawLocation: location,
        matchedLocation: matchedLocation,
        mapMatchingDiagnostics: diagnostics,
      ),
    );
  }

  MapMatcher.MapMatcher? _liveTrackerMapMatcherForDiagnostics() {
    final MapMatcher.MapMatcher? existing = _liveTrackerMapMatcher;
    if (existing != null) {
      return existing;
    }

    final SDKNativeEngine? sdkNativeEngine = SDKNativeEngine.sharedInstance;
    if (sdkNativeEngine == null) {
      return null;
    }

    return _liveTrackerMapMatcher = MapMatcher.MapMatcher.withLayers(
      sdkNativeEngine,
      true,
    );
  }

  Map<String, dynamic> _mapMatchingDiagnosticsFor({
    required Location rawLocation,
    required Navigation.MapMatchedLocation? matchedLocation,
    required DateTime observedAt,
    Object? matchError,
    StackTrace? matchStackTrace,
  }) {
    final DateTime? lastMatchedAt = _liveTrackerLastMatchedAt;
    return <String, dynamic>{
      'type': 'mapMatching',
      'source': 'MapMatcher.match',
      'observedAt': observedAt.toIso8601String(),
      'sampleCount': _liveTrackerMapMatchingSampleCount,
      'hasMatchedLocation': matchedLocation != null,
      'consecutiveUnmatchedCount': _liveTrackerConsecutiveUnmatchedCount,
      if (lastMatchedAt != null)
        'lastMatchedAt': lastMatchedAt.toIso8601String(),
      if (lastMatchedAt != null && matchedLocation == null)
        'timeSinceLastMatchedMs': observedAt
            .difference(lastMatchedAt)
            .inMilliseconds,
      'locationEngineStarted': _locationEngine?.isStarted,
      'mapMatcherReady': _liveTrackerMapMatcher != null,
      'backgroundNavigationEnabled': _liveTrackerBackgroundNavigationEnabled,
      'raw': _locationDiagnostics(rawLocation),
      if (matchedLocation != null)
        'matched': _mapMatchedLocationDiagnostics(matchedLocation),
      if (matchError != null)
        'error': <String, dynamic>{
          'type': matchError.runtimeType.toString(),
          'message': matchError.toString(),
          if (matchStackTrace != null) 'stackTrace': matchStackTrace.toString(),
        },
      if (matchedLocation == null)
        'message':
            'HERE SDK MapMatcher returned null mapMatchedLocation; segment evidence lookup skipped.',
    }..removeWhere((_, Object? value) => value == null);
  }

  void _logMapMatchingDiagnostics(
    Map<String, dynamic> diagnostics,
    bool hasMatchedLocation,
    DateTime observedAt,
  ) {
    final DateTime? lastLogAt = _liveTrackerLastMapMatchingDiagnosticLogAt;
    final bool stateChanged =
        _liveTrackerLastMapMatchingDiagnosticLogMatched != hasMatchedLocation;
    final int? elapsedSinceLogSeconds = lastLogAt == null
        ? null
        : observedAt.difference(lastLogAt).inSeconds;
    final bool shouldLog =
        stateChanged ||
        elapsedSinceLogSeconds == null ||
        (!hasMatchedLocation && elapsedSinceLogSeconds >= 3) ||
        elapsedSinceLogSeconds >= 15;

    if (!shouldLog) {
      return;
    }

    _liveTrackerLastMapMatchingDiagnosticLogAt = observedAt;
    _liveTrackerLastMapMatchingDiagnosticLogMatched = hasMatchedLocation;
    debugPrint(
      '[OCM MapMatching]\n'
      '${const JsonEncoder.withIndent('  ').convert(diagnostics)}',
    );
  }

  Map<String, dynamic> _locationDiagnostics(Location location) {
    return <String, dynamic>{
      'coordinates': _geoCoordinatesDiagnostics(location.coordinates),
      'horizontalAccuracyM': _finiteDouble(location.horizontalAccuracyInMeters),
      'verticalAccuracyM': _finiteDouble(location.verticalAccuracyInMeters),
      'speedMps': _finiteDouble(location.speedInMetersPerSecond),
      'speedAccuracyMps': _finiteDouble(
        location.speedAccuracyInMetersPerSecond,
      ),
      'bearingDeg': _finiteDouble(location.bearingInDegrees),
      'bearingAccuracyDeg': _finiteDouble(location.bearingAccuracyInDegrees),
      'time': location.time?.toUtc().toIso8601String(),
      'timestampSinceBootMs': location.timestampSinceBoot?.inMilliseconds,
      'gnssTimeMs': location.gnssTime?.inMilliseconds,
      'locationTechnology': _enumName(location.locationTechnology),
      'pitchDeg': _finiteDouble(location.pitchInDegrees),
      'laneIndex': location.laneIndex,
    }..removeWhere((_, Object? value) => value == null);
  }

  Map<String, dynamic> _mapMatchedLocationDiagnostics(
    Navigation.MapMatchedLocation location,
  ) {
    return <String, dynamic>{
      'coordinates': _geoCoordinatesDiagnostics(location.coordinates),
      'confidence': _finiteDouble(location.confidence),
      'segmentReference': _segmentReferenceDiagnostics(
        location.segmentReference,
      ),
      'segmentOffsetCm': location.segmentOffsetInCentimeters,
      'isDrivingInTheWrongWay': location.isDrivingInTheWrongWay,
      'horizontalAccuracyM': _finiteDouble(location.horizontalAccuracyInMeters),
      'speedMps': _finiteDouble(location.speedInMetersPerSecond),
      'bearingDeg': _finiteDouble(location.bearingInDegrees),
      'timestamp': location.timestamp?.toUtc().toIso8601String(),
    }..removeWhere((_, Object? value) => value == null);
  }

  Map<String, dynamic> _geoCoordinatesDiagnostics(GeoCoordinates coordinates) {
    return <String, dynamic>{
      'lat': _finiteDouble(coordinates.latitude),
      'lon': _finiteDouble(coordinates.longitude),
      'altitudeM': _finiteDouble(coordinates.altitude),
    }..removeWhere((_, Object? value) => value == null);
  }

  Map<String, dynamic> _segmentReferenceDiagnostics(
    Routing.SegmentReference segmentReference,
  ) {
    return <String, dynamic>{
      'segmentId': segmentReference.segmentId,
      'travelDirection': _enumName(segmentReference.travelDirection),
      'offsetStart': _finiteDouble(segmentReference.offsetStart),
      'offsetEnd': _finiteDouble(segmentReference.offsetEnd),
      'tilePartitionId': segmentReference.tilePartitionId,
      'localId': segmentReference.localId,
    }..removeWhere((_, Object? value) => value == null);
  }

  double? _finiteDouble(double? value) {
    return value == null || !value.isFinite ? null : value;
  }

  String? _enumName(Object? value) {
    if (value == null) {
      return null;
    }
    final String text = value.toString();
    final int dot = text.lastIndexOf('.');
    return dot >= 0 ? text.substring(dot + 1) : text;
  }

  /// Creates and initialises the location engine if all required permissions
  /// are granted.
  Future<void> _createLocationEngineIfPermissionsGranted() async {
    if (await _didLocationPermissionsGranted()) {
      // The required permissions have been granted, let's start the location engine
      _createAndInitLocationEngine();
    } else if (!_didLocationPermissionsRequested) {
      _didLocationPermissionsRequested = true;
      final isGranted = await _requestLocationPermissions();
      if (!isGranted) {
        _locationEngineStatusController.add(
          LocationEngineStatus.missingPermissions,
        );
      }
    }
  }

  Future<void> _checkLocationServicesStatus() async {
    final bool didLocationServicesEnabled = await _didLocationServicesEnabled;
    if (didLocationServicesEnabled && _locationEngine != null) {
      return; // As location engine is already created, we do not need to create a new one.
    }
    if (didLocationServicesEnabled) {
      await _createLocationEngineIfPermissionsGranted();
    }
  }
}

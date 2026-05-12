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
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:here_sdk/core.dart';
import 'package:here_sdk/core.engine.dart';
import 'package:here_sdk/gestures.dart';
import 'package:here_sdk/location.dart';
import 'package:here_sdk/mapview.dart';
import 'package:here_sdk/search.dart';
import 'package:here_sdk_reference_application_flutter/common/hds_icons/hds_assets_paths.dart';
import 'package:here_sdk_reference_application_flutter/l10n/generated/app_localizations.dart';
import 'package:here_sdk_reference_application_flutter/routing/routing_screen.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:provider/provider.dart';

import 'common/app_identity.dart';
import 'common/hds_icons/hds_icon_widget.dart';
import 'common/notifications/android_notifications.dart';
import 'common/notifications/notifications_manager.dart';
import 'common/place_actions_popup.dart';
import 'common/reset_location_button.dart';
import 'common/share_file_service.dart';
import 'common/ui_style.dart';
import 'common/util.dart' as Util;
import 'live_tracker/live_tracker_location_update.dart';
import 'live_tracker/live_tracker_service.dart';
import 'live_tracker/live_tracker_settings_dialog.dart';
import 'positioning/here_privacy_notice_handler.dart';
import 'positioning/no_location_warning_widget.dart';
import 'positioning/positioning.dart';
import 'positioning/positioning_engine.dart';
import 'routing/waypoint_info.dart';
import 'search/search_popup.dart';

/// The home screen of the application.
class LandingScreen extends StatefulWidget {
  static const String navRoute = "/";
  static final GlobalKey<_LandingScreenState> landingScreenKey = GlobalKey();

  LandingScreen({Key? key}) : super(key: key);

  @override
  _LandingScreenState createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen>
    with Positioning, WidgetsBindingObserver {
  static const int _kLocationWarningDismissPeriod = 5; // seconds

  bool _mapInitSuccess = false;
  bool _nightMapScheme = false;
  bool _liveSegmentDetailsExpanded = false;
  bool _didBackPressedAndPositionStopped = false;
  late HereMapController _hereMapController;
  late PositioningEngine _positioningEngine;
  LiveTrackerService? _liveTrackerService;
  final AndroidNotificationsManager _liveTrackerAndroidNotifications =
      AndroidNotificationsManager();
  bool? _liveTrackerBackgroundNavigationSyncedEnabled;
  bool _liveTrackerForegroundServiceRequested = false;
  bool _liveTrackerForegroundServiceActive = false;
  StreamSubscription? _liveTrackerLocationSubscription;
  GlobalKey _hereMapWidgetKey = GlobalKey();
  OverlayEntry? _locationWarningOverlay;
  MapMarker? _routeFromMarker;
  MapMarker? _matchedLocationMarker;
  final List<MapPolyline> _matchedSegmentPolylines = [];
  MapMarker? _matchedSegmentStartMarker;
  MapMarker? _matchedSegmentEndMarker;
  final List<MapMarker> _matchedSegmentDirectionMarkers = [];
  String? _matchedSegmentPolylineKey;
  Place? _routeFromPlace;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _positioningEngine = Provider.of<PositioningEngine>(context, listen: false);
    _startLiveTrackerLocationUpdates();
    final LiveTrackerService tracker = Provider.of<LiveTrackerService>(
      context,
      listen: false,
    );
    if (!identical(_liveTrackerService, tracker)) {
      _liveTrackerService?.removeListener(_handleLiveTrackerChanged);
      _liveTrackerService = tracker;
      _liveTrackerService!.addListener(_handleLiveTrackerChanged);
      _handleLiveTrackerChanged();
    }
  }

  @override
  void dispose() {
    _liveTrackerLocationSubscription?.cancel();
    _liveTrackerService?.removeListener(_handleLiveTrackerChanged);
    unawaited(_syncLiveTrackerForegroundService(false));
    stopPositioning();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _handleLiveTrackerChanged() {
    _syncLiveTrackerBackgroundNavigation();
    _syncLiveTrackerMapOverlays();
  }

  void _syncLiveTrackerBackgroundNavigation() {
    final bool enabled = _liveTrackerService?.enabled ?? false;
    if (_liveTrackerBackgroundNavigationSyncedEnabled == enabled) {
      return;
    }
    _liveTrackerBackgroundNavigationSyncedEnabled = enabled;
    _positioningEngine.setLiveTrackerBackgroundNavigationEnabled(enabled);
    unawaited(_syncLiveTrackerForegroundService(enabled));
  }

  Future<void> _syncLiveTrackerForegroundService(bool enabled) async {
    if (!Platform.isAndroid) {
      return;
    }

    _liveTrackerForegroundServiceRequested = enabled;
    try {
      if (enabled) {
        if (_liveTrackerForegroundServiceActive) {
          return;
        }
        await _liveTrackerAndroidNotifications.init();
        if (!_liveTrackerForegroundServiceRequested) {
          return;
        }
        await _liveTrackerAndroidNotifications.showNotification(
          NotificationBody(
            title: liveTrackingFeatureName,
            body: 'Sharing live location',
            imagePath: 'assets/ocm_live_tracker_icon.png',
            presentSound: false,
          ),
        );
        if (!_liveTrackerForegroundServiceRequested) {
          await _liveTrackerAndroidNotifications.dismissNotification();
          return;
        }
        _liveTrackerForegroundServiceActive = true;
        return;
      }

      if (!_liveTrackerForegroundServiceActive) {
        return;
      }
      await _liveTrackerAndroidNotifications.dismissNotification();
      _liveTrackerForegroundServiceActive = false;
    } catch (error) {
      debugPrint(
        '[$liveTrackingFeatureName] Failed to sync Android foreground service: $error',
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Stops the location engine when app is detached.
    if (state == AppLifecycleState.detached) {
      // This flag helps us to re-init the positioning when app is resumed.
      _didBackPressedAndPositionStopped = true;
      stopPositioning();
    } else if (state == AppLifecycleState.resumed &&
        _didBackPressedAndPositionStopped) {
      _didBackPressedAndPositionStopped = false;
      // Restart the location engine and initiate positioning when the app is resumed.
      _positioningEngine.initLocationEngine(context: context).then((value) {
        initPositioning(
          context: context,
          hereMapController: _hereMapController,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final HereMapOptions options = HereMapOptions()
      ..initialBackgroundColor = Theme.of(context).colorScheme.surface;
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          HereMap(
            key: _hereMapWidgetKey,
            options: options,
            onMapCreated: _onMapCreated,
          ),
          _buildMenuButton(),
          if (_mapInitSuccess) _buildMapSchemeButton(),
          if (_mapInitSuccess) _buildLiveSegmentPanel(),
        ],
      ),
      floatingActionButton: _mapInitSuccess ? _buildFAB(context) : null,
      drawer: _buildDrawer(context),
      extendBodyBehindAppBar: true,
      onDrawerChanged: (isOpened) => _dismissLocationWarningPopup(),
    );
  }

  void _onMapCreated(HereMapController hereMapController) {
    debugPrint('[$companionAppName] HereMap created.');
    _hereMapController = hereMapController;
    HereMapController.primaryLanguage = LanguageCode.enUs;
    HereMapController.secondaryLanguage = null;

    _loadMapScene(initial: true);
  }

  MapScheme get _currentMapScheme =>
      _nightMapScheme ? MapScheme.normalNight : MapScheme.normalDay;

  String get _currentMapSchemeName =>
      _nightMapScheme ? 'normalNight' : 'normalDay';

  void _loadMapScene({required bool initial}) {
    debugPrint(
      '[$companionAppName] Loading HERE map scene: $_currentMapSchemeName.',
    );
    _hereMapController.mapScene.loadSceneForMapScheme(_currentMapScheme, (
      MapError? error,
    ) {
      if (error != null) {
        debugPrint(
          '[$companionAppName] Map scene not loaded. MapError: $error',
        );
        return;
      }
      debugPrint('[$companionAppName] Map scene loaded.');

      if (!initial) {
        _forceNorthUp();
        _syncLiveTrackerMapOverlays();
        return;
      }

      _hereMapController.camera.lookAtPointWithGeoOrientationAndMeasure(
        Positioning.initPosition,
        GeoOrientationUpdate(0, 0),
        MapMeasure(
          MapMeasureKind.distanceInMeters,
          Positioning.initDistanceToEarth,
        ),
      );

      _hereMapController.setWatermarkLocation(
        Anchor2D.withHorizontalAndVertical(0, 1),
        Point2D(
          -_hereMapController.watermarkSize.width / 2,
          -_hereMapController.watermarkSize.height / 2,
        ),
      );

      _addGestureListeners();

      _positioningEngine = Provider.of<PositioningEngine>(
        context,
        listen: false,
      );
      _positioningEngine.getLocationEngineStatusUpdates.listen(
        _checkLocationStatus,
      );
      _positioningEngine.initLocationEngine(context: context).then((value) {
        debugPrint('[$companionAppName] Location engine init completed.');
        initPositioning(
          context: context,
          hereMapController: _hereMapController,
        );
      });

      setState(() {
        _mapInitSuccess = true;
      });
      _syncLiveTrackerMapOverlays();
    });
  }

  Widget _buildMenuButton() {
    ColorScheme colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Builder(
        builder: (context) => Padding(
          padding: EdgeInsets.all(UIStyle.contentMarginLarge),
          child: Material(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(UIStyle.popupsBorderRadius),
            elevation: 2,
            child: InkWell(
              borderRadius: BorderRadius.circular(UIStyle.popupsBorderRadius),
              child: Padding(
                padding: EdgeInsets.all(UIStyle.contentMarginMedium),
                child: const HdsIconWidget(HdsAssetsPaths.menuSolidIcon),
              ),
              onTap: () => Scaffold.of(context).openDrawer(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMapSchemeButton() {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return SafeArea(
      child: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: EdgeInsets.all(UIStyle.contentMarginLarge),
          child: Material(
            color: colorScheme.surface,
            borderRadius: BorderRadius.circular(UIStyle.popupsBorderRadius),
            elevation: 2,
            child: IconButton(
              icon: Icon(
                _nightMapScheme ? Icons.light_mode : Icons.dark_mode,
                color: colorScheme.onSurface,
              ),
              tooltip: _nightMapScheme
                  ? 'Switch to day mode'
                  : 'Switch to night mode',
              onPressed: _toggleMapScheme,
            ),
          ),
        ),
      ),
    );
  }

  void _toggleMapScheme() {
    _removeMatchedLocationMarker();
    _clearMatchedSegmentPolyline();
    setState(() => _nightMapScheme = !_nightMapScheme);
    _loadMapScene(initial: false);
  }

  Widget _buildLiveSegmentPanel() {
    final double maxPanelHeight = MediaQuery.of(context).size.height * 0.46;

    return SafeArea(
      child: Align(
        alignment: Alignment.bottomLeft,
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            UIStyle.contentMarginLarge,
            0,
            UIStyle.bigButtonHeight + UIStyle.contentMarginExtraLarge,
            UIStyle.contentMarginLarge,
          ),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 440,
              maxHeight: maxPanelHeight,
            ),
            child: Consumer<LiveTrackerService>(
              builder: (context, tracker, _) =>
                  _buildLiveSegmentPanelContent(tracker),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLiveSegmentPanelContent(LiveTrackerService tracker) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final String statusText = _liveSegmentStatusText(tracker);
    final Color statusColor = _liveSegmentStatusColor(tracker);
    final bool canShareCsv = _canShareLiveSegmentCsv(tracker);

    return Material(
      color: colorScheme.surface.withValues(alpha: 0.94),
      borderRadius: BorderRadius.circular(UIStyle.popupsBorderRadius),
      elevation: 4,
      child: Padding(
        padding: EdgeInsets.all(UIStyle.contentMarginMedium),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.route, size: 20, color: statusColor),
                SizedBox(width: UIStyle.contentMarginSmall),
                Expanded(
                  child: Text(
                    'OCM Segment',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: colorScheme.onSurface,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                _buildLiveSegmentStatusPill(statusText, statusColor),
                IconButton(
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  icon: Icon(
                    Icons.ios_share,
                    color: canShareCsv
                        ? colorScheme.onSurface
                        : colorScheme.onSurface.withValues(alpha: 0.35),
                  ),
                  tooltip: 'Export CSV',
                  onPressed: canShareCsv
                      ? () => _shareLiveSegmentCsv(tracker)
                      : null,
                ),
                IconButton(
                  constraints: const BoxConstraints.tightFor(
                    width: 36,
                    height: 36,
                  ),
                  icon: Icon(
                    _liveSegmentDetailsExpanded
                        ? Icons.expand_more
                        : Icons.expand_less,
                    color: colorScheme.onSurface,
                  ),
                  tooltip: _liveSegmentDetailsExpanded
                      ? 'Collapse details'
                      : 'Expand details',
                  onPressed: () => setState(
                    () => _liveSegmentDetailsExpanded =
                        !_liveSegmentDetailsExpanded,
                  ),
                ),
              ],
            ),
            SizedBox(height: UIStyle.contentMarginSmall),
            ..._liveSegmentSummaryRows(
              tracker,
            ).map((row) => _buildLiveSegmentSummaryRow(row.key, row.value)),
            if (_liveSegmentDetailsExpanded) ...[
              SizedBox(height: UIStyle.contentMarginMedium),
              Flexible(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(
                      alpha: 0.72,
                    ),
                    borderRadius: BorderRadius.circular(
                      UIStyle.popupsBorderRadius,
                    ),
                  ),
                  child: SingleChildScrollView(
                    padding: EdgeInsets.all(UIStyle.contentMarginSmall),
                    child: _buildLiveSegmentDetailsTable(tracker),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildLiveSegmentStatusPill(String text, Color color) {
    return Container(
      constraints: const BoxConstraints(minHeight: 28),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(UIStyle.popupsBorderRadius),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: color,
          fontSize: UIStyle.smallFontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildLiveSegmentSummaryRow(String label, String value) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: UIStyle.smallFontSize,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: UIStyle.smallFontSize,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _liveSegmentStatusText(LiveTrackerService tracker) {
    final LiveTrackerLocationUpdate? update = tracker.latestLocationUpdate;
    if (update == null) {
      return 'Waiting for location';
    }
    if (update.matchedLocation == null) {
      return 'Not map matched';
    }
    final String? status = tracker.latestSegmentEvidence?['status']?.toString();
    switch (status) {
      case 'loaded':
        return 'Segment OK';
      case 'partial':
        return 'Partial data';
      case 'noSegments':
        return 'No segment';
      case 'error':
        return 'Query error';
      default:
        return 'Map matched';
    }
  }

  Color _liveSegmentStatusColor(LiveTrackerService tracker) {
    final LiveTrackerLocationUpdate? update = tracker.latestLocationUpdate;
    if (update == null) {
      return Colors.blueGrey;
    }
    if (update.matchedLocation == null) {
      return Colors.orange;
    }
    final String? status = tracker.latestSegmentEvidence?['status']?.toString();
    if (status == 'error') {
      return Colors.redAccent;
    }
    if (status == 'partial') {
      return Colors.amber.shade800;
    }
    if (status == 'noSegments') {
      return Colors.deepOrange;
    }
    return Colors.teal;
  }

  List<MapEntry<String, String>> _liveSegmentSummaryRows(
    LiveTrackerService tracker,
  ) {
    final LiveTrackerLocationUpdate? update = tracker.latestLocationUpdate;
    final Map<String, dynamic>? payload = tracker.latestLocationPayload;
    final Map<String, dynamic>? evidence = tracker.latestSegmentEvidence;
    if (update == null || payload == null) {
      return const [
        MapEntry('Status', 'Waiting for map matching location output'),
      ];
    }

    final Map<String, dynamic>? raw = _asMap(payload['raw']);
    final Map<String, dynamic>? matched = _asMap(payload['matched']);
    final Map<String, dynamic>? diagnostics =
        tracker.latestMapMatchingDiagnostics;
    final Map<String, dynamic>? selected = _asMap(evidence?['selected']);
    final Map<String, dynamic>? selectedId = _asMap(selected?['id']);
    final Map<String, dynamic>? matchedSpan = _asMap(evidence?['matchedSpan']);
    final Map<String, dynamic>? span = _asMap(matchedSpan?['span']);
    final Map<String, dynamic>? undirectedMatchedSpan = _asMap(
      evidence?['undirectedMatchedSpan'],
    );
    final Map<String, dynamic>? undirectedSpan = _asMap(
      undirectedMatchedSpan?['span'],
    );
    final List<MapEntry<String, String>> rows = [
      MapEntry('Raw', _formatCoordinates(raw)),
      MapEntry('Matched', _formatCoordinates(matched)),
      MapEntry('Raw-Matched', _formatRawMatchedDistance(update)),
    ];
    if (diagnostics != null) {
      rows.add(
        MapEntry(
          'MM samples',
          '${diagnostics['sampleCount'] ?? '-'} '
              '(${diagnostics['consecutiveUnmatchedCount'] ?? 0} unmatched)',
        ),
      );
      rows.add(
        MapEntry(
          'Raw accuracy',
          _formatMeters(_asMap(diagnostics['raw'])?['horizontalAccuracyM']),
        ),
      );
      final Object? timeSinceLastMatchedMs =
          diagnostics['timeSinceLastMatchedMs'];
      if (timeSinceLastMatchedMs != null) {
        rows.add(
          MapEntry('Last matched', _formatDurationMs(timeSinceLastMatchedMs)),
        );
      }
    }

    if (selectedId != null) {
      rows.add(
        MapEntry(
          'OCMSegmentId',
          '${selectedId['tilePartitionId'] ?? '-'} / ${selectedId['localId'] ?? '-'}',
        ),
      );
    }
    if (span != null) {
      rows.add(MapEntry('Road', _formatRoadName(span)));
      rows.add(
        MapEntry(
          'Span',
          '${matchedSpan?['index'] ?? '-'} '
              '(${_formatMeters(matchedSpan?['spanStartOffsetM'])}-'
              '${_formatMeters(matchedSpan?['spanEndOffsetM'])})',
        ),
      );
      rows.add(
        MapEntry(
          'FRC / Urban',
          '${span['functionalRoadClass'] ?? '-'} / '
              '${span['isUrban'] ?? undirectedSpan?['isUrban'] ?? '-'}',
        ),
      );
      rows.add(
        MapEntry(
          'Speed limit / base',
          '${_formatSpeedLimit(_asMap(span['speedLimit']))} / '
              '${_formatSpeedMps(span['baseSpeedMps'])}',
        ),
      );
    } else if (evidence != null) {
      rows.add(MapEntry('Segment', evidence['status']?.toString() ?? '-'));
    }

    return rows;
  }

  Map<String, dynamic> _liveSegmentDetailsData(LiveTrackerService tracker) {
    return {
      'observedAt': tracker.latestLocationObservedAt?.toIso8601String(),
      'location': tracker.latestLocationPayload,
      'mapMatchingDiagnostics': tracker.latestMapMatchingDiagnostics,
      'segmentEvidence': tracker.latestSegmentEvidence,
    }..removeWhere((_, Object? value) => value == null);
  }

  bool _canShareLiveSegmentCsv(LiveTrackerService tracker) {
    return _liveSegmentDetailsData(tracker).isNotEmpty;
  }

  Future<void> _shareLiveSegmentCsv(LiveTrackerService tracker) async {
    final Map<String, dynamic> details = _liveSegmentDetailsData(tracker);
    if (details.isEmpty) {
      _showLiveSegmentCsvMessage('No OCM segment data to export yet.');
      return;
    }

    try {
      final String fileName = _liveSegmentCsvFileName(tracker);
      await ShareFileService.shareTextFile(
        fileName: fileName,
        content: _liveSegmentCsv(details),
        mimeType: 'text/csv',
        subject: 'OCM Segment CSV',
        text: fileName,
      );
    } catch (error) {
      _showLiveSegmentCsvMessage('CSV export failed: $error');
    }
  }

  void _showLiveSegmentCsvMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  String _liveSegmentCsvFileName(LiveTrackerService tracker) {
    final Map<String, dynamic>? evidence = tracker.latestSegmentEvidence;
    final Map<String, dynamic>? selected = _asMap(evidence?['selected']);
    final Map<String, dynamic>? selectedId = _asMap(selected?['id']);
    final String segmentId = selectedId == null
        ? 'unmatched'
        : '${selectedId['tilePartitionId'] ?? 'unknown'}-'
              '${selectedId['localId'] ?? 'unknown'}';
    final DateTime observedAt =
        tracker.latestLocationObservedAt?.toUtc() ?? DateTime.now().toUtc();
    final String timestamp = observedAt
        .toIso8601String()
        .replaceAll(RegExp(r'[:-]'), '')
        .replaceFirst(RegExp(r'\.\d+Z$'), 'Z');
    return 'ocm-segment-$segmentId-$timestamp.csv';
  }

  String _liveSegmentCsv(Map<String, dynamic> details) {
    final List<_LiveSegmentCsvRow> rows = _liveSegmentCsvRows(details);
    final StringBuffer buffer = StringBuffer(String.fromCharCode(0xfeff));
    buffer.writeln('path,label,value,type,depth');
    for (final _LiveSegmentCsvRow row in rows) {
      buffer.writeln(
        [
          row.path,
          row.label,
          row.value,
          row.type,
          row.depth.toString(),
        ].map(_csvEscape).join(','),
      );
    }
    return buffer.toString();
  }

  List<_LiveSegmentCsvRow> _liveSegmentCsvRows(Map<String, dynamic> details) {
    final List<_LiveSegmentCsvRow> rows = [];
    for (final MapEntry<String, dynamic> entry in details.entries) {
      _appendLiveSegmentCsvRows(
        rows,
        path: entry.key,
        label: entry.key,
        value: entry.value,
        depth: 0,
      );
    }
    return rows;
  }

  void _appendLiveSegmentCsvRows(
    List<_LiveSegmentCsvRow> rows, {
    required String path,
    required String label,
    required Object? value,
    required int depth,
  }) {
    final Map<String, dynamic>? map = _asMap(value);
    if (map != null) {
      rows.add(
        _LiveSegmentCsvRow(
          path: path,
          label: label,
          value: '${map.length} attributes',
          type: 'map',
          depth: depth,
        ),
      );
      for (final MapEntry<String, dynamic> entry in map.entries) {
        _appendLiveSegmentCsvRows(
          rows,
          path: '$path.${entry.key}',
          label: entry.key,
          value: entry.value,
          depth: depth + 1,
        );
      }
      return;
    }

    if (value is List) {
      rows.add(
        _LiveSegmentCsvRow(
          path: path,
          label: label,
          value: '${value.length} items',
          type: 'list',
          depth: depth,
        ),
      );
      for (int index = 0; index < value.length; index++) {
        _appendLiveSegmentCsvRows(
          rows,
          path: '$path[$index]',
          label: '[$index]',
          value: value[index],
          depth: depth + 1,
        );
      }
      return;
    }

    rows.add(
      _LiveSegmentCsvRow(
        path: path,
        label: label,
        value: _formatLiveSegmentCsvValue(value),
        type: _liveSegmentCsvValueType(value),
        depth: depth,
      ),
    );
  }

  String _formatLiveSegmentCsvValue(Object? value) {
    if (value == null) {
      return '';
    }
    return value.toString();
  }

  String _liveSegmentCsvValueType(Object? value) {
    if (value == null) {
      return 'null';
    }
    if (value is String) {
      return 'string';
    }
    if (value is bool) {
      return 'bool';
    }
    if (value is int) {
      return 'int';
    }
    if (value is double) {
      return 'double';
    }
    if (value is num) {
      return 'num';
    }
    return value.runtimeType.toString();
  }

  String _csvEscape(String value) {
    if (!value.contains(',') &&
        !value.contains('"') &&
        !value.contains('\n') &&
        !value.contains('\r')) {
      return value;
    }
    return '"${value.replaceAll('"', '""')}"';
  }

  Widget _buildLiveSegmentDetailsTable(LiveTrackerService tracker) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final List<_LiveSegmentDetailRow> rows = _liveSegmentDetailRows(
      _liveSegmentDetailsData(tracker),
    );

    if (rows.isEmpty) {
      return Text(
        '--',
        style: TextStyle(
          color: colorScheme.onSurfaceVariant,
          fontSize: UIStyle.smallFontSize,
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildLiveSegmentDetailHeader(),
        for (int index = 0; index < rows.length; index++)
          _buildLiveSegmentDetailRow(rows[index], index),
      ],
    );
  }

  Widget _buildLiveSegmentDetailHeader() {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
      decoration: BoxDecoration(
        color: colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 150,
            child: Text(
              'Attribute',
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: UIStyle.smallFontSize,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          Expanded(
            child: Text(
              'Value',
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: UIStyle.smallFontSize,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLiveSegmentDetailRow(_LiveSegmentDetailRow row, int index) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final Color background = row.isGroup
        ? colorScheme.secondary.withValues(alpha: 0.06)
        : index.isEven
        ? colorScheme.surface.withValues(alpha: 0.48)
        : Colors.transparent;
    final TextStyle labelStyle = TextStyle(
      color: row.isGroup ? colorScheme.onSurface : colorScheme.onSurfaceVariant,
      fontSize: UIStyle.smallFontSize,
      fontWeight: row.isGroup ? FontWeight.w700 : FontWeight.w500,
      height: 1.25,
    );
    final TextStyle valueStyle = TextStyle(
      color: row.isGroup ? colorScheme.onSurfaceVariant : colorScheme.onSurface,
      fontSize: UIStyle.smallFontSize,
      fontFeatures: const [FontFeature.tabularFigures()],
      height: 1.25,
    );

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 6),
      color: background,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Padding(
              padding: EdgeInsets.only(left: row.depth * 10.0),
              child: Text(row.label, style: labelStyle),
            ),
          ),
          Expanded(child: SelectableText(row.value, style: valueStyle)),
        ],
      ),
    );
  }

  List<_LiveSegmentDetailRow> _liveSegmentDetailRows(
    Map<String, dynamic> details,
  ) {
    final List<_LiveSegmentDetailRow> rows = [];
    for (final MapEntry<String, dynamic> entry in details.entries) {
      _appendLiveSegmentDetailRows(rows, entry.key, entry.value, 0);
    }
    return rows;
  }

  void _appendLiveSegmentDetailRows(
    List<_LiveSegmentDetailRow> rows,
    String label,
    Object? value,
    int depth,
  ) {
    final Map<String, dynamic>? map = _asMap(value);
    if (map != null) {
      rows.add(
        _LiveSegmentDetailRow(
          label: label,
          value: '${map.length} attributes',
          depth: depth,
          isGroup: true,
        ),
      );
      for (final MapEntry<String, dynamic> entry in map.entries) {
        _appendLiveSegmentDetailRows(rows, entry.key, entry.value, depth + 1);
      }
      return;
    }

    if (value is List) {
      rows.add(
        _LiveSegmentDetailRow(
          label: label,
          value: '${value.length} items',
          depth: depth,
          isGroup: true,
        ),
      );
      for (int index = 0; index < value.length; index++) {
        _appendLiveSegmentDetailRows(rows, '[$index]', value[index], depth + 1);
      }
      return;
    }

    rows.add(
      _LiveSegmentDetailRow(
        label: label,
        value: _formatLiveSegmentDetailValue(value),
        depth: depth,
      ),
    );
  }

  String _formatLiveSegmentDetailValue(Object? value) {
    if (value == null) {
      return '--';
    }
    if (value is double) {
      return value.isFinite ? value.toStringAsFixed(6) : value.toString();
    }
    if (value is num || value is bool) {
      return value.toString();
    }
    final String text = value.toString();
    return text.isEmpty ? '--' : text;
  }

  Map<String, dynamic>? _asMap(Object? value) {
    if (value is Map<String, dynamic>) {
      return value;
    }
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return null;
  }

  String _formatCoordinates(Map<String, dynamic>? coordinates) {
    final double? lat = _asDouble(coordinates?['lat']);
    final double? lon = _asDouble(coordinates?['lon']);
    if (lat == null || lon == null) {
      return '--';
    }
    return '${lat.toStringAsFixed(6)}, ${lon.toStringAsFixed(6)}';
  }

  String _formatRawMatchedDistance(LiveTrackerLocationUpdate update) {
    final GeoCoordinates? matchedCoordinates =
        update.matchedLocation?.coordinates;
    if (matchedCoordinates == null) {
      return '--';
    }
    return _formatMeters(
      update.rawLocation.coordinates.distanceTo(matchedCoordinates),
    );
  }

  String _formatRoadName(Map<String, dynamic> span) {
    final String? roadNumber = _defaultLocalizedText(span['roadNumbers']);
    final String? streetName = _defaultLocalizedText(span['streetNames']);
    final List<String> parts = [
      if (roadNumber != null && roadNumber.isNotEmpty) roadNumber,
      if (streetName != null && streetName.isNotEmpty) streetName,
    ];
    return parts.isEmpty ? '--' : parts.join(' / ');
  }

  String? _defaultLocalizedText(Object? value) {
    final Map<String, dynamic>? map = _asMap(value);
    final Object? defaultValue = map?['default'];
    final String text = defaultValue?.toString().trim() ?? '';
    return text.isEmpty ? null : text;
  }

  String _formatMeters(Object? value) {
    final double? meters = _asDouble(value);
    if (meters == null) {
      return '--';
    }
    if (meters.abs() >= 1000) {
      return '${(meters / 1000).toStringAsFixed(2)} km';
    }
    return '${meters.toStringAsFixed(1)} m';
  }

  String _formatSpeedLimit(Map<String, dynamic>? speedLimit) {
    if (speedLimit == null) {
      return '--';
    }
    if (speedLimit['speedLimitIsUnlimited'] == true) {
      return 'Unlimited';
    }
    return _formatSpeedMps(speedLimit['speedLimitMps']);
  }

  String _formatSpeedMps(Object? value) {
    final double? speedMps = _asDouble(value);
    if (speedMps == null) {
      return '--';
    }
    return '${(speedMps * 3.6).round()} km/h';
  }

  String _formatDurationMs(Object? value) {
    final double? milliseconds = _asDouble(value);
    if (milliseconds == null) {
      return '--';
    }
    if (milliseconds >= 60000) {
      return '${(milliseconds / 60000).toStringAsFixed(1)} min ago';
    }
    return '${(milliseconds / 1000).toStringAsFixed(1)} s ago';
  }

  double? _asDouble(Object? value) {
    if (value is double && value.isFinite) {
      return value;
    }
    if (value is int) {
      return value.toDouble();
    }
    if (value is num && value.isFinite) {
      return value.toDouble();
    }
    return null;
  }

  void _startLiveTrackerLocationUpdates() {
    _liveTrackerLocationSubscription?.cancel();
    _liveTrackerLocationSubscription = _positioningEngine
        .getLiveTrackerLocationUpdates
        .listen(_forwardLiveTrackerLocation);
  }

  void _forwardLiveTrackerLocation(LiveTrackerLocationUpdate update) {
    if (_mapInitSuccess) {
      _updateMatchedLocationMarker(update);
      if (update.matchedLocation == null) {
        _clearMatchedSegmentPolyline();
      }
    }
    Provider.of<LiveTrackerService>(
      context,
      listen: false,
    ).sendLocationUpdate(update);
  }

  Widget _buildDrawer(BuildContext context) {
    ColorScheme colorScheme = Theme.of(context).colorScheme;
    AppLocalizations appLocalizations = AppLocalizations.of(context)!;

    return Drawer(
      child: Ink(
        color: colorScheme.primary,
        child: ListView(
          padding: EdgeInsets.zero,
          children: [
            Container(
              child: DrawerHeader(
                padding: EdgeInsets.all(UIStyle.contentMarginLarge),
                decoration: BoxDecoration(color: colorScheme.onSecondary),
                child: Row(
                  children: [
                    Image.asset(
                      "assets/ocm_live_tracker_icon.png",
                      width: UIStyle.drawerLogoSize,
                      height: UIStyle.drawerLogoSize,
                    ),
                    SizedBox(width: UIStyle.contentMarginMedium),
                    FutureBuilder<PackageInfo>(
                      future: PackageInfo.fromPlatform(),
                      builder: (_, snapshot) {
                        switch (snapshot.connectionState) {
                          case ConnectionState.done:
                            String title = Util.formatString(
                              appLocalizations.appTitleHeader,
                              [
                                snapshot.data?.version ?? '',
                                SDKBuildInformation.sdkVersion()
                                    .versionGeneration,
                                SDKBuildInformation.sdkVersion().versionMajor,
                                SDKBuildInformation.sdkVersion().versionMinor,
                              ],
                            );
                            return Expanded(
                              child: Text(
                                title,
                                style: TextStyle(color: colorScheme.onPrimary),
                              ),
                            );
                          default:
                            return const SizedBox();
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            ListTile(
              leading: HdsIconWidget(
                HdsAssetsPaths.inboxAttentionIcon,
                color: colorScheme.onPrimary,
              ),
              title: Text(
                appLocalizations.privacyNotice,
                style: TextStyle(color: colorScheme.onPrimary),
              ),
              trailing: HdsIconWidget(
                HdsAssetsPaths.chevronRightIcon,
                color: colorScheme.onPrimary,
              ),
              onTap: () {
                Navigator.of(context)
                  ..pop()
                  ..pushNamed(HerePrivacyNoticeScreen.navRoute);
              },
            ),
            Consumer<LiveTrackerService>(
              builder: (context, tracker, _) {
                return ListTile(
                  leading: Icon(Icons.sensors, color: colorScheme.onPrimary),
                  title: Text(
                    liveTrackingFeatureName,
                    style: TextStyle(color: colorScheme.onPrimary),
                  ),
                  subtitle: Text(
                    tracker.enabled ? tracker.statusText : 'Off',
                    style: TextStyle(
                      color: colorScheme.onPrimary.withValues(alpha: 0.7),
                    ),
                  ),
                  trailing: HdsIconWidget(
                    HdsAssetsPaths.chevronRightIcon,
                    color: colorScheme.onPrimary,
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        showLiveTrackerSettingsDialog(this.context);
                      }
                    });
                  },
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFAB(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!enableMapUpdate)
              ResetLocationButton(onPressed: _resetCurrentPosition),
            Container(height: UIStyle.contentMarginMedium),
            FloatingActionButton(
              child: SizedBox(
                width: UIStyle.bigButtonHeight,
                height: UIStyle.bigButtonHeight,
                child: ClipOval(
                  child: Ink(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          UIStyle.buttonPrimaryColor,
                          UIStyle.buttonSecondaryColor,
                        ],
                      ),
                    ),
                    child: Center(child: HdsIconWidget(HdsAssetsPaths.search)),
                  ),
                ),
              ),
              onPressed: () => _onSearch(context),
            ),
          ],
        ),
      ],
    );
  }

  void _addGestureListeners() {
    _lockCameraNorthUp();

    _hereMapController.gestures.panListener = PanListener((
      state,
      origin,
      translation,
      velocity,
    ) {
      if (enableMapUpdate) {
        setState(() => enableMapUpdate = false);
      }
    });

    _hereMapController.gestures.tapListener = TapListener((point) {
      if (_hereMapController.widgetPins.isEmpty) {
        _removeRouteFromMarker();
      }
      _dismissWayPointPopup();
    });

    _hereMapController.gestures.longPressListener = LongPressListener((
      state,
      point,
    ) {
      if (state == GestureState.begin) {
        _showWayPointPopup(point);
      }
    });

    _hereMapController.gestures.pinchRotateListener = PinchRotateListener((
      state,
      pinchOrigin,
      rotationOrigin,
      twoFingerDistance,
      rotation,
    ) {
      _forceNorthUp();
    });
  }

  void _lockCameraNorthUp() {
    _hereMapController.camera.limits.bearingRange = AngleRange(0, 0);
    _hereMapController.camera.limits.tiltRange = AngleRange(0, 0);
    _hereMapController.gestures.disableDefaultAction(GestureType.twoFingerPan);
    _forceNorthUp();
  }

  void _forceNorthUp() {
    final MapCameraState cameraState = _hereMapController.camera.state;
    _hereMapController.camera.lookAtPointWithGeoOrientationAndMeasure(
      cameraState.targetCoordinates,
      GeoOrientationUpdate(0, 0),
      MapMeasure(
        MapMeasureKind.distanceInMeters,
        cameraState.distanceToTargetInMeters,
      ),
    );
  }

  void _syncLiveTrackerMapOverlays() {
    if (!_mapInitSuccess) {
      return;
    }

    final LiveTrackerService? tracker = _liveTrackerService;
    final LiveTrackerLocationUpdate? update = tracker?.latestLocationUpdate;
    if (tracker == null || update == null) {
      _removeMatchedLocationMarker();
      _clearMatchedSegmentPolyline();
      return;
    }

    _updateMatchedLocationMarker(update);
    if (update.matchedLocation == null) {
      _clearMatchedSegmentPolyline();
      return;
    }

    _updateMatchedSegmentPolyline(tracker.latestSegmentEvidence);
  }

  void _updateMatchedLocationMarker(LiveTrackerLocationUpdate update) {
    final GeoCoordinates? matchedCoordinates =
        update.matchedLocation?.coordinates;
    if (matchedCoordinates == null) {
      _removeMatchedLocationMarker();
      return;
    }

    if (_matchedLocationMarker == null) {
      final int markerSize =
          (_hereMapController.pixelScale * UIStyle.searchMarkerSize).round();
      _matchedLocationMarker = Util.createMarkerWithImagePath(
        matchedCoordinates,
        'assets/map_marker.svg',
        markerSize,
        markerSize,
        drawOrder: UIStyle.waypointsMarkerDrawOrder + 1,
        anchor: Anchor2D.withHorizontalAndVertical(0.5, 1),
      );
      _hereMapController.mapScene.addMapMarker(_matchedLocationMarker!);
      return;
    }

    _matchedLocationMarker!.coordinates = matchedCoordinates;
  }

  void _removeMatchedLocationMarker() {
    if (_matchedLocationMarker == null) {
      return;
    }
    _hereMapController.mapScene.removeMapMarker(_matchedLocationMarker!);
    _matchedLocationMarker = null;
  }

  void _updateMatchedSegmentPolyline(Map<String, dynamic>? evidence) {
    final _LiveSegmentGeometry? geometry = _liveSegmentGeometry(evidence);
    if (geometry == null) {
      _clearMatchedSegmentPolyline();
      return;
    }

    final String polylineKey = _liveSegmentPolylineKey(
      evidence,
      geometry.vertices,
    );
    if (_matchedSegmentPolylines.isNotEmpty &&
        _matchedSegmentPolylineKey == polylineKey) {
      return;
    }

    _clearMatchedSegmentPolyline();
    final GeoPolyline geoPolyline = GeoPolyline(geometry.vertices);
    _addMatchedSegmentPolyline(
      geoPolyline,
      _matchedSegmentGlowRepresentation(),
      98,
    );
    _addMatchedSegmentPolyline(
      geoPolyline,
      _matchedSegmentOuterRepresentation(),
      99,
    );
    _addMatchedSegmentPolyline(
      geoPolyline,
      _matchedSegmentMainRepresentation(),
      100,
    );
    _addMatchedSegmentNodeMarkers(geometry);
    _addMatchedSegmentDirectionMarkers(geometry);
    _matchedSegmentPolylineKey = polylineKey;
  }

  void _clearMatchedSegmentPolyline() {
    if (_matchedSegmentPolylines.isEmpty &&
        _matchedSegmentStartMarker == null &&
        _matchedSegmentEndMarker == null &&
        _matchedSegmentDirectionMarkers.isEmpty) {
      _matchedSegmentPolylineKey = null;
      return;
    }
    for (final MapPolyline polyline in _matchedSegmentPolylines) {
      _hereMapController.mapScene.removeMapPolyline(polyline);
    }
    _matchedSegmentPolylines.clear();
    if (_matchedSegmentStartMarker != null) {
      _hereMapController.mapScene.removeMapMarker(_matchedSegmentStartMarker!);
      _matchedSegmentStartMarker = null;
    }
    if (_matchedSegmentEndMarker != null) {
      _hereMapController.mapScene.removeMapMarker(_matchedSegmentEndMarker!);
      _matchedSegmentEndMarker = null;
    }
    for (final MapMarker marker in _matchedSegmentDirectionMarkers) {
      _hereMapController.mapScene.removeMapMarker(marker);
    }
    _matchedSegmentDirectionMarkers.clear();
    _matchedSegmentPolylineKey = null;
  }

  void _addMatchedSegmentPolyline(
    GeoPolyline geoPolyline,
    MapPolylineRepresentation representation,
    int drawOrder,
  ) {
    final MapPolyline polyline = MapPolyline.withRepresentation(
      geoPolyline,
      representation,
    );
    polyline.drawOrder = drawOrder;
    _hereMapController.mapScene.addMapPolyline(polyline);
    _matchedSegmentPolylines.add(polyline);
  }

  _LiveSegmentGeometry? _liveSegmentGeometry(Map<String, dynamic>? evidence) {
    final Map<String, dynamic>? directedSegmentData = _asMap(
      evidence?['segmentData'],
    );
    final Map<String, dynamic>? undirectedSegmentData = _asMap(
      evidence?['undirectedSegmentData'],
    );
    final Map<String, dynamic>? segmentData =
        directedSegmentData ?? undirectedSegmentData;
    final bool isDirectedGeometry = directedSegmentData != null;
    final String travelDirection = _liveSegmentTravelDirection(
      evidence,
      segmentData,
    );
    final List<GeoCoordinates>? vertices = _liveSegmentPolylineVertices(
      segmentData,
    );
    if (vertices == null) {
      return null;
    }

    final bool shouldReverseUndirected =
        !isDirectedGeometry && travelDirection == 'negative';
    return _LiveSegmentGeometry(
      vertices: shouldReverseUndirected ? vertices.reversed.toList() : vertices,
      travelDirection: travelDirection,
    );
  }

  List<GeoCoordinates>? _liveSegmentPolylineVertices(
    Map<String, dynamic>? segmentData,
  ) {
    final Map<String, dynamic>? polyline = _asMap(segmentData?['polyline']);
    final Object? rawVertices = polyline?['vertices'];
    if (rawVertices is! List || rawVertices.length < 2) {
      return null;
    }

    final List<GeoCoordinates> vertices = [];
    for (final Object? rawVertex in rawVertices) {
      final Map<String, dynamic>? vertex = _asMap(rawVertex);
      final double? lat = _asDouble(vertex?['lat']);
      final double? lon = _asDouble(vertex?['lon']);
      if (lat == null || lon == null) {
        continue;
      }
      vertices.add(GeoCoordinates(lat, lon));
    }

    return vertices.length >= 2 ? vertices : null;
  }

  String _liveSegmentTravelDirection(
    Map<String, dynamic>? evidence,
    Map<String, dynamic>? segmentData,
  ) {
    final Map<String, dynamic>? selected = _asMap(evidence?['selected']);
    final Map<String, dynamic>? matched = _asMap(evidence?['matched']);
    final Map<String, dynamic>? matchedSegmentReference = _asMap(
      matched?['segmentReference'],
    );
    final Map<String, dynamic>? segmentReference = _asMap(
      segmentData?['segmentReference'],
    );
    final Object? rawTravelDirection =
        selected?['travelDirection'] ??
        matchedSegmentReference?['travelDirection'] ??
        segmentReference?['travelDirection'];
    return rawTravelDirection?.toString() ?? 'unknown';
  }

  MapPolylineRepresentation _matchedSegmentGlowRepresentation() {
    return MapPolylineSolidRepresentation(
      MapMeasureDependentRenderSize.withSingleSize(RenderSizeUnit.pixels, 22),
      const Color(0x3300CFC7),
      LineCap.round,
    );
  }

  MapPolylineRepresentation _matchedSegmentOuterRepresentation() {
    return MapPolylineSolidRepresentation.withOutline(
      MapMeasureDependentRenderSize.withSingleSize(RenderSizeUnit.pixels, 12),
      const Color(0xFFF9FFFE),
      MapMeasureDependentRenderSize.withSingleSize(RenderSizeUnit.pixels, 2),
      const Color(0xFF004C4A),
      LineCap.round,
    );
  }

  MapPolylineRepresentation _matchedSegmentMainRepresentation() {
    return MapPolylineSolidRepresentation.withOutline(
      MapMeasureDependentRenderSize.withSingleSize(RenderSizeUnit.pixels, 8),
      const Color(0xFF00AFAA),
      MapMeasureDependentRenderSize.withSingleSize(RenderSizeUnit.pixels, 1),
      const Color(0xFFFFFFFF),
      LineCap.round,
    );
  }

  void _addMatchedSegmentNodeMarkers(_LiveSegmentGeometry geometry) {
    final int markerSize = (_hereMapController.pixelScale * 24).round().clamp(
      24,
      96,
    );
    _matchedSegmentStartMarker = _createSvgMapMarker(
      geometry.vertices.first,
      _segmentNodeSvg(label: 'S', fill: '#00AFAA'),
      markerSize,
      drawOrder: 121,
    );
    _matchedSegmentEndMarker = _createSvgMapMarker(
      geometry.vertices.last,
      _segmentNodeSvg(label: 'E', fill: '#2F80ED'),
      markerSize,
      drawOrder: 121,
    );
    _hereMapController.mapScene.addMapMarker(_matchedSegmentStartMarker!);
    _hereMapController.mapScene.addMapMarker(_matchedSegmentEndMarker!);
  }

  void _addMatchedSegmentDirectionMarkers(_LiveSegmentGeometry geometry) {
    final double lengthMeters = _polylineLengthMeters(geometry.vertices);
    if (lengthMeters <= 0) {
      return;
    }

    final List<double> ratios = lengthMeters >= 70 ? [0.35, 0.65] : [0.5];
    final int markerSize = (_hereMapController.pixelScale * 26).round().clamp(
      26,
      104,
    );
    for (final double ratio in ratios) {
      final _SegmentDirectionSample? sample = _directionSampleAtRatio(
        geometry.vertices,
        ratio,
      );
      if (sample == null) {
        continue;
      }
      final MapMarker marker = _createSvgMapMarker(
        sample.coordinates,
        _segmentDirectionSvg(sample.bearingDegrees),
        markerSize,
        drawOrder: 122,
      );
      _hereMapController.mapScene.addMapMarker(marker);
      _matchedSegmentDirectionMarkers.add(marker);
    }
  }

  MapMarker _createSvgMapMarker(
    GeoCoordinates coordinates,
    String svg,
    int size, {
    required int drawOrder,
  }) {
    final MapImage image = MapImage.withImageDataImageFormatWidthAndHeight(
      Uint8List.fromList(svg.codeUnits),
      ImageFormat.svg,
      size,
      size,
    );
    final MapMarker marker = Util.createMarkerWithImage(
      coordinates,
      image,
      drawOrder: drawOrder,
      anchor: Anchor2D.withHorizontalAndVertical(0.5, 0.5),
    );
    marker.isOverlapAllowed = true;
    return marker;
  }

  String _segmentNodeSvg({required String label, required String fill}) {
    return '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 44 44">
  <circle cx="22" cy="22" r="20" fill="#003B3A" fill-opacity="0.28"/>
  <circle cx="22" cy="22" r="17" fill="#FFFFFF"/>
  <circle cx="22" cy="22" r="12" fill="$fill"/>
  <text x="22" y="26.5" text-anchor="middle" font-size="13" font-family="Arial, Helvetica, sans-serif" font-weight="700" fill="#FFFFFF">$label</text>
</svg>
''';
  }

  String _segmentDirectionSvg(double bearingDegrees) {
    final String bearing = bearingDegrees.toStringAsFixed(1);
    return '''
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 48 48">
  <circle cx="24" cy="24" r="21" fill="#003B3A" fill-opacity="0.20"/>
  <circle cx="24" cy="24" r="17" fill="#FFFFFF" fill-opacity="0.96"/>
  <g transform="rotate($bearing 24 24)">
    <path d="M24 7 L37 36 L24 29 L11 36 Z" fill="#00AFAA" stroke="#003B3A" stroke-width="2.2" stroke-linejoin="round"/>
    <path d="M24 12 L32 31 L24 26.5 L16 31 Z" fill="#54F0E5"/>
  </g>
</svg>
''';
  }

  double _polylineLengthMeters(List<GeoCoordinates> vertices) {
    double length = 0;
    for (int index = 0; index < vertices.length - 1; index++) {
      length += vertices[index].distanceTo(vertices[index + 1]);
    }
    return length;
  }

  _SegmentDirectionSample? _directionSampleAtRatio(
    List<GeoCoordinates> vertices,
    double ratio,
  ) {
    if (vertices.length < 2) {
      return null;
    }

    final double targetDistance = _polylineLengthMeters(vertices) * ratio;
    double traversed = 0;
    for (int index = 0; index < vertices.length - 1; index++) {
      final GeoCoordinates start = vertices[index];
      final GeoCoordinates end = vertices[index + 1];
      final double segmentLength = start.distanceTo(end);
      if (segmentLength <= 0) {
        continue;
      }
      if (traversed + segmentLength >= targetDistance ||
          index == vertices.length - 2) {
        final double segmentRatio =
            ((targetDistance - traversed) / segmentLength).clamp(0.0, 1.0);
        return _SegmentDirectionSample(
          coordinates: start.interpolate(end, segmentRatio),
          bearingDegrees: _bearingDegrees(start, end),
        );
      }
      traversed += segmentLength;
    }
    return null;
  }

  double _bearingDegrees(GeoCoordinates from, GeoCoordinates to) {
    final double lat1 = _degreesToRadians(from.latitude);
    final double lat2 = _degreesToRadians(to.latitude);
    final double deltaLon = _degreesToRadians(to.longitude - from.longitude);
    final double y = math.sin(deltaLon) * math.cos(lat2);
    final double x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(deltaLon);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  double _degreesToRadians(double degrees) => degrees * math.pi / 180;

  String _liveSegmentPolylineKey(
    Map<String, dynamic>? evidence,
    List<GeoCoordinates> vertices,
  ) {
    final Map<String, dynamic>? selected = _asMap(evidence?['selected']);
    final Map<String, dynamic>? selectedId = _asMap(selected?['id']);
    return [
      selectedId?['tilePartitionId'] ?? '',
      selectedId?['localId'] ?? '',
      selected?['travelDirection'] ?? '',
      vertices.length,
      _formatPolylineKeyCoordinate(vertices.first),
      _formatPolylineKeyCoordinate(vertices.last),
    ].join('|');
  }

  String _formatPolylineKeyCoordinate(GeoCoordinates coordinates) {
    return '${coordinates.latitude.toStringAsFixed(7)},'
        '${coordinates.longitude.toStringAsFixed(7)}';
  }

  void _dismissWayPointPopup() {
    if (_hereMapController.widgetPins.isNotEmpty) {
      _hereMapController.widgetPins.first.unpin();
    }
  }

  void _showWayPointPopup(Point2D point) {
    _dismissWayPointPopup();
    GeoCoordinates coordinates =
        _hereMapController.viewToGeoCoordinates(point) ??
        _hereMapController.camera.state.targetCoordinates;

    _hereMapController.pinWidget(
      PlaceActionsPopup(
        coordinates: coordinates,
        hereMapController: _hereMapController,
        onLeftButtonPressed: (place) {
          _dismissWayPointPopup();
          _routeFromPlace = place;
          _addRouteFromPoint(coordinates);
        },
        leftButtonIcon: HdsIconWidget.medium(
          "assets/depart_marker.svg",
          color: UIStyle.addWayPointPopupForegroundColor,
        ),
        onRightButtonPressed: (place) {
          _dismissWayPointPopup();
          _showRoutingScreen(
            place != null
                ? WayPointInfo.withPlace(
                    place: place,
                    originalCoordinates: coordinates,
                  )
                : WayPointInfo.withCoordinates(coordinates: coordinates),
          );
        },
        rightButtonIcon: HdsIconWidget.medium(
          HdsAssetsPaths.path,
          color: UIStyle.addWayPointPopupForegroundColor,
        ),
      ),
      coordinates,
      anchor: Anchor2D.withHorizontalAndVertical(0.5, 1),
    );
  }

  void _addRouteFromPoint(GeoCoordinates coordinates) {
    if (_routeFromMarker == null) {
      int markerSize =
          (_hereMapController.pixelScale * UIStyle.searchMarkerSize).round();
      _routeFromMarker = Util.createMarkerWithImagePath(
        coordinates,
        "assets/depart_marker.svg",
        markerSize,
        markerSize,
        drawOrder: UIStyle.waypointsMarkerDrawOrder,
        anchor: Anchor2D.withHorizontalAndVertical(0.5, 1),
      );
      _hereMapController.mapScene.addMapMarker(_routeFromMarker!);
      if (!isLocationEngineStarted) {
        locationVisible = false;
      }
    } else {
      _routeFromMarker!.coordinates = coordinates;
    }
  }

  void _removeRouteFromMarker() {
    if (_routeFromMarker != null) {
      _hereMapController.mapScene.removeMapMarker(_routeFromMarker!);
      _routeFromMarker = null;
      _routeFromPlace = null;
      locationVisible = true;
    }
  }

  void _resetCurrentPosition() {
    GeoCoordinates coordinates = lastKnownLocation != null
        ? lastKnownLocation!.coordinates
        : Positioning.initPosition;
    _hereMapController.camera.lookAtPointWithGeoOrientationAndMeasure(
      coordinates,
      GeoOrientationUpdate(0, 0),
      MapMeasure(
        MapMeasureKind.distanceInMeters,
        Positioning.initDistanceToEarth,
      ),
    );

    setState(() => enableMapUpdate = true);
  }

  void _dismissLocationWarningPopup() {
    _locationWarningOverlay?.remove();
    _locationWarningOverlay = null;
  }

  void _checkLocationStatus(LocationEngineStatus status) {
    if (status == LocationEngineStatus.engineStarted ||
        status == LocationEngineStatus.alreadyStarted) {
      _dismissLocationWarningPopup();
      return;
    }
    // If we manually stopped the [_positioning], then no need to show the
    // warning dialog.
    if (status == LocationEngineStatus.engineStopped &&
        _didBackPressedAndPositionStopped) {
      _dismissLocationWarningPopup();
      return;
    }

    if (_locationWarningOverlay == null) {
      _locationWarningOverlay = OverlayEntry(
        builder: (context) =>
            NoLocationWarning(onPressed: () => _dismissLocationWarningPopup()),
      );

      Overlay.of(context).insert(_locationWarningOverlay!);
      Timer(
        Duration(seconds: _kLocationWarningDismissPeriod),
        _dismissLocationWarningPopup,
      );
    }
  }

  void _onSearch(BuildContext context) async {
    GeoCoordinates currentPosition =
        _hereMapController.camera.state.targetCoordinates;

    final SearchResult? result = await showSearchPopup(
      context: context,
      currentPosition: currentPosition,
      hereMapController: _hereMapController,
      hereMapKey: _hereMapWidgetKey,
    );
    if (result != null) {
      SearchResult searchResult = result;
      assert(searchResult.place != null);
      _showRoutingScreen(WayPointInfo.withPlace(place: searchResult.place));
    }
  }

  void _showRoutingScreen(WayPointInfo destination) async {
    final GeoCoordinates currentPosition = lastKnownLocation != null
        ? lastKnownLocation!.coordinates
        : Positioning.initPosition;

    // Restart if coming back from navigation screen (no value returned).
    final bool shouldRestartLocationEngine =
        await Navigator.of(context).pushNamed(
              RoutingScreen.navRoute,
              arguments: [
                currentPosition,
                _routeFromMarker != null
                    ? _routeFromPlace != null
                          ? WayPointInfo.withPlace(
                              place: _routeFromPlace,
                              originalCoordinates:
                                  _routeFromMarker!.coordinates,
                            )
                          : WayPointInfo.withCoordinates(
                              coordinates: _routeFromMarker!.coordinates,
                            )
                    : WayPointInfo(coordinates: currentPosition),
                destination,
              ],
            )
            as bool? ??
        true;

    _routeFromPlace = null;
    _removeRouteFromMarker();
    if (shouldRestartLocationEngine) {
      _positioningEngine.restartLocationEngine();
    }
  }
}

class _LiveSegmentDetailRow {
  const _LiveSegmentDetailRow({
    required this.label,
    required this.value,
    required this.depth,
    this.isGroup = false,
  });

  final String label;
  final String value;
  final int depth;
  final bool isGroup;
}

class _LiveSegmentCsvRow {
  const _LiveSegmentCsvRow({
    required this.path,
    required this.label,
    required this.value,
    required this.type,
    required this.depth,
  });

  final String path;
  final String label;
  final String value;
  final String type;
  final int depth;
}

class _LiveSegmentGeometry {
  const _LiveSegmentGeometry({
    required this.vertices,
    required this.travelDirection,
  });

  final List<GeoCoordinates> vertices;
  final String travelDirection;
}

class _SegmentDirectionSample {
  const _SegmentDirectionSample({
    required this.coordinates,
    required this.bearingDegrees,
  });

  final GeoCoordinates coordinates;
  final double bearingDegrees;
}

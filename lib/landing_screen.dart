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
import 'common/ui_style.dart';
import 'common/util.dart' as Util;
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
  bool _didBackPressedAndPositionStopped = false;
  late HereMapController _hereMapController;
  late PositioningEngine _positioningEngine;
  LiveTrackerService? _liveTrackerService;
  final AndroidNotificationsManager _liveTrackerAndroidNotifications =
      AndroidNotificationsManager();
  bool _liveTrackerForegroundServiceRequested = false;
  bool _liveTrackerForegroundServiceActive = false;
  GlobalKey _hereMapWidgetKey = GlobalKey();
  OverlayEntry? _locationWarningOverlay;
  MapMarker? _routeFromMarker;
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
    final LiveTrackerService tracker = Provider.of<LiveTrackerService>(
      context,
      listen: false,
    );
    if (!identical(_liveTrackerService, tracker)) {
      _liveTrackerService?.removeListener(_syncLiveTrackerBackgroundNavigation);
      _liveTrackerService = tracker;
      _liveTrackerService!.addListener(_syncLiveTrackerBackgroundNavigation);
      _syncLiveTrackerBackgroundNavigation();
    }
  }

  @override
  void dispose() {
    _liveTrackerService?.removeListener(_syncLiveTrackerBackgroundNavigation);
    unawaited(_syncLiveTrackerForegroundService(false));
    stopPositioning();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _syncLiveTrackerBackgroundNavigation() {
    final bool enabled = _liveTrackerService?.enabled ?? false;
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
          onLocationUpdated: _forwardLiveTrackerLocation,
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

    debugPrint('[$companionAppName] Loading HERE map scene: normalDay.');
    hereMapController.mapScene.loadSceneForMapScheme(MapScheme.normalDay, (
      MapError? error,
    ) {
      if (error != null) {
        debugPrint(
          '[$companionAppName] Map scene not loaded. MapError: $error',
        );
        return;
      }
      debugPrint('[$companionAppName] Map scene loaded.');

      hereMapController.camera.lookAtPointWithMeasure(
        Positioning.initPosition,
        MapMeasure(
          MapMeasureKind.distanceInMeters,
          Positioning.initDistanceToEarth,
        ),
      );

      hereMapController.setWatermarkLocation(
        Anchor2D.withHorizontalAndVertical(0, 1),
        Point2D(
          -hereMapController.watermarkSize.width / 2,
          -hereMapController.watermarkSize.height / 2,
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
          hereMapController: hereMapController,
          onLocationUpdated: _forwardLiveTrackerLocation,
        );
      });

      setState(() {
        _mapInitSuccess = true;
      });
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

  void _forwardLiveTrackerLocation(Location location) {
    Provider.of<LiveTrackerService>(
      context,
      listen: false,
    ).sendRawLocation(location);
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
      GeoOrientationUpdate(double.nan, double.nan),
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

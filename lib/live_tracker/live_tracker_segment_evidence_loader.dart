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

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:here_sdk/core.dart';
import 'package:here_sdk/mapdata.dart' as MapData;
import 'package:here_sdk/navigation.dart' as Navigation;
import 'package:here_sdk/routing.dart' as Routing;
import 'package:here_sdk/transport.dart' as Transport;

class LiveTrackerSegmentEvidenceLoader {
  LiveTrackerSegmentEvidenceLoader({this.searchRadiusInMeters = 1.0});

  final double searchRadiusInMeters;
  final Map<String, Map<String, dynamic>> _cache = {};
  MapData.SegmentDataLoader? _segmentDataLoader;

  Map<String, dynamic>? evidenceFor(
    Navigation.MapMatchedLocation? matchedLocation,
  ) {
    if (matchedLocation == null) {
      return null;
    }

    final String cacheKey = _segmentReferenceKey(
      matchedLocation.segmentReference,
    );
    final bool isNewSegment = !_cache.containsKey(cacheKey);
    final Map<String, dynamic> baseEvidence = _cache[cacheKey] ??=
        _loadEvidence(matchedLocation);
    final Map<String, dynamic> evidence = _decorateEvidenceForMatchedLocation(
      baseEvidence,
      matchedLocation,
    );
    if (isNewSegment) {
      _logStructuredEvidence(evidence);
    }
    return evidence;
  }

  MapData.SegmentDataLoader get _loader =>
      _segmentDataLoader ??= MapData.SegmentDataLoader();

  Map<String, dynamic> _loadEvidence(
    Navigation.MapMatchedLocation matchedLocation,
  ) {
    try {
      final List<MapData.OCMSegmentId> candidates = _loader
          .getSegmentsAroundCoordinates(
            matchedLocation.coordinates,
            searchRadiusInMeters,
          );
      if (candidates.isEmpty) {
        return {
          'status': 'noSegments',
          'searchRadiusM': searchRadiusInMeters,
          'candidateCount': 0,
          'candidates': <Map<String, dynamic>>[],
        };
      }

      final MapData.OCMSegmentId selected = _selectCandidate(
        candidates,
        matchedLocation.segmentReference,
      );
      final MapData.DirectedOCMSegmentId directed =
          MapData.DirectedOCMSegmentId(
            selected,
          )..travelDirection = matchedLocation.segmentReference.travelDirection;
      final _SegmentDataLoadResult directedLoad = _loadDirectedSegmentData(
        directed,
        _directedOptions(),
      );
      final _SegmentDataLoadResult supplementalLoad = _loadSegmentData(
        selected,
        _undirectedSupplementalOptions(),
      );
      if (directedLoad.segmentData == null &&
          supplementalLoad.segmentData == null) {
        return {
          'status': 'error',
          'searchRadiusM': searchRadiusInMeters,
          'matched': _mapMatchedLocationToJson(matchedLocation),
          'candidateCount': candidates.length,
          'candidates': candidates.map(_ocmSegmentIdToJson).toList(),
          'selected': _directedSegmentIdToJson(directed),
          'selection':
              _candidateMatchesReference(
                selected,
                matchedLocation.segmentReference,
              )
              ? 'matchedSegmentReference'
              : 'nearestByCoordinates',
          'loadDiagnostics': {
            'directed': directedLoad.toJson(),
            'undirectedSupplemental': supplementalLoad.toJson(),
          },
        };
      }
      return {
        'status':
            directedLoad.segmentData != null &&
                supplementalLoad.segmentData != null
            ? 'loaded'
            : 'partial',
        'searchRadiusM': searchRadiusInMeters,
        'matched': _mapMatchedLocationToJson(matchedLocation),
        'candidateCount': candidates.length,
        'candidates': candidates.map(_ocmSegmentIdToJson).toList(),
        'selected': _directedSegmentIdToJson(directed),
        'selection':
            _candidateMatchesReference(
              selected,
              matchedLocation.segmentReference,
            )
            ? 'matchedSegmentReference'
            : 'nearestByCoordinates',
        'loadDiagnostics': {
          'directed': directedLoad.toJson(),
          'undirectedSupplemental': supplementalLoad.toJson(),
        },
        if (directedLoad.segmentData != null)
          'segmentData': _segmentDataToJson(directedLoad.segmentData!),
        if (supplementalLoad.segmentData != null)
          'undirectedSegmentData': _segmentDataToJson(
            supplementalLoad.segmentData!,
          ),
      };
    } catch (error, stackTrace) {
      return {
        'status': 'error',
        'searchRadiusM': searchRadiusInMeters,
        'exception': _exceptionToJson(error, stackTrace),
      };
    }
  }

  Map<String, dynamic> _decorateEvidenceForMatchedLocation(
    Map<String, dynamic> baseEvidence,
    Navigation.MapMatchedLocation matchedLocation,
  ) {
    final Map<String, dynamic> evidence = Map<String, dynamic>.of(baseEvidence);
    evidence['matched'] = _mapMatchedLocationToJson(matchedLocation);

    final Object? segmentData = evidence['segmentData'];
    if (segmentData is Map<String, dynamic>) {
      final Map<String, dynamic>? matchedSpan = _matchedSpanToJson(
        segmentData,
        matchedLocation,
      );
      if (matchedSpan != null) {
        evidence['matchedSpanIndex'] = matchedSpan['index'];
        evidence['matchedSpan'] = matchedSpan;
      }
    }
    final Object? undirectedSegmentData = evidence['undirectedSegmentData'];
    if (undirectedSegmentData is Map<String, dynamic>) {
      final Map<String, dynamic>? matchedSpan = _matchedSpanToJson(
        undirectedSegmentData,
        matchedLocation,
      );
      if (matchedSpan != null) {
        evidence['undirectedMatchedSpanIndex'] = matchedSpan['index'];
        evidence['undirectedMatchedSpan'] = matchedSpan;
      }
    }
    return evidence;
  }

  Map<String, dynamic>? _matchedSpanToJson(
    Map<String, dynamic> segmentData,
    Navigation.MapMatchedLocation matchedLocation,
  ) {
    final Object? rawSpans = segmentData['spans'];
    if (rawSpans is! List || rawSpans.isEmpty) {
      return null;
    }

    final double offsetInMeters =
        matchedLocation.segmentOffsetInCentimeters / 100.0;
    for (int index = 0; index < rawSpans.length; index++) {
      final Object? rawSpan = rawSpans[index];
      if (rawSpan is! Map) {
        continue;
      }
      final double? startOffset = _numberToDouble(
        rawSpan['startOffsetInMeters'],
      );
      final double? spanLength = _numberToDouble(rawSpan['spanLengthInMeters']);
      if (startOffset == null || spanLength == null) {
        continue;
      }
      final double endOffset = startOffset + spanLength;
      final bool isLastSpan = index == rawSpans.length - 1;
      if (offsetInMeters >= startOffset &&
          (offsetInMeters < endOffset ||
              (isLastSpan && offsetInMeters <= endOffset))) {
        return {
          'index': index,
          'matchedSegmentOffsetM': _finiteDouble(offsetInMeters),
          'spanStartOffsetM': _finiteDouble(startOffset),
          'spanEndOffsetM': _finiteDouble(endOffset),
          'span': Map<String, dynamic>.from(rawSpan),
        }..removeWhere((_, Object? value) => value == null);
      }
    }
    return {
      'index': null,
      'matchedSegmentOffsetM': _finiteDouble(offsetInMeters),
      'span': null,
    }..removeWhere((_, Object? value) => value == null);
  }

  _SegmentDataLoadResult _loadDirectedSegmentData(
    MapData.DirectedOCMSegmentId directed,
    MapData.SegmentDataLoaderOptions options,
  ) {
    try {
      return _SegmentDataLoadResult.loaded(
        _loader.loadDirectedSegmentData(directed, options),
      );
    } catch (error, stackTrace) {
      return _SegmentDataLoadResult.failed(_exceptionToJson(error, stackTrace));
    }
  }

  _SegmentDataLoadResult _loadSegmentData(
    MapData.OCMSegmentId segment,
    MapData.SegmentDataLoaderOptions options,
  ) {
    try {
      return _SegmentDataLoadResult.loaded(_loader.loadData(segment, options));
    } catch (error, stackTrace) {
      return _SegmentDataLoadResult.failed(_exceptionToJson(error, stackTrace));
    }
  }

  MapData.SegmentDataLoaderOptions _directedOptions() =>
      MapData.SegmentDataLoaderOptions()
        ..loadTravelDirection = true
        ..loadFunctionalRoadClass = true
        ..loadTransportModesAccess = true
        ..loadSpeedLimits = true
        ..loadBaseSpeeds = true
        ..loadLocalRoadCharacteristics = true
        ..loadStreetNamesAndRoadNumbers = true
        ..loadRoadAttributes = true
        ..loadAdasAttributes = true
        ..loadTrafficSignals = true
        ..loadRoadSigns = true
        ..loadAdministrativeRules = true
        ..loadRailwayCrossings = true
        ..loadSegmentConnectivities = true
        ..loadTollPoints = true;

  MapData.SegmentDataLoaderOptions _undirectedSupplementalOptions() =>
      MapData.SegmentDataLoaderOptions()
        ..loadLaneBlocks = true
        ..loadUrban = true
        ..loadAdministrativeRules = true
        ..loadSpecialSpeedSituations = true;

  MapData.OCMSegmentId _selectCandidate(
    List<MapData.OCMSegmentId> candidates,
    Routing.SegmentReference segmentReference,
  ) {
    for (final MapData.OCMSegmentId candidate in candidates) {
      if (_candidateMatchesReference(candidate, segmentReference)) {
        return candidate;
      }
    }
    return candidates.first;
  }

  bool _candidateMatchesReference(
    MapData.OCMSegmentId candidate,
    Routing.SegmentReference segmentReference,
  ) {
    return candidate.tilePartitionId == segmentReference.tilePartitionId &&
        candidate.localId == segmentReference.localId;
  }

  void _logStructuredEvidence(Map<String, dynamic> evidence) {
    final String json = const JsonEncoder.withIndent(
      '  ',
    ).convert({'event': 'ocmSegmentData', ...evidence});
    debugPrint('[OCM SegmentData]\n$json');
  }

  Map<String, dynamic> _segmentDataToJson(MapData.SegmentData data) {
    final List<GeoCoordinates> vertices = data.polyline.vertices;
    return {
      'ocmSegmentId': _ocmSegmentIdToJson(data.ocmSegmentId),
      'segmentReference': _segmentReferenceToJson(data.segmentReference),
      'lengthInMeters': data.lengthInMeters,
      'polyline': {
        'vertexCount': vertices.length,
        'vertices': vertices.map(_geoCoordinatesToJson).toList(),
      },
      'spans': data.spans.map(_segmentSpanDataToJson).toList(),
      'laneBlocks': data.laneBlocks?.map(_laneBlockToJson).toList(),
      'adasAttributes': data.adasAttributes
          ?.map(_adasAttributesToJson)
          .toList(),
      'trafficSignals': data.trafficSignals?.map(_trafficSignalToJson).toList(),
      'roadSigns': data.roadSigns?.map(_roadSignToJson).toList(),
      'railwayCrossings': data.railwayCrossings
          ?.map(_railwayCrossingToJson)
          .toList(),
      'segmentConnectivities': _segmentConnectivitiesToJson(
        data.segmentConnectivities,
      ),
      'tollPoints': data.tollPoints?.map(_tollPointToJson).toList(),
    }..removeWhere((_, Object? value) => value == null);
  }

  Map<String, dynamic> _segmentSpanDataToJson(MapData.SegmentSpanData span) {
    return {
      'startOffsetInMeters': span.startOffsetInMeters,
      'spanLengthInMeters': span.spanLengthInMeters,
      'travelDirection': _enumName(span.travelDirection),
      'allowedTransportModes': _allowedTransportModesToJson(
        span.allowedTransportModes,
      ),
      'functionalRoadClass': _enumName(span.functionalRoadClass),
      'positiveDirectionSpeedLimit': _segmentSpeedLimitToJson(
        span.positiveDirectionSpeedLimit,
      ),
      'negativeDirectionSpeedLimit': _segmentSpeedLimitToJson(
        span.negativeDirectionSpeedLimit,
      ),
      'speedLimit': _segmentSpeedLimitToJson(span.speedLimit),
      'positiveDirectionBaseSpeedMps': _finiteDouble(
        span.positiveDirectionBaseSpeedInMetersPerSecond,
      ),
      'negativeDirectionBaseSpeedMps': _finiteDouble(
        span.negativeDirectionBaseSpeedInMetersPerSecond,
      ),
      'baseSpeedMps': _finiteDouble(span.baseSpeedInMetersPerSecond),
      'localRoadCharacteristics': _enumList(span.localRoadCharacteristics),
      'streetNames': _localizedTextsToJson(span.streetNames),
      'roadNumbers': _localizedRoadNumbersToJson(span.roadNumbers),
      'physicalAttributes': _physicalAttributesToJson(span.physicalAttributes),
      'roadUsages': _roadUsagesToJson(span.roadUsages),
      'administrativeRules': _administrativeRulesToJson(
        span.administrativeRules,
      ),
      'isUrban': span.isUrban,
      'specialSpeedSituations': span.specialSpeedSituations
          ?.map(_specialSpeedSituationToJson)
          .toList(),
    }..removeWhere((_, Object? value) => value == null);
  }

  Map<String, dynamic> _mapMatchedLocationToJson(
    Navigation.MapMatchedLocation matched,
  ) {
    return {
      'coordinates': _geoCoordinatesToJson(matched.coordinates),
      'bearingDeg': _finiteDouble(matched.bearingInDegrees),
      'segmentReference': _segmentReferenceToJson(matched.segmentReference),
      'segmentOffsetCm': matched.segmentOffsetInCentimeters,
      'confidence': _finiteDouble(matched.confidence),
      'isDrivingInTheWrongWay': matched.isDrivingInTheWrongWay,
      'horizontalAccuracyM': _finiteDouble(matched.horizontalAccuracyInMeters),
      'speedMps': _finiteDouble(matched.speedInMetersPerSecond),
      'timestamp': matched.timestamp?.toUtc().toIso8601String(),
    }..removeWhere((_, Object? value) => value == null);
  }

  Map<String, dynamic> _segmentReferenceToJson(
    Routing.SegmentReference reference,
  ) {
    return {
      'segmentId': reference.segmentId,
      'travelDirection': _enumName(reference.travelDirection),
      'offsetStart': _finiteDouble(reference.offsetStart),
      'offsetEnd': _finiteDouble(reference.offsetEnd),
      'tilePartitionId': reference.tilePartitionId,
      'localId': reference.localId,
    }..removeWhere((_, Object? value) => value == null);
  }

  String _segmentReferenceKey(Routing.SegmentReference reference) =>
      '${reference.tilePartitionId}:${reference.localId ?? -1}:'
      '${_enumName(reference.travelDirection)}';

  Map<String, dynamic> _ocmSegmentIdToJson(MapData.OCMSegmentId id) => {
    'tilePartitionId': id.tilePartitionId,
    'localId': id.localId,
  };

  Map<String, dynamic> _directedSegmentIdToJson(
    MapData.DirectedOCMSegmentId id,
  ) => {
    'id': _ocmSegmentIdToJson(id.id),
    'travelDirection': _enumName(id.travelDirection),
  };

  Map<String, dynamic> _geoCoordinatesToJson(GeoCoordinates coordinates) => {
    'lat': _finiteDouble(coordinates.latitude),
    'lon': _finiteDouble(coordinates.longitude),
    'altitudeM': _finiteDouble(coordinates.altitude),
  }..removeWhere((_, Object? value) => value == null);

  Map<String, dynamic>? _allowedTransportModesToJson(
    MapData.AllowedTransportModes? value,
  ) {
    if (value == null) {
      return null;
    }
    return {
      'bicycleAllowed': value.bicycleAllowed,
      'busAllowed': value.busAllowed,
      'carAllowed': value.carAllowed,
      'pedestrianAllowed': value.pedestrianAllowed,
      'scooterAllowed': value.scooterAllowed,
      'taxiAllowed': value.taxiAllowed,
      'truckAllowed': value.truckAllowed,
    };
  }

  Map<String, dynamic>? _segmentSpeedLimitToJson(
    MapData.SegmentSpeedLimit? value,
  ) {
    if (value == null) {
      return null;
    }
    return {
      'speedLimitMps': _finiteDouble(value.speedLimitInMeterPerSeconds),
      'speedLimitIsUnlimited': value.speedLimitIsUnlimited,
    }..removeWhere((_, Object? item) => item == null);
  }

  Map<String, dynamic>? _localizedTextsToJson(LocalizedTexts? value) {
    if (value == null) {
      return null;
    }
    return {
      'default': value.getDefaultValue(),
      'items': value.items.map(_localizedTextToJson).toList(),
    }..removeWhere((_, Object? item) => item == null);
  }

  Map<String, dynamic>? _localizedTextToJson(LocalizedText? value) {
    if (value == null) {
      return null;
    }
    return {'text': value.text, 'locale': value.locale?.toString()}
      ..removeWhere((_, Object? item) => item == null);
  }

  Map<String, dynamic>? _localizedRoadNumbersToJson(
    Routing.LocalizedRoadNumbers? value,
  ) {
    if (value == null) {
      return null;
    }
    return {
      'default': value.getDefaultValue(),
      'items': value.items.map(_localizedRoadNumberToJson).toList(),
    }..removeWhere((_, Object? item) => item == null);
  }

  Map<String, dynamic> _localizedRoadNumberToJson(
    Routing.LocalizedRoadNumber value,
  ) {
    return {
      'textWithDirection': value.getTextWithDirection(),
      'localizedNumber': _localizedTextToJson(value.localizedNumber),
      'direction': _enumName(value.direction),
      'routeType': _enumName(value.routeType),
    }..removeWhere((_, Object? item) => item == null);
  }

  Map<String, dynamic>? _physicalAttributesToJson(
    MapData.PhysicalAttributes? value,
  ) {
    if (value == null) {
      return null;
    }
    return {
      'isDirtRoad': value.isDirtRoad,
      'isTunnel': value.isTunnel,
      'isBridge': value.isBridge,
      'isPrivate': value.isPrivate,
      'isRoundabout': value.isRoundabout,
      'isMultiplyDigitized': value.isMultiplyDigitized,
      'divider': _enumName(value.divider),
      'isBoatFerry': value.isBoatFerry,
      'isRailFerry': value.isRailFerry,
    }..removeWhere((_, Object? item) => item == null);
  }

  Map<String, dynamic>? _roadUsagesToJson(MapData.RoadUsages? value) {
    if (value == null) {
      return null;
    }
    return {
      'isRamp': value.isRamp,
      'isControlledAccess': value.isControlledAccess,
      'isTollway': value.isTollway,
      'isPriorityRoad': value.isPriorityRoad,
    };
  }

  Map<String, dynamic>? _administrativeRulesToJson(
    MapData.AdministrativeRules? value,
  ) {
    if (value == null) {
      return null;
    }
    return {
      'countryCode': _enumName(value.countryCode),
      'stateCode': value.stateCode,
      'drivingSide': _enumName(value.drivingSide),
      'unitSystem': _enumName(value.unitSystem),
      'speedLimits': _generalVehicleSpeedLimitsToJson(value.speedLimits),
      'timeZoneOffsetsMinutes': value.timeZoneOffsetsInMinutes
          .map((Duration duration) => duration.inMinutes)
          .toList(),
      'daylightSavingPeriod': _timeRuleToJson(value.daylightSavingPeriod),
      'isUturnRestricted': value.isUturnRestricted,
      'headlightsRequirements': _enumList(value.headlightsRequirements),
      'isTollRequired': value.isTollRequired,
      'isTollStickerRequired': value.isTollStickerRequired,
      'turnOnRedRegulations': _enumList(value.turnOnRedRegulations),
      'parkingSideRegulations': _enumList(value.parkingSideRegulations),
      'isCleanAirStickerRequired': value.isCleanAirStickerRequired,
      'bloodAlcoholContentLimit': _bloodAlcoholContentLimitToJson(
        value.bloodAlcoholContentLimit,
      ),
      'tollSystems': value.tollSystems.map(_tollSystemToJson).toList(),
      'preTripPlanning': _preTripPlanningToJson(value.preTripPlanning),
    }..removeWhere((_, Object? item) => item == null);
  }

  Map<String, dynamic>? _generalVehicleSpeedLimitsToJson(
    Transport.GeneralVehicleSpeedLimits? value,
  ) {
    if (value == null) {
      return null;
    }
    return {
      'maxSpeedHighwaysMps': _finiteDouble(
        value.maxSpeedHighwaysInMetersPerSecond,
      ),
      'maxSpeedRuralMps': _finiteDouble(value.maxSpeedRuralInMetersPerSecond),
      'maxSpeedUrbanMps': _finiteDouble(value.maxSpeedUrbanInMetersPerSecond),
      'maxSpeedRainingMps': _finiteDouble(
        value.maxSpeedRainingInMetersPerSecond,
      ),
      'maxSpeedSnowingMps': _finiteDouble(
        value.maxSpeedSnowingInMetersPerSecond,
      ),
      'maxSpeedNightMps': _finiteDouble(value.maxSpeedNightInMetersPerSecond),
      'minSpeedHighwaysMps': _finiteDouble(
        value.minSpeedHighwaysInMetersPerSecond,
      ),
    }..removeWhere((_, Object? item) => item == null);
  }

  Map<String, dynamic>? _timeRuleToJson(TimeRule? value) {
    if (value == null) {
      return null;
    }
    return {
      'timeRuleString': value.timeRuleString,
      'timeZoneOffsetSeconds': value.timeZoneOffsetSeconds,
      'dstSpec': value.dstSpec,
    };
  }

  Map<String, dynamic>? _preTripPlanningToJson(MapData.PreTripPlanning? value) {
    if (value == null) {
      return null;
    }
    return {
      'isWarningTriangleRequired': value.isWarningTriangleRequired,
      'isFirstAidKitRequired': value.isFirstAidKitRequired,
      'isSafetyVestRequired': value.isSafetyVestRequired,
      'areSpareLightBulbsRequired': value.areSpareLightBulbsRequired,
      'isAlcoholTesterRequired': value.isAlcoholTesterRequired,
      'isFireExtinguisherRequired': value.isFireExtinguisherRequired,
      'isTowRopeRequired': value.isTowRopeRequired,
      'areWinterTiresRequired': value.areWinterTiresRequired,
      'winterSeasonPeriod': value.winterSeasonPeriod,
    }..removeWhere((_, Object? item) => item == null);
  }

  Map<String, dynamic>? _bloodAlcoholContentLimitToJson(
    MapData.BloodAlcoholContentLimit? value,
  ) {
    if (value == null) {
      return null;
    }
    return {
      'noviceDriverLimitPpm': value.noviceDriverLimitInPartsPerMillion,
      'standardDriverLimitPpm': value.standardDriverLimitInPartsPerMillion,
      'commercialDriverLimitPpm': value.commercialDriverLimitInPartsPerMillion,
    };
  }

  Map<String, dynamic> _tollSystemToJson(MapData.TollSystem value) => {
    'systemName': value.systemName,
    'tollCosts': value.tollCosts.map(_tollCostToJson).toList(),
  };

  Map<String, dynamic> _tollCostToJson(MapData.TollCost value) => {
    'currency': value.currency,
    'price': _finiteDouble(value.price),
    'paymentMethods': _enumList(value.paymentMethods),
    'isPriceCalculatedPerKilometer': value.isPriceCalculatedPerKilometer,
    'vehicleProfiles': value.vehicleProfiles
        .map(_vehicleProfileToJson)
        .toList(),
  }..removeWhere((_, Object? item) => item == null);

  Map<String, dynamic> _vehicleProfileToJson(Transport.VehicleProfile value) =>
      {
        'vehicleType': _enumName(value.vehicleType),
        'truckCategory': _enumName(value.truckCategory),
        'trailerCount': value.trailerCount,
        'hazardousMaterials': _enumList(value.hazardousMaterials),
        'tunnelCategory': _enumName(value.tunnelCategory),
        'axleCount': value.axleCount,
        'grossWeightKg': value.grossWeightInKilograms,
        'heightCm': value.heightInCentimeters,
        'lengthCm': value.lengthInCentimeters,
        'widthCm': value.widthInCentimeters,
        'weightPerAxleKg': value.weightPerAxleInKilograms,
      }..removeWhere((_, Object? item) => item == null);

  Map<String, dynamic> _laneBlockToJson(MapData.LaneBlock value) => {
    'startOffsetInMeters': value.startOffsetInMeters,
    'lanes': value.lanes.map(_laneDataToJson).toList(),
  };

  Map<String, dynamic> _laneDataToJson(MapData.LaneData value) => {
    'index': value.index,
    'travelDirection': _enumName(value.travelDirection),
    'attributes': _enumList(value.attributes),
    'connectivities': value.connectivities
        .map(_laneConnectivityToJson)
        .toList(),
  }..removeWhere((_, Object? item) => item == null);

  Map<String, dynamic> _laneConnectivityToJson(
    MapData.LaneConnectivity value,
  ) => {
    'access': _enumName(value.access),
    'targetSegmentId': _ocmSegmentIdToJson(value.targetSegmentId),
    'targetLaneBlockIndex': value.targetLaneBlockIndex,
    'targetLaneIndexes': value.targetLaneIndexes,
  };

  Map<String, dynamic> _adasAttributesToJson(MapData.AdasAttributes value) => {
    'offsetInMeters': value.offsetInMeters,
    'slopeInDegrees': value.slopeInDegrees,
    'elevationInCentimeters': value.elevationInCentimeters,
    'curvature': value.curvature,
  }..removeWhere((_, Object? item) => item == null);

  Map<String, dynamic> _trafficSignalToJson(MapData.TrafficSignal value) => {
    'offsetInMeters': value.offsetInMeters,
    'travelDirection': _enumName(value.travelDirection),
    'signalLocations': _enumList(value.signalLocations),
  };

  Map<String, dynamic> _roadSignToJson(Navigation.RoadSign value) => {
    'offsetInMeters': value.offsetInMeters,
    'travelDirection': _enumName(value.travelDirection),
    'roadSignType': _enumName(value.roadSignType),
    'roadSignCategory': _enumName(value.roadSignCategory),
    'isPrioritySign': value.isPrioritySign,
    'generalWarningType': _enumName(value.generalWarningType),
    'vehicleTypes': _enumList(value.vehicleTypes),
    'weatherType': _enumName(value.weatherType),
    'localizedSignValue': _localizedTextToJson(value.localizedSignValue),
    'localizedPreWarning': _localizedTextToJson(value.localizedPreWarning),
    'localizedDuration': _localizedTextToJson(value.localizedDuration),
    'localizedValidityTime': _localizedTextToJson(value.localizedValidityTime),
  }..removeWhere((_, Object? item) => item == null);

  Map<String, dynamic> _railwayCrossingToJson(MapData.RailwayCrossing value) =>
      {
        'startOffsetInMeters': value.startOffsetInMeters,
        'endOffsetInMeters': value.endOffsetInMeters,
        'railwayCrossingType': _enumName(value.railwayCrossingType),
      };

  Map<String, dynamic>? _segmentConnectivitiesToJson(
    MapData.SegmentConnectivities? value,
  ) {
    if (value == null) {
      return null;
    }
    return {
      'sourceConnectivities': value.sourceConnectivities
          .map(_connectivityToJson)
          .toList(),
      'targetConnectivities': value.targetConnectivities
          .map(_connectivityToJson)
          .toList(),
    };
  }

  Map<String, dynamic> _connectivityToJson(MapData.Connectivity value) => {
    'directedSegmentId': _directedSegmentIdToJson(value.directedSegmentId),
    'access': _enumList(value.access),
  };

  Map<String, dynamic> _specialSpeedSituationToJson(
    MapData.SegmentSpecialSpeedSituation value,
  ) => {
    'specialSpeedType': _enumName(value.specialSpeedType),
    'speedLimitMps': _finiteDouble(value.speedLimitInMetersPerSecond),
    'appliesDuring': value.appliesDuring.map(_timeRuleToJson).toList(),
  };

  Map<String, dynamic> _tollPointToJson(MapData.TollPoint value) => {
    'offsetInMeters': value.offsetInMeters,
    'structureManeuvers': value.structureManeuvers
        .map(_tollStructureManeuverToJson)
        .toList(),
  };

  Map<String, dynamic> _tollStructureManeuverToJson(
    MapData.TollStructureManeuver value,
  ) => {
    'tollStructure': _tollStructureToJson(value.tollStructure),
    'isCheckpoint': value.isCheckpoint,
    'destinations': value.destinations.map(_directedSegmentIdToJson).toList(),
    'etcGuidanceFile': _fileReferenceToJson(value.etcGuidanceFile),
  }..removeWhere((_, Object? item) => item == null);

  Map<String, dynamic>? _tollStructureToJson(MapData.TollStructure? value) {
    if (value == null) {
      return null;
    }
    return {
      'structureTypes': _enumList(value.structureTypes),
      'paymentMethods': _enumList(value.paymentMethods),
    };
  }

  Map<String, dynamic>? _fileReferenceToJson(MapData.FileReference? value) {
    if (value == null) {
      return null;
    }
    return {
      'hostTileId': value.hostTileId,
      'fileName': value.fileName,
      'type': _enumName(value.type),
      'catalogHandle': value.catalogHandle,
    }..removeWhere((_, Object? item) => item == null);
  }

  List<String>? _enumList(List<Object>? values) =>
      values?.map(_enumName).whereType<String>().toList();

  String? _enumName(Object? value) {
    if (value == null) {
      return null;
    }
    final String text = value.toString();
    final int dot = text.lastIndexOf('.');
    return dot >= 0 ? text.substring(dot + 1) : text;
  }

  Map<String, dynamic> _exceptionToJson(Object error, StackTrace stackTrace) {
    return {
      'type': error.runtimeType.toString(),
      if (error is MapData.MapDataLoaderExceptionException)
        'code': _enumName(error.error),
      'message': error.toString(),
      'stackTrace': stackTrace.toString(),
    }..removeWhere((_, Object? item) => item == null);
  }

  double? _finiteDouble(double? value) =>
      value != null && value.isFinite ? value : null;

  double? _numberToDouble(Object? value) {
    if (value is num && value.isFinite) {
      return value.toDouble();
    }
    return null;
  }
}

class _SegmentDataLoadResult {
  _SegmentDataLoadResult.loaded(this.segmentData) : exception = null;

  _SegmentDataLoadResult.failed(this.exception) : segmentData = null;

  final MapData.SegmentData? segmentData;
  final Map<String, dynamic>? exception;

  Map<String, dynamic> toJson() => {
    'status': segmentData != null ? 'loaded' : 'error',
    if (exception != null) 'exception': exception,
  };
}

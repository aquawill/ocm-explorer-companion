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

import 'package:here_sdk/core.dart';
import 'package:path_provider/path_provider.dart';

import '../common/app_identity.dart';

class GpxTrackFile {
  GpxTrackFile({required this.path, required this.createdNewFile});

  final String path;
  final bool createdNewFile;
}

class GpxTrackRecorder {
  static const String _tracksDirectoryName = 'ocm_live_tracks';
  static const String _creator = companionAppName;
  static const String _footer = '    </trkseg>\n  </trk>\n</gpx>\n';

  Future<GpxTrackFile> startTrack({
    required String sessionId,
    required String deviceId,
    required DateTime startedAt,
    required bool appendToPrevious,
    String? previousFilePath,
  }) async {
    if (appendToPrevious && previousFilePath != null) {
      final File previousFile = File(previousFilePath);
      if (await previousFile.exists()) {
        await _repairFooterIfNeeded(previousFile);
        return GpxTrackFile(path: previousFile.path, createdNewFile: false);
      }
    }

    final Directory tracksDirectory = await _tracksDirectory();
    final File file = File(
      '${tracksDirectory.path}/${_safeFileName(sessionId)}.gpx',
    );
    await file.writeAsString(
      _initialDocument(
        sessionId: sessionId,
        deviceId: deviceId,
        startedAt: startedAt.toUtc(),
      ),
      flush: true,
    );
    return GpxTrackFile(path: file.path, createdNewFile: true);
  }

  Future<void> appendLocation({
    required String filePath,
    required Location location,
    required int sequence,
    required DateTime sentAt,
    Map<String, dynamic>? matchedLocation,
    Map<String, dynamic>? segmentEvidence,
  }) async {
    final File file = File(filePath);
    await _repairFooterIfNeeded(file);
    await _insertBeforeFooter(
      file,
      _trackPoint(
        location: location,
        sequence: sequence,
        sentAt: sentAt.toUtc(),
        matchedLocation: matchedLocation,
        segmentEvidence: segmentEvidence,
      ),
    );
  }

  Future<void> closeTrack({required String filePath}) async {
    await _repairFooterIfNeeded(File(filePath));
  }

  Future<Directory> _tracksDirectory() async {
    final Directory documentsDirectory =
        await getApplicationDocumentsDirectory();
    final Directory tracksDirectory = Directory(
      '${documentsDirectory.path}/$_tracksDirectoryName',
    );
    if (!await tracksDirectory.exists()) {
      await tracksDirectory.create(recursive: true);
    }
    return tracksDirectory;
  }

  Future<void> _insertBeforeFooter(File file, String text) async {
    final RandomAccessFile handle = await file.open(mode: FileMode.append);
    try {
      final int footerLength = _footer.length;
      final int length = await handle.length();
      await handle.setPosition(length - footerLength);
      await handle.truncate(length - footerLength);
      await handle.writeString(text);
      await handle.writeString(_footer);
      await handle.flush();
    } finally {
      await handle.close();
    }
  }

  Future<void> _repairFooterIfNeeded(File file) async {
    if (!await file.exists()) {
      throw FileSystemException('GPX file does not exist', file.path);
    }
    if (await _hasFooter(file)) {
      return;
    }
    final String text = await file.readAsString();

    final int lastCompletePointEnd = text.lastIndexOf('</trkpt>');
    if (lastCompletePointEnd >= 0) {
      final String repaired =
          '${text.substring(0, lastCompletePointEnd + '</trkpt>'.length)}\n$_footer';
      await file.writeAsString(repaired, flush: true);
      return;
    }

    final int segmentStart = text.indexOf('<trkseg>');
    if (segmentStart >= 0) {
      final int segmentContentStart = segmentStart + '<trkseg>'.length;
      final String repaired =
          '${text.substring(0, segmentContentStart)}\n$_footer';
      await file.writeAsString(repaired, flush: true);
      return;
    }

    throw FileSystemException('GPX file is not recoverable', file.path);
  }

  Future<bool> _hasFooter(File file) async {
    final RandomAccessFile handle = await file.open();
    try {
      final int footerLength = _footer.length;
      final int length = await handle.length();
      if (length < footerLength) {
        return false;
      }
      await handle.setPosition(length - footerLength);
      final List<int> footerBytes = await handle.read(footerLength);
      return String.fromCharCodes(footerBytes) == _footer;
    } finally {
      await handle.close();
    }
  }

  String _initialDocument({
    required String sessionId,
    required String deviceId,
    required DateTime startedAt,
  }) {
    final String escapedSessionId = _xml(sessionId);
    final String escapedDeviceId = _xml(deviceId);
    final String startedAtText = startedAt.toIso8601String();
    return '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="$_creator" xmlns="http://www.topografix.com/GPX/1/1" xmlns:ocm="https://self.local/ocm-live-tracker">
  <metadata>
    <name>$liveTrackingFeatureName $escapedSessionId</name>
    <time>$startedAtText</time>
  </metadata>
  <trk>
    <name>$liveTrackingFeatureName $escapedSessionId</name>
    <type>GPS</type>
    <extensions>
      <ocm:deviceId>$escapedDeviceId</ocm:deviceId>
      <ocm:firstSessionId>$escapedSessionId</ocm:firstSessionId>
    </extensions>
    <trkseg>
$_footer''';
  }

  String _trackPoint({
    required Location location,
    required int sequence,
    required DateTime sentAt,
    Map<String, dynamic>? matchedLocation,
    Map<String, dynamic>? segmentEvidence,
  }) {
    final GeoCoordinates coordinates = location.coordinates;
    final StringBuffer buffer = StringBuffer()
      ..writeln(
        '      <trkpt lat="${_decimal(coordinates.latitude, 8)}" lon="${_decimal(coordinates.longitude, 8)}">',
      );
    final double? altitude = coordinates.altitude;
    if (altitude != null && altitude.isFinite) {
      buffer.writeln('        <ele>${_decimal(altitude, 2)}</ele>');
    }
    final DateTime time = location.time?.toUtc() ?? sentAt;
    buffer
      ..writeln('        <time>${time.toIso8601String()}</time>')
      ..writeln('        <extensions>')
      ..writeln('          <ocm:seq>$sequence</ocm:seq>')
      ..writeln(
        '          <ocm:sentAt>${sentAt.toIso8601String()}</ocm:sentAt>',
      );
    buffer.writeln(
      '          <ocm:matchedStatus>${matchedLocation == null ? 'unmatched' : 'matched'}</ocm:matchedStatus>',
    );
    _extensionElement(
      buffer,
      'accuracyM',
      location.horizontalAccuracyInMeters,
      fractionDigits: 2,
    );
    _extensionElement(
      buffer,
      'verticalAccuracyM',
      location.verticalAccuracyInMeters,
      fractionDigits: 2,
    );
    _extensionElement(
      buffer,
      'speedMps',
      location.speedInMetersPerSecond,
      fractionDigits: 2,
    );
    _extensionElement(
      buffer,
      'bearingDeg',
      location.bearingInDegrees,
      fractionDigits: 2,
    );
    _extensionElement(
      buffer,
      'bearingAccuracyDeg',
      location.bearingAccuracyInDegrees,
      fractionDigits: 2,
    );
    _extensionElement(
      buffer,
      'speedAccuracyMps',
      location.speedAccuracyInMetersPerSecond,
      fractionDigits: 2,
    );
    _jsonExtensionElement(buffer, 'matchedJson', matchedLocation);
    if (segmentEvidence != null) {
      _textExtensionElement(
        buffer,
        'segmentStatus',
        segmentEvidence['status']?.toString(),
      );
      _textExtensionElement(
        buffer,
        'matchedSpanIndex',
        segmentEvidence['matchedSpanIndex']?.toString(),
      );
      _jsonExtensionElement(buffer, 'segmentEvidenceJson', segmentEvidence);
    }
    buffer
      ..writeln('        </extensions>')
      ..writeln('      </trkpt>');
    return buffer.toString();
  }

  void _textExtensionElement(StringBuffer buffer, String name, String? value) {
    if (value == null || value.isEmpty) {
      return;
    }
    buffer.writeln('          <ocm:$name>${_xml(value)}</ocm:$name>');
  }

  void _jsonExtensionElement(
    StringBuffer buffer,
    String name,
    Map<String, dynamic>? value,
  ) {
    if (value == null) {
      return;
    }
    buffer.writeln(
      '          <ocm:$name>${_xml(jsonEncode(value))}</ocm:$name>',
    );
  }

  void _extensionElement(
    StringBuffer buffer,
    String name,
    double? value, {
    required int fractionDigits,
  }) {
    if (value == null || !value.isFinite) {
      return;
    }
    buffer.writeln(
      '          <ocm:$name>${_decimal(value, fractionDigits)}</ocm:$name>',
    );
  }

  String _decimal(double value, int fractionDigits) {
    if (value.isNaN || value.isInfinite) {
      return '';
    }
    return value.toStringAsFixed(fractionDigits);
  }

  String _safeFileName(String value) {
    final String safe = value
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9._-]+'), '-')
        .replaceAll(RegExp(r'-+'), '-')
        .replaceAll(RegExp(r'^-|-$'), '');
    return safe.isEmpty ? 'track' : safe;
  }

  String _xml(String value) {
    return value
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;')
        .replaceAll("'", '&apos;');
  }
}

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

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../common/app_identity.dart';
import 'live_tracker_service.dart';

Future<void> showLiveTrackerSettingsDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (_) => const _LiveTrackerSettingsDialog(),
  );
}

class _LiveTrackerSettingsDialog extends StatefulWidget {
  const _LiveTrackerSettingsDialog();

  @override
  State<_LiveTrackerSettingsDialog> createState() =>
      _LiveTrackerSettingsDialogState();
}

class _LiveTrackerSettingsDialogState
    extends State<_LiveTrackerSettingsDialog> {
  late final TextEditingController _serverUrlController;
  late final TextEditingController _tokenController;
  late final TextEditingController _firebaseDatabaseUrlController;
  late final TextEditingController _firebasePathPrefixController;
  late final TextEditingController _deviceIdController;
  late LiveTrackerTarget _target;
  late int _intervalMs;
  String? _errorText;
  bool _isStartingTracking = false;
  bool _isExportingGpxTrack = false;

  @override
  void initState() {
    super.initState();
    final LiveTrackerService tracker = context.read<LiveTrackerService>();
    _serverUrlController = TextEditingController(text: tracker.serverUrl);
    _tokenController = TextEditingController(text: tracker.token);
    _firebaseDatabaseUrlController = TextEditingController(
      text: tracker.firebaseDatabaseUrl,
    );
    _firebasePathPrefixController = TextEditingController(
      text: tracker.firebasePathPrefix,
    );
    _deviceIdController = TextEditingController(text: tracker.deviceId);
    _target = tracker.target;
    _intervalMs = tracker.minIntervalMs;
  }

  @override
  void dispose() {
    _serverUrlController.dispose();
    _tokenController.dispose();
    _firebaseDatabaseUrlController.dispose();
    _firebasePathPrefixController.dispose();
    _deviceIdController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final LiveTrackerService tracker = context.watch<LiveTrackerService>();

    return AlertDialog(
      title: const Text(liveTrackingFeatureName),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _TrackingStatusBanner(tracker: tracker),
              const SizedBox(height: 8),
              DropdownButtonFormField<LiveTrackerTarget>(
                initialValue: _target,
                decoration: const InputDecoration(labelText: 'Target'),
                items: const [
                  DropdownMenuItem(
                    value: LiveTrackerTarget.firebaseRealtime,
                    child: Text('OCM Explorer (Firebase)'),
                  ),
                  DropdownMenuItem(
                    value: LiveTrackerTarget.localServer,
                    child: Text('OCM Explorer API (LAN)'),
                  ),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _target = value);
                  }
                },
              ),
              const SizedBox(height: 8),
              if (_target == LiveTrackerTarget.localServer) ...[
                TextField(
                  controller: _serverUrlController,
                  decoration: const InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'http://192.168.1.10:5000',
                  ),
                  keyboardType: TextInputType.url,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _tokenController,
                  decoration: const InputDecoration(labelText: 'Token'),
                  obscureText: true,
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 8),
              ],
              if (_target == LiveTrackerTarget.firebaseRealtime) ...[
                if (!tracker.hasBundledFirebaseDatabaseUrl) ...[
                  TextField(
                    controller: _firebaseDatabaseUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Firebase database URL',
                      hintText: 'https://project-id.firebaseio.com',
                    ),
                    keyboardType: TextInputType.url,
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 8),
                ],
                if (!tracker.hasBundledFirebasePathPrefix) ...[
                  TextField(
                    controller: _firebasePathPrefixController,
                    decoration: const InputDecoration(
                      labelText: 'Path prefix',
                      hintText: LiveTrackerService.firebaseDefaultPathPrefix,
                    ),
                    textInputAction: TextInputAction.next,
                  ),
                  const SizedBox(height: 8),
                ],
              ],
              TextField(
                controller: _deviceIdController,
                decoration: const InputDecoration(labelText: 'Device ID'),
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<int>(
                initialValue: _intervalMs,
                decoration: const InputDecoration(labelText: 'Write interval'),
                items: const [
                  DropdownMenuItem(value: 500, child: Text('0.5 seconds')),
                  DropdownMenuItem(value: 1000, child: Text('1 second')),
                  DropdownMenuItem(value: 2000, child: Text('2 seconds')),
                  DropdownMenuItem(value: 5000, child: Text('5 seconds')),
                ],
                onChanged: (value) {
                  if (value != null) {
                    setState(() => _intervalMs = value);
                  }
                },
              ),
              const SizedBox(height: 16),
              if (_target == LiveTrackerTarget.firebaseRealtime) ...[
                _FirebaseTrackPanel(
                  tracker: tracker,
                  isStarting: _isStartingTracking,
                  isExporting: _isExportingGpxTrack,
                  onStartOrNew: _startFirebaseSession,
                  onStop: _stopTracking,
                  onExport: _exportGpxTrack,
                ),
              ],
              if (_target == LiveTrackerTarget.localServer) ...[
                _LocalServerTrackPanel(
                  tracker: tracker,
                  serverUrl: _serverUrlController.text,
                  isStarting: _isStartingTracking,
                  onStart: _startLocalServerTracking,
                  onStop: _stopTracking,
                ),
              ],
              if (_errorText != null)
                Text(
                  _errorText!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _save, child: const Text('Save')),
      ],
    );
  }

  Future<void> _save() async {
    final LiveTrackerService tracker = context.read<LiveTrackerService>();
    final bool wasEnabled = tracker.enabled;
    await tracker.configure(
      enabled: wasEnabled,
      target: _target,
      serverUrl: _serverUrlController.text,
      token: _tokenController.text,
      deviceId: _deviceIdController.text,
      minIntervalMs: _intervalMs,
      firebaseDatabaseUrl: _firebaseDatabaseUrlController.text,
      firebasePathPrefix: _firebasePathPrefixController.text,
      appendToPreviousGpxTrack: tracker.appendToPreviousGpxTrack,
    );
    if (wasEnabled && _target == LiveTrackerTarget.firebaseRealtime) {
      await tracker.ensureFirebaseSession();
      if (!tracker.enabled) {
        setState(() => _errorText = tracker.statusText);
        return;
      }
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _startFirebaseSession() async {
    setState(() {
      _isStartingTracking = true;
      _errorText = null;
    });
    try {
      final LiveTrackerService tracker = context.read<LiveTrackerService>();
      await tracker.configure(
        target: LiveTrackerTarget.firebaseRealtime,
        deviceId: _deviceIdController.text,
        minIntervalMs: _intervalMs,
        firebaseDatabaseUrl: _firebaseDatabaseUrlController.text,
        firebasePathPrefix: _firebasePathPrefixController.text,
        appendToPreviousGpxTrack: false,
      );
      await tracker.startFirebaseSession();
      setState(() {
        _target = tracker.target;
      });
    } catch (error) {
      setState(() => _errorText = error.toString());
    } finally {
      if (mounted) {
        setState(() => _isStartingTracking = false);
      }
    }
  }

  Future<void> _startLocalServerTracking() async {
    setState(() {
      _isStartingTracking = true;
      _errorText = null;
    });
    try {
      final LiveTrackerService tracker = context.read<LiveTrackerService>();
      await tracker.configure(
        enabled: true,
        target: LiveTrackerTarget.localServer,
        serverUrl: _serverUrlController.text,
        token: _tokenController.text,
        deviceId: _deviceIdController.text,
        minIntervalMs: _intervalMs,
      );
      setState(() {
        _target = tracker.target;
      });
    } catch (error) {
      setState(() => _errorText = error.toString());
    } finally {
      if (mounted) {
        setState(() => _isStartingTracking = false);
      }
    }
  }

  Future<void> _stopTracking() async {
    final LiveTrackerService tracker = context.read<LiveTrackerService>();
    if (tracker.target == LiveTrackerTarget.firebaseRealtime) {
      await tracker.stopFirebaseSession();
    } else {
      await tracker.setEnabled(false);
    }
    setState(() {});
  }

  Future<void> _exportGpxTrack() async {
    setState(() {
      _isExportingGpxTrack = true;
      _errorText = null;
    });
    try {
      await context.read<LiveTrackerService>().exportGpxTrack();
    } catch (error) {
      setState(() => _errorText = error.toString());
    } finally {
      if (mounted) {
        setState(() => _isExportingGpxTrack = false);
      }
    }
  }
}

class _TrackingStatusBanner extends StatelessWidget {
  const _TrackingStatusBanner({required this.tracker});

  final LiveTrackerService tracker;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colorScheme = Theme.of(context).colorScheme;
    final bool isTracking = tracker.enabled;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              isTracking ? Icons.radio_button_checked : Icons.pause_circle,
              color: isTracking ? colorScheme.primary : colorScheme.outline,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isTracking ? 'Tracking' : 'Stopped',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    tracker.statusText,
                    style: TextStyle(color: colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LocalServerTrackPanel extends StatelessWidget {
  const _LocalServerTrackPanel({
    required this.tracker,
    required this.serverUrl,
    required this.isStarting,
    required this.onStart,
    required this.onStop,
  });

  final LiveTrackerService tracker;
  final String serverUrl;
  final bool isStarting;
  final VoidCallback onStart;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    final bool isLocalTracking =
        tracker.enabled && tracker.target == LiveTrackerTarget.localServer;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'OCM Explorer API',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            _InfoRow(label: 'Server URL', value: serverUrl),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: tracker.enabled ? onStop : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
                FilledButton.icon(
                  onPressed: isStarting ? null : onStart,
                  icon: const Icon(Icons.play_arrow),
                  label: Text(
                    isStarting
                        ? 'Starting...'
                        : isLocalTracking
                        ? 'Restart tracking'
                        : 'Start tracking',
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FirebaseTrackPanel extends StatelessWidget {
  const _FirebaseTrackPanel({
    required this.tracker,
    required this.isStarting,
    required this.isExporting,
    required this.onStartOrNew,
    required this.onStop,
    required this.onExport,
  });

  final LiveTrackerService tracker;
  final bool isStarting;
  final bool isExporting;
  final VoidCallback onStartOrNew;
  final VoidCallback onStop;
  final VoidCallback onExport;

  @override
  Widget build(BuildContext context) {
    final String sessionId = tracker.firebaseSessionId ?? 'No active session';
    final String gpxFile =
        tracker.gpxTrackFilePath ??
        tracker.lastGpxTrackFilePath ??
        'No GPX file';
    final String startLabel = tracker.enabled
        ? 'New session'
        : 'Start tracking';

    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).dividerColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Firebase Realtime Database',
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            _InfoRow(label: 'Path prefix', value: tracker.firebasePathPrefix),
            _InfoRow(label: 'Session ID', value: sessionId),
            _InfoRow(label: 'GPX file', value: gpxFile),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.end,
              children: [
                OutlinedButton.icon(
                  onPressed: tracker.enabled ? onStop : null,
                  icon: const Icon(Icons.stop),
                  label: const Text('Stop'),
                ),
                OutlinedButton.icon(
                  onPressed:
                      tracker.exportableGpxTrackFilePath == null || isExporting
                      ? null
                      : onExport,
                  icon: const Icon(Icons.ios_share),
                  label: Text(isExporting ? 'Exporting...' : 'Export'),
                ),
                FilledButton.icon(
                  onPressed: isStarting ? null : onStartOrNew,
                  icon: Icon(tracker.enabled ? Icons.add : Icons.play_arrow),
                  label: Text(isStarting ? 'Starting...' : startLabel),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
          Expanded(child: SelectableText(value, maxLines: 3)),
        ],
      ),
    );
  }
}

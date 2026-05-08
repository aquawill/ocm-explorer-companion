/*
 * Copyright (C) 2025 HERE Europe B.V.
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

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:here_sdk_reference_application_flutter/common/hds_icons/hds_assets_paths.dart';
import 'package:here_sdk_reference_application_flutter/common/hds_icons/hds_icon_widget.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../common/application_preferences.dart';
import '../common/gradient_elevated_button.dart';
import '../common/ui_style.dart';

// Third-party privacy notice URLs.
const String _herePrivacyNoticeUrl =
    'https://legal.here.com/en-gb/here-network-positioning-via-sdk';
const String _firebasePrivacyUrl =
    'https://firebase.google.com/support/privacy';

const String _privacyNoticeText = '''
Last updated: May 8, 2026

OCM Explorer Companion is a companion app for OCM Explorer. Its remote tracking feature sends your device's current location to the remote endpoint that you configure, so another OCM Explorer client can view the latest position.

Data handled by this app may include latitude, longitude, timestamp, speed, heading, altitude, positioning accuracy, the Device ID you enter, remote tracking settings, and GPX track files.

When OCM Live Tracking is active, the app writes the current location to the configured Firebase Realtime Database path. Firebase is used only as a current-location relay for this feature. Full track history is stored on this device as GPX files, one file per tracking session, unless you choose to share or export those files through the system share sheet.

The app does not send location updates after tracking is stopped. You can change the Device ID and remote endpoint settings at any time. Removing the app normally removes its local settings and locally stored GPX files.

If you export a GPX file, the selected receiving app or service controls how that exported copy is handled.
''';

const String _herePrivacyNoticeText =
    'This app uses HERE SDK for map display and location-related functionality. '
    'When HERE network positioning is used, HERE may process location data and nearby Wi-Fi or mobile network signal characteristics as described in the HERE privacy notice: ';

const String _firebasePrivacyNoticeText =
    'If you configure Firebase Realtime Database as the remote tracking endpoint, that service is provided by Google Firebase. '
    'Firebase privacy and security information is available here: ';

const EdgeInsets _commonPadding = const EdgeInsets.symmetric(
  vertical: UIStyle.contentMarginLarge,
  horizontal: UIStyle.contentMarginLarge,
);

/// A screen that shows the HERE Privacy Notice, typically from Settings,
/// to inform users about data handling and ensure privacy compliance.
class HerePrivacyNoticeScreen extends StatelessWidget {
  HerePrivacyNoticeScreen({super.key});
  static const String navRoute = "/here_privacy_notice_screen";

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Privacy Notice'),
        leading: IconButton(
          highlightColor: UIStyle.foregroundInactive,
          onPressed: () => Navigator.maybePop(context),
          icon: const HdsIconWidget.medium(HdsAssetsPaths.arrowLeftIcon),
          iconSize: UIStyle.sizeAppBarIcon,
        ),
      ),
      body: Padding(
        padding: _commonPadding,
        child: ListView(
          children: <Widget>[
            Text(
              _privacyNoticeText,
              style: TextStyle(fontSize: UIStyle.bigFontSize),
            ),
            const SizedBox(height: UIStyle.contentMarginLarge),
            const HerePrivacyNoticeWidget(),
          ],
        ),
      ),
    );
  }
}

/// A reusable widget that shows the HERE Privacy Notice with a link to more details.
class HerePrivacyNoticeWidget extends StatelessWidget {
  const HerePrivacyNoticeWidget({super.key});

  Future<void> _launchURL(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    } else {
      print('Could not launch $url');
    }
  }

  @override
  Widget build(BuildContext context) {
    return RichText(
      text: TextSpan(
        style: DefaultTextStyle.of(
          context,
        ).style.copyWith(fontSize: UIStyle.bigFontSize),
        children: [
          const TextSpan(text: _herePrivacyNoticeText),
          TextSpan(
            text: _herePrivacyNoticeUrl,
            style: TextStyle(
              color: Colors.blue,
              decoration: TextDecoration.underline,
            ),
            recognizer: TapGestureRecognizer()
              ..onTap = () => _launchURL(_herePrivacyNoticeUrl),
          ),
          const TextSpan(text: '\n\n'),
          const TextSpan(text: _firebasePrivacyNoticeText),
          TextSpan(
            text: _firebasePrivacyUrl,
            style: TextStyle(
              color: Colors.blue,
              decoration: TextDecoration.underline,
            ),
            recognizer: TapGestureRecognizer()
              ..onTap = () => _launchURL(_firebasePrivacyUrl),
          ),
        ],
      ),
    );
  }
}

/// A dialog that displays the HERE Privacy Notice during app startup as part of the FTU (First-Time Use) flow.
class HerePrivacyDialog extends StatelessWidget {
  const HerePrivacyDialog({super.key});

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: AlertDialog(
        scrollable: true,
        title: const Text('Welcome', textAlign: TextAlign.center),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Thanks for using OCM Explorer Companion.\n\n'
              'Please review the following privacy notice before continuing.\n\n',
            ),
            const HerePrivacyNoticeWidget(),
          ],
        ),
        actions: [
          GradientElevatedButton(
            title: const Text('Continue'),
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
        contentPadding: _commonPadding,
        actionsPadding: _commonPadding,
        insetPadding: _commonPadding,
      ),
    );
  }
}

/// Shows the HERE Privacy Dialog, typically during app startup as part of the FTU flow.
Future<void> showHerePrivacyDialog(BuildContext context) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (BuildContext dialogContext) {
      return const HerePrivacyDialog();
    },
  );
  if (accepted == true) {
    Provider.of<AppPreferences>(
      context,
      listen: false,
    ).isHerePrivacyDialogShown = true;
  }
}

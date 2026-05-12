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

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

class ShareFileService {
  static const MethodChannel _shareChannel = MethodChannel(
    'com.example.RefApp/share_channel',
  );

  static Future<void> shareTextFile({
    required String fileName,
    required String content,
    required String mimeType,
    String? subject,
    String? text,
  }) async {
    final Directory temporaryDirectory = await getTemporaryDirectory();
    final File file = File('${temporaryDirectory.path}/$fileName');
    await file.writeAsString(content, flush: true);
    await _shareChannel.invokeMethod<void>('shareFile', {
      'path': file.path,
      'mimeType': mimeType,
      if (subject != null) 'subject': subject,
      if (text != null) 'text': text,
    });
  }
}

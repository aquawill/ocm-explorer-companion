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
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:here_sdk/core.dart';
import 'package:here_sdk/core.engine.dart';
import 'package:here_sdk/maploader.dart';
import 'package:here_sdk/routing.dart' as Routing;
import 'package:here_sdk/search.dart';
import 'package:here_sdk_reference_application_flutter/environment.dart';
import 'package:here_sdk_reference_application_flutter/l10n/generated/app_localizations.dart';
import 'package:here_sdk_reference_application_flutter/sdk_engine_configuration/catalog_configuration_data.dart';
import 'package:here_sdk_reference_application_flutter/sdk_engine_configuration/custom_catalog_configuration_screen.dart';
import 'package:here_sdk_reference_application_flutter/sdk_engine_configuration/sdk_engine_utils.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'common/application_preferences.dart';
import 'common/app_identity.dart';
import 'common/custom_map_style_settings.dart';
import 'common/ui_style.dart';
import 'download_maps/download_maps_screen.dart';
import 'download_maps/map_loader_controller.dart';
import 'download_maps/map_regions_list_screen.dart';
import 'landing_screen.dart';
import 'live_tracker/live_tracker_service.dart';
import 'navigation/navigation_screen.dart';
import 'positioning/here_privacy_notice_handler.dart';
import 'positioning/positioning_engine.dart';
import 'route_preferences/route_preferences_model.dart';
import 'routing/route_details_screen.dart';
import 'routing/routing_screen.dart';
import 'routing/waypoint_info.dart';
import 'routing/waypoints_controller.dart';
import 'search/recent_search_data_model.dart';
import 'search/search_results_screen.dart';

LogAppender? _hereSdkLogAppender;

/// The entry point of the application.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  SdkContext.init();
  _configureHereSdkLogging();

  // Obtain an instance of SharedPreferences for persistent storage.
  final SharedPreferences sharedPreferences =
      await SharedPreferences.getInstance();

  // Load catalog configurations data from preferences and convert to CatalogConfiguration format.
  final List<CatalogConfigurationData>? catalogConfigurationData =
      AppPreferences.loadSdkOptionsCatalogConfigurationFromPrefs(
        sharedPreferences,
      );
  _logCatalogConfigurations(catalogConfigurationData);
  final List<CatalogConfiguration>? catalogConfigurations =
      catalogConfigurationData?.toSdkCatalogConfigurations();
  _logCredentialPresence();

  // Create SDKOptions with authentication using access key and secret.
  final SDKOptions sdkOptions = SDKOptions.withAuthenticationMode(
    AuthenticationMode.withKeySecret(
      Environment.accessKeyId,
      Environment.accessKeySecret,
    ),
  );

  // If catalog configurations are available, assign them to sdkOptions.
  if (catalogConfigurations != null && catalogConfigurations.isNotEmpty) {
    sdkOptions.catalogConfigurations = catalogConfigurations;
  }

  createSDKNativeEngine(
    sdkOptions: sdkOptions,
    onSuccess: () => runApp(MyApp(sharedPreferences: sharedPreferences)),
    onFailure: (_) => runApp(const InitErrorScreen()),
  );
}

void _logCredentialPresence() {
  final bool hasAccessKeyId = Environment.accessKeyId.trim().isNotEmpty;
  final bool hasAccessKeySecret = Environment.accessKeySecret.trim().isNotEmpty;
  debugPrint(
    '[$companionAppName] HERE credentials '
    'accessKeyId=${hasAccessKeyId ? 'set' : 'missing'}, '
    'accessKeySecret=${hasAccessKeySecret ? 'set' : 'missing'}',
  );
}

void _configureHereSdkLogging() {
  LogControl.enableLoggingToConsole(LogLevel.logLevelInfo);
  _hereSdkLogAppender = LogAppender((LogLevel level, String message) {
    debugPrint('[HERE SDK ${_logLevelLabel(level)}] $message');
  });
  LogControl.setCustomAppender(LogLevel.logLevelInfo, _hereSdkLogAppender!);
  debugPrint('[$companionAppName] HERE SDK logging enabled.');
}

String _logLevelLabel(LogLevel level) {
  switch (level) {
    case LogLevel.logLevelInfo:
      return 'INFO';
    case LogLevel.logLevelWarning:
      return 'WARN';
    case LogLevel.logLevelError:
      return 'ERROR';
    case LogLevel.logLevelFatal:
      return 'FATAL';
    case LogLevel.logLevelOff:
      return 'OFF';
  }
}

void _logCatalogConfigurations(List<CatalogConfigurationData>? configs) {
  if (configs == null || configs.isEmpty) {
    debugPrint('[$companionAppName] No custom catalog configurations.');
    return;
  }

  debugPrint(
    '[$companionAppName] Applying ${configs.length} custom catalog configuration(s).',
  );
  for (final CatalogConfigurationData config in configs) {
    debugPrint(
      '[$companionAppName] CatalogConfiguration '
      'hrn=${config.hrn}, '
      'version=${config.version ?? 'latest'}, '
      'allowDownload=${config.allowDownload}, '
      'ignoreCachedData=${config.ignoreCachedData}, '
      'cacheExpirationInSec=${config.cacheExpirationInSec ?? 'none'}, '
      'patchHrn=${config.patchHrn ?? 'none'}',
    );
  }
}

/// Application root widget.
class MyApp extends StatefulWidget {
  const MyApp({super.key, required this.sharedPreferences});

  final SharedPreferences sharedPreferences;

  @override
  _MyAppState createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  @override
  void dispose() {
    SdkContext.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (context) => RecentSearchDataModel()),
        ChangeNotifierProvider(
          create: (context) => RoutePreferencesModel.withDefaults(),
        ),
        ChangeNotifierProvider(create: (context) => MapLoaderController()),
        ChangeNotifierProvider(
          create: (context) =>
              AppPreferences.withSharedPreferences(widget.sharedPreferences),
        ),
        Provider(create: (context) => PositioningEngine()),
        ChangeNotifierProvider(create: (context) => LiveTrackerService()),
        ChangeNotifierProvider(create: (context) => CustomMapStyleSettings()),
      ],
      child: MaterialApp(
        localizationsDelegates: [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        locale: const Locale('en', ''),
        supportedLocales: const [Locale('en', '')],
        theme: UIStyle.lightTheme,
        onGenerateTitle: (BuildContext context) =>
            AppLocalizations.of(context)!.appTitle,
        onGenerateRoute: (RouteSettings settings) {
          Map<String, WidgetBuilder> routes = {
            LandingScreen.navRoute: (BuildContext context) =>
                LandingScreen(key: LandingScreen.landingScreenKey),
            SearchResultsScreen.navRoute: (BuildContext context) {
              List<dynamic> arguments = settings.arguments as List<dynamic>;
              assert(arguments.length == 4);
              return SearchResultsScreen(
                queryString: arguments[0] as String,
                places: arguments[1] as List<Place>,
                currentPosition: arguments[2] as GeoCoordinates,
                isRecentSearchResult: arguments[3] as bool,
              );
            },
            RoutingScreen.navRoute: (BuildContext context) {
              List<dynamic> arguments = settings.arguments as List<dynamic>;
              assert(arguments.length == 3);
              return RoutingScreen(
                currentPosition: arguments[0] as GeoCoordinates,
                departure: arguments[1] as WayPointInfo,
                destination: arguments[2] as WayPointInfo,
              );
            },
            RouteDetailsScreen.navRoute: (BuildContext context) {
              List<dynamic> arguments = settings.arguments as List<dynamic>;
              assert(arguments.length == 2);
              return RouteDetailsScreen(
                route: arguments[0] as Routing.Route,
                wayPointsController: arguments[1] as WayPointsController,
              );
            },
            NavigationScreen.navRoute: (BuildContext context) {
              List<dynamic> arguments = settings.arguments as List<dynamic>;
              assert(arguments.length == 2);
              return NavigationScreen(
                route: arguments[0] as Routing.Route,
                wayPoints: arguments[1] as List<Routing.Waypoint>,
              );
            },
            DownloadMapsScreen.navRoute: (BuildContext context) {
              return DownloadMapsScreen();
            },
            HerePrivacyNoticeScreen.navRoute: (BuildContext context) =>
                HerePrivacyNoticeScreen(),
            MapRegionsListScreen.navRoute: (BuildContext context) {
              List<dynamic> arguments = settings.arguments as List<dynamic>;
              assert(arguments.length == 1);
              return MapRegionsListScreen(
                regions: arguments[0] as List<Region>,
              );
            },
            CustomCatalogConfigurationScreen.navRoute: (BuildContext context) =>
                CustomCatalogConfigurationScreen(),
          };

          WidgetBuilder builder = routes[settings.name]!;
          return MaterialPageRoute(
            builder: (ctx) => builder(ctx),
            settings: settings,
          );
        },
        initialRoute: LandingScreen.navRoute,
      ),
    );
  }
}

class InitErrorScreen extends StatelessWidget {
  const InitErrorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      locale: const Locale('en', ''),
      supportedLocales: const [Locale('en', '')],
      home: Builder(
        builder: (context) {
          return Container(
            color: Theme.of(context).colorScheme.surface,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(UIStyle.contentMarginExtraHuge),
                child: Text(
                  AppLocalizations.of(context)!.sdkInitFailError,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
            ),
          );
        },
      ),
      theme: UIStyle.lightTheme,
      localizationsDelegates: [AppLocalizations.delegate],
    );
  }
}

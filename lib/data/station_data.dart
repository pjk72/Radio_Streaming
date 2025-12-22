import 'package:flutter/foundation.dart';
import '../models/station.dart';
import '../models/station_genre.dart';

String _getPlatformUrl({
  required String defaultUrl,
  String? web,
  String? android,
  String? ios,
  String? windows,
  String? macos,
  String? linux,
}) {
  if (kIsWeb) {
    return web ?? defaultUrl;
  }
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return android ?? defaultUrl;
    case TargetPlatform.iOS:
      return ios ?? defaultUrl;
    case TargetPlatform.windows:
      return windows ?? defaultUrl;
    case TargetPlatform.macOS:
      return macos ?? defaultUrl;
    case TargetPlatform.linux:
      return linux ?? defaultUrl;
    default:
      return defaultUrl;
  }
}

List<Station> stations = [
  // Station(
  //   id: 1,
  //   name: "Radio Deejay",
  //   genre: "Pop | Italian",
  //   url: _getPlatformUrl(
  //     defaultUrl:
  //         "https://4c4b867c89244861ac216426883d1ad0.msvdn.net/radiodeejay/radiodeejay/master_ma.m3u8",
  //   ),
  //   icon: "radio",
  //   logo: "assets/images/default_stations/pop.png",
  //   color: "0xffD32F2F",
  //   category: "Italian",
  // ),
];

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
  // Italian
  Station(
    id: 1,
    name: "Radio 105",
    genre: "Pop",
    url: _getPlatformUrl(defaultUrl: "https://icy.unitedradio.it/Radio105.mp3"),
    icon: "radio",
    logo: "assets/images/default_stations/pop.png",
    color: "0xffFBC02D",
    category: "Italian",
  ),
  Station(
    id: 2,
    name: "Radio Deejay",
    genre: "Pop | Italian",
    url: _getPlatformUrl(
      defaultUrl:
          "https://4c4b867c89244861ac216426883d1ad0.msvdn.net/radiodeejay/radiodeejay/master_ma.m3u8",
    ),
    icon: "radio",
    logo: "assets/images/default_stations/pop.png",
    color: "0xffD32F2F",
    category: "Italian",
  ),
  Station(
    id: 3,
    name: "Virgin Radio",
    genre: StationGenre.rock,
    url: _getPlatformUrl(defaultUrl: "https://icy.unitedradio.it/Virgin.mp3"),
    icon: "radio",
    logo: "assets/images/default_stations/rock.png",
    color: "0xffB71C1C",
    category: "Italian",
  ),
  Station(
    id: 4,
    name: "R101",
    genre: "Pop",
    url: _getPlatformUrl(defaultUrl: "https://icy.unitedradio.it/R101.mp3"),
    icon: "radio",
    logo: "assets/images/default_stations/pop.png",
    color: "0xffE65100",
    category: "Italian",
  ),
  Station(
    id: 5,
    name: "RTL 102.5",
    genre: "Pop",
    url: _getPlatformUrl(
      defaultUrl:
          "https://dd782ed59e2a4e86aabf6fc508674b59.msvdn.net/live/S97044836/tbbP8T1ZRPBL/playlist_audio.m3u8",
    ),
    icon: "radio",
    logo: "assets/images/default_stations/pop.png",
    color: "0xff000000",
    category: "Italian",
  ),
  Station(
    id: 6,
    name: "RDS",
    genre: "Pop",
    url: _getPlatformUrl(
      defaultUrl: "https://stream.rds.radio/audio/rds.stream_aac/playlist.m3u8",
    ),
    icon: "radio",
    logo: "assets/images/default_stations/pop.png",
    color: "0xffC2185B",
    category: "Italian",
  ),
  Station(
    id: 7,
    name: "Radio Italia",
    genre: StationGenre.italian,
    url: _getPlatformUrl(
      defaultUrl:
          "https://radioitaliasmi.akamaized.net/hls/live/2093120/RISMI/stream01/streamPlaylist.m3u8",
    ),
    icon: "radio",
    logo: "assets/images/default_stations/italian.png",
    color: "0xffE53935",
    category: "Italian",
  ),
  Station(
    id: 8,
    name: "RAI Radio 1",
    genre: "News",
    url: _getPlatformUrl(
      defaultUrl:
          "https://icecdn-19d24861e90342cc8decb03c24c8a419.msvdn.net/icecastRelay/S16355530/Q4zh3NTu28Rx/icecast",
    ),
    icon: "towerBroadcast",
    logo: "assets/images/default_stations/news.png",
    color: "0xff1976D2",
    category: "Italian",
  ),
  Station(
    id: 9,
    name: "Radio Kiss Kiss",
    genre: "Pop",
    url: _getPlatformUrl(defaultUrl: "https://kk.fluidstream.eu/kk_hits.mp3"),
    icon: "radio",
    logo: "assets/images/default_stations/pop.png",
    color: "0xff0288D1",
    category: "Italian",
  ),
  Station(
    id: 10,
    name: "Radio Capital",
    genre: "Pop",
    url: _getPlatformUrl(
      defaultUrl:
          "https://radiocapital-lh.akamaihd.net/i/RadioCapital_Live_1@196312/master.m3u8",
    ),
    icon: "radio",
    logo: "assets/images/default_stations/pop.png",
    color: "0xffE53935",
    category: "Italian",
  ),
  Station(
    id: 11,
    name: "Radio Monte Carlo",
    genre: "Pop",
    url: _getPlatformUrl(defaultUrl: "https://icy.unitedradio.it/RMC.mp3"),
    icon: "radio",
    logo: "assets/images/default_stations/pop.png",
    color: "0xff212121",
    category: "Italian",
  ),
  Station(
    id: 12,
    name: "Jazz Cafe",
    genre: StationGenre.jazz,
    url: _getPlatformUrl(defaultUrl: "http://jazz.streamr.ru/jazz-64.mp3"),
    icon: "saxophone",
    logo: "assets/images/default_stations/jazz.png",
    color: "0xffd63031",
    category: "International",
  ),
];

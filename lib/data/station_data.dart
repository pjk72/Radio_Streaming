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
  Station(
    id: 1,
    name: "Lofi Hip Hop",
    genre: StationGenre.lofi,
    url: _getPlatformUrl(defaultUrl: "https://stream.zeno.fm/0r0xa792kwzuv"),
    icon: "mugHot",
    logo: "assets/images/default_stations/lofi.png",
    color: "0xffe17055",
    category: "International",
  ),
  Station(
    id: 2,
    name: "Classical Masterpieces",
    genre: StationGenre.classical,
    url: _getPlatformUrl(
      defaultUrl: "https://live.musopen.org:8085/streamvbr0",
    ),
    icon: "violin",
    logo: "assets/images/default_stations/classical.png",
    color: "0xfffdcb6e",
    category: "International",
  ),
  Station(
    id: 3,
    name: "Deep House Lounge",
    genre: StationGenre.electronic,
    url: _getPlatformUrl(
      defaultUrl: "http://pulseedm.cdnstream1.com:8124/1373_128",
    ),
    icon: "headphones",
    logo: "assets/images/default_stations/electronic.png",
    color: "0xff0984e3",
    category: "International",
  ),
  Station(
    id: 4,
    name: "Jazz Cafe",
    genre: StationGenre.jazz,
    url: _getPlatformUrl(defaultUrl: "http://jazz.streamr.ru/jazz-64.mp3"),
    icon: "saxophone",
    logo: "assets/images/default_stations/jazz.png",
    color: "0xffd63031",
    category: "International",
  ),
  Station(
    id: 5,
    name: "Pop Hits",
    genre: StationGenre.pop,
    url: _getPlatformUrl(defaultUrl: "http://icecast.omroep.nl/3fm-bb-mp3"),
    icon: "microphone",
    logo: "assets/images/default_stations/pop.png",
    color: "0xffe84393",
    category: "International",
  ),
  Station(
    id: 6,
    name: "News (BBC)",
    genre: StationGenre.news,
    url: _getPlatformUrl(
      defaultUrl: "https://bbcwssc.ic.llnwd.net/stream/bbcwssc_mp1_ws-eieuk",
    ),
    icon: "newspaper",
    logo:
        "https://upload.wikimedia.org/wikipedia/commons/thumb/f/ff/BBC_World_Service_2022.svg/512px-BBC_World_Service_2022.svg.png",
    color: "0xff636e72",
    category: "International",
  ),
  // Italian
  Station(
    id: 7,
    name: "Radio 105",
    genre: "Pop",
    url: _getPlatformUrl(defaultUrl: "https://icy.unitedradio.it/Radio105.mp3"),
    icon: "radio",
    logo:
        "https://upload.wikimedia.org/wikipedia/commons/9/97/Radio_105_italy_2023.png",
    color: "0xffFBC02D",
    category: "Italian",
  ),
  Station(
    id: 8,
    name: "Radio Deejay",
    genre: "Pop | Italian",
    url: _getPlatformUrl(
      defaultUrl:
          "https://4c4b867c89244861ac216426883d1ad0.msvdn.net/radiodeejay/radiodeejay/master_ma.m3u8",
    ),
    icon: "radio",
    logo: "https://upload.wikimedia.org/wikipedia/commons/b/b5/Logo_DeeJay.png",
    color: "0xffD32F2F",
    category: "Italian",
  ),
  Station(
    id: 9,
    name: "Virgin Radio",
    genre: StationGenre.rock,
    url: _getPlatformUrl(defaultUrl: "https://icy.unitedradio.it/Virgin.mp3"),
    icon: "radio",
    logo: "https://upload.wikimedia.org/wikipedia/commons/d/d1/VirginRadio.png",
    color: "0xffB71C1C",
    category: "Italian",
  ),
  Station(
    id: 10,
    name: "R101",
    genre: "Pop",
    url: _getPlatformUrl(defaultUrl: "https://icy.unitedradio.it/R101.mp3"),
    icon: "radio",
    logo: "https://www.r101.it/images/logos/7/logo_black.jpg",
    color: "0xffE65100",
    category: "Italian",
  ),
  Station(
    id: 11,
    name: "RTL 102.5",
    genre: "Pop",
    url: _getPlatformUrl(
      defaultUrl:
          "https://dd782ed59e2a4e86aabf6fc508674b59.msvdn.net/live/S97044836/tbbP8T1ZRPBL/playlist_audio.m3u8",
    ),
    icon: "radio",
    logo:
        "https://upload.wikimedia.org/wikipedia/commons/thumb/4/4b/RTL_102.5_%28logo%29.png/800px-RTL_102.5_%28logo%29.png",
    color: "0xff000000",
    category: "Italian",
  ),
  Station(
    id: 12,
    name: "RDS",
    genre: "Pop",
    url: _getPlatformUrl(
      defaultUrl: "https://stream.rds.radio/audio/rds.stream_aac/playlist.m3u8",
    ),
    icon: "radio",
    logo:
        "https://upload.wikimedia.org/wikipedia/commons/thumb/e/ed/RDS_logo.svg/1200px-RDS_logo.svg.png",
    color: "0xffC2185B",
    category: "Italian",
  ),
  Station(
    id: 13,
    name: "Radio Italia",
    genre: StationGenre.italian,
    url: _getPlatformUrl(
      defaultUrl:
          "https://radioitaliasmi.akamaized.net/hls/live/2093120/RISMI/stream01/streamPlaylist.m3u8",
    ),
    icon: "radio",
    logo: "https://www.radioitalia.it//images/logo-radioitalia-200.png",
    color: "0xffE53935",
    category: "Italian",
  ),
  Station(
    id: 14,
    name: "RAI Radio 1",
    genre: "News",
    url: _getPlatformUrl(
      defaultUrl:
          "https://icecdn-19d24861e90342cc8decb03c24c8a419.msvdn.net/icecastRelay/S16355530/Q4zh3NTu28Rx/icecast",
    ),
    icon: "towerBroadcast",
    logo: "https://upload.wikimedia.org/wikipedia/it/9/93/RAI_radio1.png",
    color: "0xff1976D2",
    category: "Italian",
  ),
  Station(
    id: 15,
    name: "Radio Kiss Kiss",
    genre: "Pop",
    url: _getPlatformUrl(defaultUrl: "https://kk.fluidstream.eu/kk_hits.mp3"),
    icon: "radio",
    logo:
        "https://upload.wikimedia.org/wikipedia/commons/thumb/0/0e/Radio_Kiss_Kiss_logo.svg/1200px-Radio_Kiss_Kiss_logo.svg.png",
    color: "0xff0288D1",
    category: "Italian",
  ),
  Station(
    id: 16,
    name: "Radio Capital",
    genre: "Pop",
    url: _getPlatformUrl(
      defaultUrl:
          "https://radiocapital-lh.akamaihd.net/i/RadioCapital_Live_1@196312/master.m3u8",
    ),
    icon: "radio",
    logo:
        "https://upload.wikimedia.org/wikipedia/commons/thumb/2/23/Radio_Capital_logo.svg/1200px-Radio_Capital_logo.svg.png",
    color: "0xffE53935",
    category: "Italian",
  ),
  Station(
    id: 17,
    name: "Radio Monte Carlo",
    genre: "Pop",
    url: _getPlatformUrl(defaultUrl: "https://icy.unitedradio.it/RMC.mp3"),
    icon: "radio",
    logo:
        "https://upload.wikimedia.org/wikipedia/commons/thumb/6/69/Radio_Monte_Carlo_logo.svg/1200px-Radio_Monte_Carlo_logo.svg.png",
    color: "0xff212121",
    category: "Italian",
  ),
];

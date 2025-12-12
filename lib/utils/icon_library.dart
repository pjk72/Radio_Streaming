import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class IconLibrary {
  static final Map<String, IconData> icons = {
    // Audio / Radio
    'music': FontAwesomeIcons.music,
    'radio': FontAwesomeIcons.radio,
    'microphone': FontAwesomeIcons.microphone,
    'microphoneLines': FontAwesomeIcons.microphoneLines,
    'headphones': FontAwesomeIcons.headphones,
    'headphonesSimple': FontAwesomeIcons.headphonesSimple,
    'podcast': FontAwesomeIcons.podcast,
    'towerBroadcast': FontAwesomeIcons.towerBroadcast,
    'sliders': FontAwesomeIcons.sliders,
    'volumeHigh': FontAwesomeIcons.volumeHigh,
    'recordVinyl': FontAwesomeIcons.compactDisc,
    'guitar': FontAwesomeIcons.guitar,
    'drum': FontAwesomeIcons.drum,

    // Genres / Vibes
    'bolt': FontAwesomeIcons.bolt,
    'fire': FontAwesomeIcons.fire,
    'star': FontAwesomeIcons.star,
    'heart': FontAwesomeIcons.heart,
    'mugHot': FontAwesomeIcons.mugHot,
    'cloud': FontAwesomeIcons.cloud,
    'moon': FontAwesomeIcons.moon,
    'sun': FontAwesomeIcons.sun,
    'water': FontAwesomeIcons.water,
    'leaf': FontAwesomeIcons.leaf,
    'snowflake': FontAwesomeIcons.snowflake,
    'ghost': FontAwesomeIcons.ghost,
    'gamepad': FontAwesomeIcons.gamepad,
    'film': FontAwesomeIcons.film,
    'tv': FontAwesomeIcons.tv,
    'newspaper': FontAwesomeIcons.newspaper,
    'book': FontAwesomeIcons.book,
    'glasses': FontAwesomeIcons.glasses,
    'graduationCap': FontAwesomeIcons.graduationCap,

    // Places / Objects
    'house': FontAwesomeIcons.house,
    'car': FontAwesomeIcons.car,
    'train': FontAwesomeIcons.train,
    'plane': FontAwesomeIcons.plane,
    'globe': FontAwesomeIcons.globe,
    'earthAmericas': FontAwesomeIcons.earthAmericas,
    'earthEurope': FontAwesomeIcons.earthEurope,
    'city': FontAwesomeIcons.city,
    'church': FontAwesomeIcons.church,
    'mosque': FontAwesomeIcons.mosque,

    // Abstract
    'comments': FontAwesomeIcons.comments,
    'users': FontAwesomeIcons.users,
    'bell': FontAwesomeIcons.bell,
    'code': FontAwesomeIcons.code,
    'palette': FontAwesomeIcons.palette,
  };

  static IconData getIcon(String? name) {
    if (name == null || name.isEmpty) return FontAwesomeIcons.music;
    return icons[name] ??
        icons[name.replaceAll('fa-', '')] ??
        FontAwesomeIcons.music;
  }
}

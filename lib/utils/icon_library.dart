import 'package:flutter/material.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

class IconLibrary {
  static final Map<String, IconData> icons = {
    // Audio / Radio
    'music': FontAwesomeIcons.music.data,
    'radio': FontAwesomeIcons.radio.data,
    'microphone': FontAwesomeIcons.microphone.data,
    'microphoneLines': FontAwesomeIcons.microphoneLines.data,
    'headphones': FontAwesomeIcons.headphones.data,
    'headphonesSimple': FontAwesomeIcons.headphonesSimple.data,
    'podcast': FontAwesomeIcons.podcast.data,
    'towerBroadcast': FontAwesomeIcons.towerBroadcast.data,
    'sliders': FontAwesomeIcons.sliders.data,
    'volumeHigh': FontAwesomeIcons.volumeHigh.data,
    'recordVinyl': FontAwesomeIcons.compactDisc.data,
    'guitar': FontAwesomeIcons.guitar.data,
    'drum': FontAwesomeIcons.drum.data,

    // Genres / Vibes
    'bolt': FontAwesomeIcons.bolt.data,
    'fire': FontAwesomeIcons.fire.data,
    'star': FontAwesomeIcons.star.data,
    'heart': FontAwesomeIcons.heart.data,
    'mugHot': FontAwesomeIcons.mugHot.data,
    'cloud': FontAwesomeIcons.cloud.data,
    'moon': FontAwesomeIcons.moon.data,
    'sun': FontAwesomeIcons.sun.data,
    'water': FontAwesomeIcons.water.data,
    'leaf': FontAwesomeIcons.leaf.data,
    'snowflake': FontAwesomeIcons.snowflake.data,
    'ghost': FontAwesomeIcons.ghost.data,
    'gamepad': FontAwesomeIcons.gamepad.data,
    'film': FontAwesomeIcons.film.data,
    'tv': FontAwesomeIcons.tv.data,
    'newspaper': FontAwesomeIcons.newspaper.data,
    'book': FontAwesomeIcons.book.data,
    'glasses': FontAwesomeIcons.glasses.data,
    'graduationCap': FontAwesomeIcons.graduationCap.data,

    // Places / Objects
    'house': FontAwesomeIcons.house.data,
    'car': FontAwesomeIcons.car.data,
    'train': FontAwesomeIcons.train.data,
    'plane': FontAwesomeIcons.plane.data,
    'globe': FontAwesomeIcons.globe.data,
    'earthAmericas': FontAwesomeIcons.earthAmericas.data,
    'earthEurope': FontAwesomeIcons.earthEurope.data,
    'city': FontAwesomeIcons.city.data,
    'church': FontAwesomeIcons.church.data,
    'mosque': FontAwesomeIcons.mosque.data,

    // Abstract
    'comments': FontAwesomeIcons.comments.data,
    'users': FontAwesomeIcons.users.data,
    'bell': FontAwesomeIcons.bell.data,
    'code': FontAwesomeIcons.code.data,
    'palette': FontAwesomeIcons.palette.data,
  };

  static IconData getIcon(String? name) {
    if (name == null || name.isEmpty) return FontAwesomeIcons.music.data;
    return icons[name] ??
        icons[name.replaceAll('fa-', '')] ??
        FontAwesomeIcons.music.data;
  }
}

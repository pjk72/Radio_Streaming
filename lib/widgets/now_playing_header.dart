import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

import '../utils/icon_library.dart';

import '../providers/radio_provider.dart';
import '../providers/language_provider.dart';
import '../screens/artist_details_screen.dart';
import 'realistic_visualizer.dart';

import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';

import 'dart:io';
import 'dart:typed_data';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import '../services/recognition_api_service.dart';
import '../models/saved_song.dart';
import '../utils/glass_utils.dart';
import '../services/entitlement_service.dart';
import '../services/interstitial_ad_service.dart';
import 'advanced_recognition_visualizer.dart';

class NowPlayingHeader extends StatefulWidget {
  final double height;
  final double minHeight;
  final double maxHeight;
  final double topPadding;

  const NowPlayingHeader({
    super.key,
    required this.height,
    this.minHeight = 110,
    this.maxHeight = 200,
    this.topPadding = 0,
  });

  @override
  State<NowPlayingHeader> createState() => _NowPlayingHeaderState();
}

class _NowPlayingHeaderState extends State<NowPlayingHeader> {
  String? _fetchedArtistImage;
  String? _lastArtistChecked;

  bool _isListening = false;
  bool _isAnalyzing = false;
  final AudioRecorder _record = AudioRecorder();

  @override
  void dispose() {
    _record.dispose();
    super.dispose();
  }

  // Removed redundant lifecycle methods as we handle check in build

  Future<void> _fetchArtistImage(String artistName) async {
    try {
      // Logic copied from ArtistDetailsScreen
      final uri = Uri.parse(
        "https://api.deezer.com/search/artist?q=${Uri.encodeComponent(artistName)}&limit=1",
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        if (json['data'] != null && (json['data'] as List).isNotEmpty) {
          String? picture =
              json['data'][0]['picture_xl'] ??
              json['data'][0]['picture_big'] ??
              json['data'][0]['picture_medium'];

          if (picture != null && mounted) {
            // Only update if it matches the currently checked artist to avoid race conditions
            if (_lastArtistChecked == artistName) {
              setState(() {
                _fetchedArtistImage = picture;
              });

              // Push to provider so StationCard can see it too
              Provider.of<RadioProvider>(
                context,
                listen: false,
              ).setArtistImage(picture);
              return;
            }
          }
        }
      }

      // If we reach here, we found nothing or valid response but no image
      if (mounted && _lastArtistChecked == artistName) {
        setState(() {
          _fetchedArtistImage = null; // Clear if not found
        });
      }
    } catch (e) {
      debugPrint("Error fetching artist image in header: \$e");
      if (mounted && _lastArtistChecked == artistName) {
        setState(() {
          _fetchedArtistImage = null; // Clear on error
        });
      }
    }
  }

  void _startListening() async {
    final lang = Provider.of<LanguageProvider>(context, listen: false);

    if (RecognitionApiService.isShazamDisabled.value) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(lang.translate('music_recognition_disabled_momentarily')),
            backgroundColor: Colors.redAccent,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
      return;
    }

    bool hasPermission = await _record.hasPermission();

    if (!hasPermission) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              lang.translate('shazam_mic_denied'),
            ),
          ),
        );
      }
      return;
    }

    if (hasPermission) {
      setState(() => _isListening = true);

      final Directory tempDir = await getTemporaryDirectory();
      final String tempPath = '${tempDir.path}/shazam_temp.m4a';

      try {
        await _record.start(
          const RecordConfig(encoder: AudioEncoder.aacLc),
          path: tempPath,
        );

        // Fase 1: Registrazione (5 secondi) - Animazione note musicali
        await Future.delayed(const Duration(seconds: 5));

        if (mounted) setState(() => _isAnalyzing = true);

        final path = await _record.stop();
        
        if (path != null) {
          final File audioFile = File(path);
          final Uint8List audioBytes = await audioFile.readAsBytes();

          if (audioBytes.isNotEmpty && mounted) {
            // Fase 2: Analisi (Animazione scanner digitale)
            final result = await RecognitionApiService().identifyFromAudioBytes(
              audioBytes,
            );

            // Una volta finito, il pulsante torna al suo posto
            if (mounted) {
              setState(() {
                _isListening = false;
                _isAnalyzing = false;
              });
            }

            if (result != null && result['track'] != null) {
              // Fase 3: Risultato (Sfondo sfocato e popup glass)
              _showShazamResultPopup(result['track']);
            } else {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(lang.translate('song_not_recognized'))),
                );
              }
            }
          } else {
            if (mounted) setState(() => _isListening = false);
          }
        } else {
          if (mounted) setState(() => _isListening = false);
        }
      } catch (e) {
        if (mounted) {
            setState(() => _isListening = false);
            ScaffoldMessenger.of(context).showSnackBar(
               SnackBar(content: Text(lang.translate('mic_error').replaceAll('{0}', e.toString()))),
            );
        }
        debugPrint('Record error: $e');
      }
    }
  }

  void _showShazamResultPopup(Map<String, dynamic> trackData) {
    if (!mounted) return;
    final lang = Provider.of<LanguageProvider>(context, listen: false);
    
    String title = trackData['title'] ?? lang.translate('unknown');
    String artist = trackData['subtitle'] ?? lang.translate('unknown');
    String cover = '';
    if (trackData['images'] != null) {
      cover = trackData['images']['coverart'] ?? trackData['images']['background'] ?? '';
    }
    
    String album = '';
    String year = '';
    String genre = '';
    
    if (trackData['sections'] != null) {
      for (var section in trackData['sections']) {
        if (section['type'] == 'SONG') {
          for (var meta in section['metadata'] ?? []) {
            if (meta['title'] == 'Album') album = meta['text'];
            if (meta['title'] == 'Released') year = meta['text'];
            if (meta['title'] == 'Genre') genre = meta['text'];
          }
        }
      }
    }
    if (genre.isEmpty && trackData['genres'] != null && trackData['genres']['primary'] != null) {
      genre = trackData['genres']['primary'];
    }

    GlassUtils.showGlassDialog(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setStateDialog) {
            final provider = Provider.of<RadioProvider>(context, listen: false);
            
            bool isFav = false;
            try {
              isFav = provider.playlists.any((playlist) => 
                  playlist.songs.any((s) => s.title == title && s.artist == artist)
              );
            } catch (e) {
              isFav = false;
            }

            return AlertDialog(
              backgroundColor: Theme.of(context).cardColor.withValues(alpha: 0.15),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.1), width: 1),
              ),
              contentPadding: const EdgeInsets.all(24),
              elevation: 0,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (cover.isNotEmpty)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20.0),
                      child: CachedNetworkImage(
                        imageUrl: cover,
                        height: 220,
                        width: 220,
                        fit: BoxFit.cover,
                      ),
                    ),
                  const SizedBox(height: 16),
                  Text(
                    title,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 20,
                      color: Colors.white,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    artist,
                    style: const TextStyle(fontSize: 16, color: Colors.white70),
                    textAlign: TextAlign.center,
                  ),
                  
                  if (album.isNotEmpty || year.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.3), 
                        borderRadius: BorderRadius.circular(12)
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (album.isNotEmpty) Text("${lang.translate('genre') == 'Genre' ? 'Album' : lang.translate('label_album')}: $album", style: const TextStyle(fontSize: 13, color: Colors.white60), textAlign: TextAlign.center),
                          if (year.isNotEmpty) Text("${lang.translate('year')}: $year", style: const TextStyle(fontSize: 13, color: Colors.white60), textAlign: TextAlign.center),
                        ]
                      )
                    )
                  ],

                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      IconButton(
                        iconSize: 32,
                        icon: Icon(
                          isFav ? Icons.favorite : Icons.favorite_border, 
                          color: isFav ? Colors.redAccent : Colors.white70
                        ),
                        tooltip: lang.translate('add_to_playlist'),
                        onPressed: () async {
                          if (isFav) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(lang.translate('already_in_favorites'))),
                            );
                            return;
                          }
                          
                          final song = SavedSong(
                            id: DateTime.now().millisecondsSinceEpoch.toString(),
                            title: title,
                            artist: artist,
                            album: album.isNotEmpty ? album : 'Shazam',
                            artUri: cover,
                            dateAdded: DateTime.now(),
                          );
                          await provider.bulkToggleFavoriteSongs([song], true);
                          setStateDialog(() { isFav = true; });
                          
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                               SnackBar(content: Text(lang.translate('added_to_favorites'))),
                            );
                          }
                        },
                      ),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.1),
                          foregroundColor: Colors.white,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                          ),
                        ),
                        onPressed: () {
                          Navigator.of(context).pop();
                          InterstitialAdService().showAd();
                        },
                        child: Text(lang.translate('close')),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    // Calculate scale factor (0.0 to 1.0)
    // t goes from 0.0 (at minHeight) to 1.0 (at maxHeight)
    // Adjust range to account for the fact that minHeight and maxHeight MIGHT include topPadding
    // But height passes the actual height.
    final double range = widget.maxHeight - widget.minHeight;
    final double t = range > 0
        ? ((widget.height - widget.minHeight) / range).clamp(0.0, 1.0)
        : 1.0;

    final double screenWidth = MediaQuery.of(context).size.width;
    final provider = Provider.of<RadioProvider>(context);
    final lang = Provider.of<LanguageProvider>(context);
    final station = provider.currentStation;
    final artist = provider.currentArtist;

    // Check for artist change
    if (artist != _lastArtistChecked) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          // Update state to trigger fetch but KEEP old image to prevent flashing
          setState(() {
            _lastArtistChecked = artist;

            // Check placeholder logic
            final isPlaceholder =
                (station != null &&
                (artist == station.genre || artist == station.name));

            if (artist.isNotEmpty &&
                artist !=
                    Provider.of<LanguageProvider>(
                      context,
                      listen: false,
                    ).translate('unknown_artist') &&
                !isPlaceholder) {
              _fetchArtistImage(artist);
            } else {
              // If valid artist is gone (e.g. unknown), clear immediately
              _fetchedArtistImage = null;
            }
          });
        }
      });
    }

    // PRIORITY: Local Fetch -> Provider Artist Image -> Station Logo
    // NOTE: currentAlbumArt intentionally excluded to avoid the brief album-cover
    // flash before the artist photo loads. Falls back directly to station logo.
    final String? imageUrl = station != null
        ? (_fetchedArtistImage ?? provider.currentArtistImage ?? station.logo)
        : null;

    // Logic to determine if we are showing a specific image (Artist/Album) or just the default Station Logo
    // We consider it "Enriched" if we have a specific image AND it differs from the fallback station logo.
    final bool hasEnrichedImage =
        (imageUrl != null && station != null && imageUrl != station.logo);

    final bool isLinkEnabled =
        station != null &&
        provider.currentArtist.isNotEmpty &&
        provider.currentArtist != lang.translate('unknown_artist') &&
        provider.currentTrack != lang.translate('live_broadcast') &&
        hasEnrichedImage;

    final double titleSize = 16.0 + (10.0 * t); // 16 to 30
    final double trackSize = 12.0 + (8.0 * t); // 12 to 20
    final double stationSize = 18.0 + (18.0 * t); // 18 to 36

    // Animate border radius to 0 when nearing collapsed state
    final double borderRadius = 24.0 * t;

    // Interpolate top padding:
    // When t=1 (Expanded): padding is standard (16.0).
    // When t=0 (Collapsed): padding is standard + safeArea (16.0 + topPadding).
    // Adding extra buffer to be safe.
    final double dynamicTopPadding =
        (16.0 * t) + ((widget.topPadding + 10.0) * (1.0 - t));

    return Stack(
      children: [
        MouseRegion(
          cursor: isLinkEnabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          child: GestureDetector(
            onTap: isLinkEnabled
                ? () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => ArtistDetailsScreen(
                          artistName: provider.currentArtist,
                          artistImage:
                              _fetchedArtistImage ??
                              provider.currentArtistImage,
                          genre: station.genre,
                        ),
                      ),
                    );
                  }
                : null,
            child: Container(
              width: double.infinity,
              height: widget.height,
              margin: EdgeInsets.only(
                bottom: 24.0 * t,
                left: 20.0 * t,
                right: 20.0 * t,
              ),
              decoration: BoxDecoration(
                // Increase opacity when collapsed (t -> 0) to prevent background content mix
                // Increase opacity when collapsed (t -> 0) to prevent background content mix
                color:
                    Theme.of(context).appBarTheme.backgroundColor ??
                    Theme.of(
                      context,
                    ).scaffoldBackgroundColor.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(borderRadius),
                border: Border.all(
                  color: Colors.white.withValues(
                    alpha: 0.1 * t,
                  ), // Fade border too
                ),
                boxShadow: [
                  if (t > 0.1) // Remove shadow when collapsed flat
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.2),
                      blurRadius: 20,
                      offset: const Offset(0, 10),
                    ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(borderRadius),
                child: Stack(
                  children: [
                    // 1. Blurred Background
                    if (imageUrl != null)
                      Positioned.fill(
                        child: ImageFiltered(
                          imageFilter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                          child: _buildImage(
                            imageUrl,
                            fit: BoxFit.cover,
                            color: Colors.black.withValues(alpha: 0.3),
                            colorBlendMode: BlendMode.darken,
                            fallbackUrl: station?.logo,
                          ),
                        ),
                      ),

                    // 2. Right-Aligned Image with Fade (blends into background)
                    // Resize logic: width factor reduces as t -> 0
                    if (imageUrl != null)
                      Positioned(
                        top:
                            widget.topPadding *
                            (1.0 -
                                t), // Slide down to respect safe area when collapsed
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: AspectRatio(
                            aspectRatio: 1.8,
                            child: ShaderMask(
                              shaderCallback: (rect) {
                                return const LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  stops: [0.6, 1.0],
                                  colors: [Colors.white, Colors.transparent],
                                ).createShader(rect);
                              },
                              blendMode: BlendMode.dstIn,
                              child: ShaderMask(
                                shaderCallback: (rect) {
                                  return const LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    stops: [0.0, 0.7], // Soft blend
                                    colors: [Colors.transparent, Colors.white],
                                  ).createShader(rect);
                                },
                                blendMode: BlendMode.dstIn,
                                child: _buildImage(
                                  imageUrl,
                                  fit: BoxFit.cover,
                                  alignment:
                                      Alignment.topCenter, // Focus on face
                                  fallbackUrl: station?.logo,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                    // Gradient Overlay for readability
                    if (t > 0.1)
                      Positioned.fill(
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.bottomLeft,
                              end: Alignment.topRight,
                              colors: [
                                station != null
                                    ? Color(
                                        int.parse(station.color),
                                      ).withValues(alpha: 0.4)
                                    : Theme.of(context).primaryColor.withValues(
                                        alpha: 0.2,
                                      ), // Use theme primary for default tint
                                Colors.black.withValues(
                                  alpha:
                                      Theme.of(context).brightness ==
                                          Brightness.light
                                      ? 0.7
                                      : 0.3,
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),


                    // 4. Content
                    Positioned.fill(
                      child: Padding(
                        padding: EdgeInsets.only(
                          left: 24.0,
                          right: 24.0,
                          bottom: 5.0,
                          top: dynamicTopPadding,
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            return SingleChildScrollView(
                              physics: const NeverScrollableScrollPhysics(),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  minHeight: constraints.maxHeight,
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.start,
                                  children: [
                                    if (t < 0.3) const SizedBox(height: 0),

                                    if (station == null) ...[
                                      SizedBox(
                                        height: 40 * t,
                                      ), // spacer replacement
                                      Row(
                                        children: [
                                          Container(
                                            padding: const EdgeInsets.all(16),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context)
                                                  .primaryColor
                                                  .withValues(alpha: 0.2),
                                              shape: BoxShape.circle,
                                            ),
                                            child: Icon(
                                              Icons.radio,
                                              color: Theme.of(
                                                context,
                                              ).primaryColor,
                                              size: 32,
                                            ),
                                          ),
                                          const SizedBox(width: 16),
                                          Text(
                                            lang.translate('discover_radio'),
                                            style: Theme.of(context)
                                                .textTheme
                                                .headlineSmall
                                                ?.copyWith(
                                                  fontWeight: FontWeight.bold,
                                                  color: Theme.of(context)
                                                      .textTheme
                                                      .headlineSmall
                                                      ?.color,
                                                ),
                                          ),
                                        ],
                                      ),
                                      if (t > 0.2) ...[
                                        const SizedBox(height: 8),
                                        Text(
                                          lang.translate('discover_radio_desc'),
                                          style: const TextStyle(
                                            fontSize: 14,
                                            color: Colors.white70,
                                          ),
                                        ),
                                      ],
                                    ] else ...[
                                      // Check if we have valid artist info to highlight
                                      if (provider.currentArtist.isNotEmpty &&
                                          provider.currentArtist !=
                                              lang.translate(
                                                'unknown_artist',
                                              ) &&
                                          provider.currentTrack !=
                                              lang.translate(
                                                'live_broadcast',
                                              )) ...[
                                        if (t > 0.3)
                                          SizedBox(
                                            height: 20 * t,
                                          ), // spacer replacement
                                        // ARTIST HIGHLIGHT MODE
                                        Text(
                                          provider.currentTrack
                                              .replaceFirst("⬇️ ", "")
                                              .replaceFirst("📱 ", "")
                                              .toUpperCase(),
                                          style: TextStyle(
                                            fontSize: titleSize,
                                            fontWeight: FontWeight.w900,
                                            letterSpacing: -1.0,
                                            color: (station.id > 0)
                                                ? Color(
                                                    int.parse(station.color),
                                                  )
                                                : Theme.of(
                                                    context,
                                                  ).primaryColor,
                                            height: 1.0,
                                            shadows: const [
                                              Shadow(
                                                blurRadius: 15.0,
                                                color: Colors.black,
                                                offset: Offset(2, 2),
                                              ),
                                            ],
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        SizedBox(height: (4.0 * t)),
                                        Text.rich(
                                          TextSpan(
                                            text: provider.currentArtist,
                                            style: TextStyle(
                                              fontSize: trackSize,
                                              fontWeight: FontWeight.w300,
                                              color: Colors.white,
                                            ),
                                            children: [
                                              if (provider.currentReleaseDate !=
                                                      null &&
                                                  provider
                                                          .currentReleaseDate!
                                                          .length >=
                                                      4)
                                                TextSpan(
                                                  text:
                                                      "   ${provider.currentReleaseDate!.substring(0, 4)}",
                                                  style: const TextStyle(
                                                    fontSize: 14,
                                                    color: Colors.white38,
                                                    fontWeight:
                                                        FontWeight.normal,
                                                  ),
                                                ),
                                            ],
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),

                                        // Hide secondary info when very collapsed to save space
                                        if (t > 0.3) ...[
                                          SizedBox(
                                            height: 20 * t,
                                          ), // spacer replacement
                                          Row(
                                            children: [
                                              Icon(
                                                Icons.radio,
                                                size: 12.0,
                                                color: Colors.white60,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                lang
                                                    .translate('on_station')
                                                    .replaceAll(
                                                      '{0}',
                                                      station.name
                                                          .toUpperCase(),
                                                    ),
                                                style: const TextStyle(
                                                  fontSize: 12.0,
                                                  color: Colors.white60,
                                                  fontWeight: FontWeight.bold,
                                                  letterSpacing: 1.0,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ] else ...[
                                          // When collapsed, just use a small spacer so content is centered vertically
                                          const SizedBox(height: 8),
                                        ],

                                        if (t >
                                            0.1) // Keep NOW PLAYING tag mostly visible but tighter layout
                                          SizedBox(height: 2.0 * t),

                                        Row(
                                          children: [
                                            AnimatedOpacity(
                                              duration: const Duration(
                                                milliseconds: 300,
                                              ),
                                              opacity: provider.isPlaying
                                                  ? 1.0
                                                  : 0.0,
                                              child: Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 6,
                                                      vertical: 2,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: Colors.white
                                                      .withValues(alpha: 0.1),
                                                  borderRadius:
                                                      BorderRadius.circular(4),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Padding(
                                                      padding:
                                                          const EdgeInsets.only(
                                                            right: 4,
                                                          ),
                                                      child:
                                                          RealisticVisualizer(
                                                            color:
                                                                Colors.white70,
                                                            volume:
                                                                provider.volume,
                                                          ),
                                                    ),
                                                    Text(
                                                      lang.translate(
                                                        'now_playing',
                                                      ),
                                                      style: const TextStyle(
                                                        fontSize: 9,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        letterSpacing: 0.5,
                                                        color: Colors.white70,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                            const Spacer(),
                                          ],
                                        ),
                                      ] else ...[
                                        // STATION DEFAULT MODE
                                        SizedBox(
                                          height: 40 * t,
                                        ), // spacer replacement
                                        Text(
                                          station.name,
                                          style: TextStyle(
                                            fontSize: stationSize,
                                            fontWeight: FontWeight.w800,
                                            letterSpacing: -1.0,
                                            color: (station.id > 0)
                                                ? Color(
                                                    int.parse(station.color),
                                                  )
                                                : Theme.of(
                                                    context,
                                                  ).primaryColor,
                                            height: 1.0,
                                          ),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        // Hide genre when very collapsed to save space or scale it down
                                        if (t > 0.1) ...[
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              FaIcon(
                                                IconLibrary.getIcon(
                                                  station.icon,
                                                ),
                                                size: trackSize, // Scale icon
                                                color: Colors.white70,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                station.genre,
                                                style: TextStyle(
                                                  fontSize:
                                                      trackSize, // Scale text
                                                  color: Colors.white70,
                                                  fontWeight: FontWeight.w500,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ] else
                                          const SizedBox(height: 4),
                                        SizedBox(height: 4.0 + (2.0 * t)),
                                        AnimatedOpacity(
                                          duration: const Duration(
                                            milliseconds: 300,
                                          ),
                                          opacity: provider.isPlaying
                                              ? 1.0
                                              : 0.0,
                                          child: Container(
                                            height:
                                                32, // Match height of icon row in artist mode roughly
                                            alignment: Alignment.centerLeft,
                                            child: Row(
                                              children: [
                                                Container(
                                                  padding:
                                                      const EdgeInsets.symmetric(
                                                        horizontal: 6,
                                                        vertical: 2,
                                                      ),
                                                  decoration: BoxDecoration(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.1),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          4,
                                                        ),
                                                  ),
                                                  child: Row(
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Padding(
                                                        padding:
                                                            const EdgeInsets.only(
                                                              right: 4,
                                                            ),
                                                        child:
                                                            RealisticVisualizer(
                                                              color: Colors
                                                                  .white70,
                                                              volume: provider
                                                                  .volume,
                                                            ),
                                                      ),
                                                      Text(
                                                        lang.translate(
                                                          'now_playing',
                                                        ),
                                                        style: TextStyle(
                                                          fontSize: 9,
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          letterSpacing: 0.5,
                                                          color: Colors.white70,
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        if (_isListening)
          Positioned.fill(
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.0, end: 1.0),
              duration: const Duration(milliseconds: 300),
              builder: (context, value, child) {
                return BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 5 * value, sigmaY: 5 * value),
                  child: Container(
                    color: Colors.black.withValues(alpha: 0.3 * value),
                  ),
                );
              },
            ),
          ),

        if (Provider.of<EntitlementService>(context).isFeatureEnabled('external_song_recognition'))
          ValueListenableBuilder<bool>(
            valueListenable: RecognitionApiService.isShazamDisabled,
            builder: (context, isShazamDisabled, child) {
              return AnimatedPositioned(
                duration: const Duration(milliseconds: 400),
                curve: Curves.easeInOutCirc,
                top: _isListening
                    ? (widget.height / 2) - 40 // Centrato verticalmente nella card
                    : (widget.topPadding * (1.0 - t)) + 8.0,
                right: _isListening
                    ? (screenWidth / 2) - 40 // Centrato orizzontalmente
                    : (20.0 * t) + 8.0,
                child: Opacity(
                  opacity: _isListening ? 1.0 : (isShazamDisabled ? 0.3 : 0.3 + (0.7 * t)),
                  child: Transform.scale(
                    scale: _isListening ? 2.5 : 0.8 + (0.4 * t),
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        decoration: BoxDecoration(
                          color: _isListening
                              ? const Color(0xFF0088FF)
                              : (isShazamDisabled ? Colors.grey : const Color(0xFF0088FF)).withValues(alpha: 0.8 * (1.0 - (t * 0.5))),
                          shape: BoxShape.circle,
                          boxShadow: [
                            if (!isShazamDisabled && (t > 0.5 || _isListening))
                              BoxShadow(
                                color: const Color(0xFF0088FF).withValues(alpha: _isListening ? 0.4 : 0.3),
                                blurRadius: _isListening ? 30 : 12,
                                spreadRadius: _isListening ? 10 : 2,
                              ),
                          ],
                        ),
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          icon: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 300),
                            child: _isListening
                                ? SizedBox(
                                    width: 80,
                                    height: 80,
                                    child: Center(
                                      child: AdvancedRecognitionVisualizer(
                                        isAnalyzing: _isAnalyzing,
                                        color: Colors.white,
                                      ),
                                    ),
                                  )
                                : Icon(
                                    Icons.track_changes,
                                    color: isShazamDisabled ? Colors.white54 : Colors.white,
                                    size: 26,
                                  ),
                          ),
                          tooltip: isShazamDisabled ? lang.translate('music_recognition_disabled') : lang.translate('music_recognition'),
                          onPressed: _isListening ? null : _startListening,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _buildImage(
    String url, {
    BoxFit? fit,
    Color? color,
    BlendMode? colorBlendMode,
    Alignment? alignment,
    String? fallbackUrl, // Station logo fallback if the main image fails
  }) {
    if (url.startsWith('assets/')) {
      return Image.asset(
        url,
        fit: fit,
        color: color,
        colorBlendMode: colorBlendMode,
        alignment: alignment ?? Alignment.center,
      );
    } else {
      return CachedNetworkImage(
        imageUrl: url,
        fit: fit,
        color: color,
        colorBlendMode: colorBlendMode,
        alignment: alignment ?? Alignment.center,
        fadeInDuration: const Duration(milliseconds: 300),
        useOldImageOnUrlChange: true, // Reduce flickering
        memCacheWidth: 1024,
        maxWidthDiskCache: 1024,
        // If the main image (artist/album art) fails, fall back to station logo
        errorWidget: fallbackUrl != null && fallbackUrl != url
            ? (context, url, error) => CachedNetworkImage(
                imageUrl: fallbackUrl,
                fit: fit,
                color: color,
                colorBlendMode: colorBlendMode,
                alignment: alignment ?? Alignment.center,
                fadeInDuration: const Duration(milliseconds: 200),
                memCacheWidth: 512,
                maxWidthDiskCache: 512,
              )
            : null,
      );
    }
  }
}

class NowPlayingHeaderDelegate extends SliverPersistentHeaderDelegate {
  final double minHeight;
  final double maxHeight;
  final double topPadding;

  NowPlayingHeaderDelegate({
    this.minHeight = 100,
    this.maxHeight = 200,
    this.topPadding = 0.0,
  });

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // Current width/height
    final double currentHeight = (maxHeight - shrinkOffset).clamp(
      minHeight,
      maxHeight,
    );

    return OverflowBox(
      minHeight: minHeight,
      maxHeight: maxHeight,
      child: Align(
        alignment: Alignment.topCenter,
        // Pass topPadding explicitly
        child: NowPlayingHeader(
          height: currentHeight,
          minHeight: minHeight,
          maxHeight: maxHeight,
          topPadding: topPadding,
        ),
      ),
    );
  }

  @override
  double get maxExtent => maxHeight;

  @override
  double get minExtent => minHeight;

  @override
  bool shouldRebuild(covariant NowPlayingHeaderDelegate oldDelegate) {
    return maxHeight != oldDelegate.maxHeight ||
        minHeight != oldDelegate.minHeight ||
        topPadding != oldDelegate.topPadding;
  }
}

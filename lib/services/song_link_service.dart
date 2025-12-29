import 'dart:convert';
import 'package:http/http.dart' as http;

class SongLinkService {
  static const String _baseUrl = 'https://api.song.link/v1-alpha.1/links';

  String _lastRawJson = "";
  String get lastRawJson => _lastRawJson;

  Future<Map<String, String>> fetchLinks({
    String? spotifyId,
    String? url,
    String countryCode = 'IT',
  }) async {
    _lastRawJson = ""; // Reset

    String queryUrl;

    if (spotifyId != null) {
      // Use URI format as requested by user example
      queryUrl = 'spotify:track:$spotifyId';
    } else if (url != null) {
      queryUrl = url;
    } else {
      return {};
    }

    final uri = Uri.parse(
      '$_baseUrl?url=${Uri.encodeComponent(queryUrl)}&userCountry=$countryCode',
    );

    // DEBUG: Store request URL first
    print('SONG_LINK_REQ: $uri');
    _lastRawJson = "Song Link API Log\n\nREQUEST: $uri\n\nRESPONSE:\n";

    final Map<String, String> result = {};

    try {
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        _lastRawJson += response.body; // Append raw response
        final json = jsonDecode(response.body);
        final links = json['linksByPlatform'] as Map<String, dynamic>?;

        if (links != null) {
          // Attempt to extract thumbnail
          try {
            // SongLink usually provides entitiesByUniqueId.
            // We need to find a valid entity to get the thumbnail.
            // Usually we can trust the 'spotify' or 'google' or 'appleMusic' entry in linksByPlatform
            // to have an 'entityUniqueId'.
            String? entityId;
            if (links.containsKey('spotify')) {
              entityId = links['spotify']['entityUniqueId'];
            } else if (links.containsKey('appleMusic')) {
              entityId = links['appleMusic']['entityUniqueId'];
            } else if (links.containsKey('youtube')) {
              entityId = links['youtube']['entityUniqueId'];
            }

            // Or use the top-level entityUniqueId if available (depends on API version/response type)
            if (entityId == null && json.containsKey('entityUniqueId')) {
              entityId = json['entityUniqueId'];
            }

            if (entityId != null) {
              final entities = json['entitiesByUniqueId'];
              if (entities != null && entities[entityId] != null) {
                final entity = entities[entityId];
                final thumb = entity['thumbnailUrl'];
                if (thumb != null) {
                  result['thumbnailUrl'] = thumb;
                }
                // Also try to get artist image? Odesli usually only gives album art.
              }
            }
          } catch (e) {
            print("Error extracting thumbnail: $e");
          }

          // Spotify
          if (links.containsKey('spotify')) {
            final data = links['spotify'];
            result['spotify'] = data['nativeAppUriMobile'] ?? data['url'];
          }

          // Apple Music
          if (links.containsKey('appleMusic')) {
            final data = links['appleMusic'];
            result['appleMusic'] = data['url'] ?? data['nativeAppUriMobile'];
          }

          // YouTube
          if (links.containsKey('youtube')) {
            final data = links['youtube'];
            result['youtube'] = data['url'] ?? data['nativeAppUriMobile'];
          }

          // YouTube Music
          if (links.containsKey('youtubeMusic')) {
            final data = links['youtubeMusic'];
            result['youtubeMusic'] = data['nativeAppUriMobile'] ?? data['url'];
          }

          // Deezer
          if (links.containsKey('deezer')) {
            final data = links['deezer'];
            result['deezer'] = data['nativeAppUriMobile'] ?? data['url'];
          }

          // Tidal
          if (links.containsKey('tidal')) {
            final data = links['tidal'];
            result['tidal'] = data['nativeAppUriMobile'] ?? data['url'];
          }

          // Amazon Music
          if (links.containsKey('amazonMusic')) {
            final data = links['amazonMusic'];
            result['amazonMusic'] = data['nativeAppUriMobile'] ?? data['url'];
          }

          // Napster
          if (links.containsKey('napster')) {
            final data = links['napster'];
            result['napster'] = data['nativeAppUriMobile'] ?? data['url'];
          }
        }
      } else {
        _lastRawJson += "API Error ${response.statusCode}: ${response.body}";
        throw Exception("API Error ${response.statusCode}: ${response.body}");
      }
    } catch (e) {
      if (!_lastRawJson.contains("API Error")) {
        _lastRawJson += "Network/Parse Error: $e";
      }
      throw Exception("Network/Parse Error: $e");
    }

    return result;
  }
}

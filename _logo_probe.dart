import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:http/http.dart' as http;
import 'package:image/image.dart' as img;

const Set<String> _logoStopWords = {
  'radio', 'fm', 'am', 'live', 'online', 'stream', 'streaming', 'station',
  'the', 'official', 'web', 'hd', 'hq', 'music',
};

const Map<String, String> _logoDiacritics = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a',
  'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e',
  'ì': 'i', 'í': 'i', 'î': 'i', 'ï': 'i',
  'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', 'ö': 'o', 'ø': 'o',
  'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u',
  'ç': 'c', 'ñ': 'n', 'ý': 'y', 'ÿ': 'y', 'ß': 'ss', 'æ': 'ae', 'œ': 'oe',
};

const Map<String, String> _logoHttpHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  'Accept':
      'text/html,application/xhtml+xml,image/avif,image/webp,'
      'image/png,image/*;q=0.9,*/*;q=0.8',
  'Accept-Language': 'en-US,en;q=0.9',
};

const Set<String> _streamProviderHosts = {
  'radio-browser.info', 'zeno.fm', 'radio.co', 'streamguys.com',
  'shoutcast.com', 'radionomy.com', 'live365.com', 'securenetsystems.net',
  'spacial.com', 'listen2myradio.com', 'myradiostream.com', 'cristalhost.com',
  'streamerr.net',
};

const Set<String> _aggregatorHosts = {
  'onlineradiobox.com', 'streema.com', 'tunein.com', 'radio.it',
  'radioguide.fm', 'streamingradioguide.com', 'facebook.com', 'instagram.com',
  'twitter.com', 'x.com', 'youtube.com', 'tiktok.com', 'linkedin.com',
  'linktr.ee', 'sites.google.com',
};

String _normalizeStationName(String value) {
  var text = value.toLowerCase();
  _logoDiacritics.forEach((from, to) => text = text.replaceAll(from, to));
  text = text.replaceAll(
    RegExp(r"[\s\-_.,/\\|:;!?()\[\]{}'’“”«»&+#@*~^%$=<>]+"),
    ' ',
  );
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

List<String> _stationTokens(String normalized) => normalized
    .split(' ')
    .where((t) => t.isNotEmpty && !_logoStopWords.contains(t))
    .toList();

bool _phraseContains(List<String> haystack, List<String> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    var matches = true;
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) {
        matches = false;
        break;
      }
    }
    if (matches) return true;
  }
  return false;
}

bool _isSameStation(String candidateName, String query) {
  final candidate = _normalizeStationName(candidateName);
  final queryNorm = _normalizeStationName(query);
  if (candidate.isEmpty || queryNorm.isEmpty) return false;
  if (candidate == queryNorm) return true;

  final candidateNameTokens = candidate.split(' ');
  final queryNameTokens = queryNorm.split(' ');
  final queryTokens = _stationTokens(queryNorm);
  final candidateTokens = _stationTokens(candidate);
  final queryCore = queryTokens.join(' ');
  final candidateCore = candidateTokens.join(' ');

  if (queryCore.isEmpty) return candidateCore == queryCore;
  if (candidateCore.isEmpty) return false;
  if (candidateCore == queryCore) return true;

  final numericQuery = RegExp(r'^\d+$').hasMatch(queryCore);
  final numericCandidate = RegExp(r'^\d+$').hasMatch(candidateCore);
  if (numericQuery || numericCandidate) return false;

  if (queryTokens.length >= 2 &&
      (_phraseContains(candidateTokens, queryTokens) ||
          _phraseContains(queryTokens, candidateTokens))) {
    return true;
  }

  return _phraseContains(candidateNameTokens, queryNameTokens) ||
      _phraseContains(queryNameTokens, candidateNameTokens);
}

String? _hostFromUrl(String? rawUrl) {
  if (rawUrl == null) return null;
  var value = rawUrl.trim();
  if (value.isEmpty) return null;
  if (!value.contains('://')) value = 'https://$value';
  try {
    final uri = Uri.parse(value);
    var host = uri.host.toLowerCase();
    if (host.isEmpty) return null;
    if (host.startsWith('www.')) host = host.substring(4);
    return host.contains('.') ? host : null;
  } catch (_) {
    return null;
  }
}

bool _hostInSet(String host, Set<String> hosts) => hosts.any(
      (candidate) => host == candidate || host.endsWith('.$candidate'),
    );

bool _isStationLogoHost(String host) =>
    !_hostInSet(host, _streamProviderHosts) &&
    !_hostInSet(host, _aggregatorHosts);

List<String> _logoUrlsForHost(String host) => [
      'https://www.google.com/s2/favicons?domain=$host&sz=256',
      'https://icons.duckduckgo.com/ip3/$host.ico',
      'https://logo.clearbit.com/$host',
    ];

String? _absoluteLogoUrl(String value, String baseUrl) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return null;
  final lower = trimmed.toLowerCase();
  if (lower.startsWith('data:') || lower.startsWith('javascript:')) {
    return null;
  }
  try {
    final base = Uri.parse(baseUrl);
    final resolved = base.resolve(trimmed);
    if (resolved.scheme != 'http' && resolved.scheme != 'https') return null;
    return resolved.toString();
  } catch (_) {
    return null;
  }
}

Future<List<String>> _homepageLogoUrls(String homepage) async {
  final host = _hostFromUrl(homepage);
  if (host == null || !_isStationLogoHost(host)) return [];

  var pageUrl = homepage.trim();
  if (!pageUrl.contains('://')) pageUrl = 'https://$pageUrl';

  try {
    final response = await http
        .get(Uri.parse(pageUrl), headers: _logoHttpHeaders)
        .timeout(const Duration(seconds: 5));
    if (response.statusCode < 200 || response.statusCode >= 300) return [];

    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.isNotEmpty && !contentType.contains('html')) return [];

    final html = utf8.decode(response.bodyBytes, allowMalformed: true);
    if (html.isEmpty) return [];

    final urls = <String>[];
    void addFromTag(String tagPattern, String attribute) {
      final tagRegExp = RegExp(tagPattern, caseSensitive: false, dotAll: true);
      final attributeRegExp = RegExp(
        '$attribute\\s*=\\s*["\']([^"\']+)["\']',
        caseSensitive: false,
        dotAll: true,
      );
      for (final match in tagRegExp.allMatches(html)) {
        final tag = match.group(0);
        if (tag == null) continue;
        final value = attributeRegExp.firstMatch(tag)?.group(1);
        final resolved =
            value == null ? null : _absoluteLogoUrl(value, pageUrl);
        if (resolved != null && !urls.contains(resolved)) urls.add(resolved);
      }
    }

    addFromTag(
      r"""<link[^>]+rel\s*=\s*["'][^"']*(?:apple-touch-icon|icon)[^"']*["'][^>]*>""",
      'href',
    );
    addFromTag(
      r"""<meta[^>]+(?:property|name)\s*=\s*["'](?:og:image(?::url|:secure_url)?|twitter:image(?::src)?|image)["'][^>]*>""",
      'content',
    );

    return urls.take(6).toList();
  } catch (e) {
    print('homepage $homepage failed: $e');
    return [];
  }
}

Future<Uint8List?> _downloadLogo(String url) async {
  try {
    final response = await http
        .get(Uri.parse(url), headers: _logoHttpHeaders)
        .timeout(const Duration(seconds: 6));
    if (response.statusCode < 200 || response.statusCode >= 300) return null;
    final bytes = response.bodyBytes;
    if (bytes.length < 64 || bytes.length > 4 * 1024 * 1024) return null;
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.contains('text/html') ||
        contentType.contains('application/json')) {
      return null;
    }
    return bytes;
  } catch (_) {
    return null;
  }
}

({Uint8List bytes, String signature})? _prepareLogo(Uint8List raw) {
  try {
    final decoded = img.decodeImage(raw);
    if (decoded == null) return null;
    if (decoded.width < 16 || decoded.height < 16) return null;
    if (decoded.width * decoded.height > 40000000) return null;

    final signature = crypto.sha1
        .convert(
          img.encodePng(img.copyResize(decoded, width: 32, height: 32)),
        )
        .toString();

    var output = decoded;
    final maxSide = math.max(decoded.width, decoded.height);
    if (maxSide > 512) {
      output = img.copyResize(
        decoded,
        width: decoded.width >= decoded.height ? 512 : null,
        height: decoded.height > decoded.width ? 512 : null,
      );
    }

    return (
      bytes: Uint8List.fromList(img.encodePng(output, level: 6)),
      signature: signature,
    );
  } catch (_) {
    return null;
  }
}

Future<List<dynamic>> _fetchRadioBrowserStations(String query) async {
  final encoded = Uri.encodeComponent(query);
  for (var i = 1; i <= 5; i++) {
    final server = 'de$i.api.radio-browser.info';
    final url = Uri.parse(
      'https://$server/json/stations/search?name=$encoded&limit=100&hidebroken=true&order=clickcount&reverse=true',
    );
    try {
      final response =
          await http.get(url).timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        final decoded = json.decode(response.body);
        if (decoded is List) return decoded;
      }
    } catch (e) {
      print('server $server failed: $e');
    }
  }
  return [];
}

Future<void> probe(String name) async {
  print('=== $name ===');
  final raw = await _fetchRadioBrowserStations(name);
  final matching = raw
      .whereType<Map>()
      .map((s) => Map<String, dynamic>.from(s))
      .where((s) => _isSameStation('${s['name']}', name))
      .toList();
  matching.sort((a, b) =>
      (b['clickcount'] as num? ?? 0).compareTo(a['clickcount'] as num? ?? 0));
  print('matching stations: ${matching.length}');
  for (final s in matching.take(4)) {
    print(' - ${s['name']} | ${s['homepage']} | ${s['favicon']}');
  }

  final homepageLogos = <String>[];
  for (final s in matching.take(4)) {
    final homepage = '${s['homepage'] ?? ''}';
    if (homepage.isEmpty) continue;
    for (final u in await _homepageLogoUrls(homepage)) {
      if (!homepageLogos.contains(u)) homepageLogos.add(u);
    }
  }
  final favicons = matching
      .map((s) => '${s['favicon'] ?? ''}')
      .where((u) => u.startsWith('http'))
      .toSet()
      .toList();
  final domains = matching
      .map((s) => _hostFromUrl('${s['homepage'] ?? ''}'))
      .whereType<String>()
      .where(_isStationLogoHost)
      .toSet()
      .expand(_logoUrlsForHost)
      .toList();

  final candidates = <String>[...homepageLogos, ...favicons, ...domains];
  print('candidates: ${candidates.length}');
  final seen = <String>{};
  var shown = 0;
  for (final url in candidates) {
    if (shown >= 15) break;
    final rawBytes = await _downloadLogo(url);
    if (rawBytes == null) {
      print(' SKIP (download) $url');
      continue;
    }
    final prepared = _prepareLogo(rawBytes);
    if (prepared == null) {
      print(' SKIP (decode)   $url');
      continue;
    }
    if (!seen.add(prepared.signature)) {
      print(' DUP              $url');
      continue;
    }
    shown++;
    print(' OK ${prepared.bytes.length.toString().padLeft(6)} bytes  $url');
  }
  print('shown: $shown');
}

Future<void> main() async {
  for (final name in [
    'Radio Italia',
    'Radio Deejay',
    'RTL 102.5',
    'Radio 105',
    'Virgin Radio',
  ]) {
    await probe(name);
  }
}

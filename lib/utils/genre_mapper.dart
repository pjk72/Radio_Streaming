class GenreMapper {
  static const String _basePath = 'assets/images/default_stations';

  static String? getGenreImage(String genre) {
    final lower = genre.toLowerCase();

    if (lower.contains('pop') ||
        lower.contains('indie') ||
        lower.contains('hits') ||
        lower.contains('top')) {
      return '$_basePath/pop.png';
    }
    if (lower.contains('rock') ||
        lower.contains('metal') ||
        lower.contains('punk')) {
      return '$_basePath/rock.png';
    }
    if (lower.contains('news') ||
        lower.contains('talk') ||
        lower.contains('sport') ||
        lower.contains('radio 1')) {
      return '$_basePath/news.png';
    }
    if (lower.contains('italian') ||
        lower.contains('italy') ||
        lower.contains('napop') ||
        lower.contains('milano') ||
        lower.contains('roma')) {
      return '$_basePath/italian.png';
    }
    if (lower.contains('lofi') ||
        lower.contains('chill') ||
        lower.contains('ambient') ||
        lower.contains('sleep') ||
        lower.contains('study')) {
      return '$_basePath/lofi.png';
    }
    if (lower.contains('jazz') ||
        lower.contains('blues') ||
        lower.contains('soul') ||
        lower.contains('rnb') ||
        lower.contains('funk') ||
        lower.contains('smooth')) {
      return '$_basePath/jazz.png';
    }
    if (lower.contains('classic') ||
        lower.contains('piano') ||
        lower.contains('opera') ||
        lower.contains('instrumental') ||
        lower.contains('symphony')) {
      return '$_basePath/classical.png';
    }
    if (lower.contains('electronic') ||
        lower.contains('dance') ||
        lower.contains('house') ||
        lower.contains('techno') ||
        lower.contains('edm') ||
        lower.contains('disco') ||
        lower.contains('club') ||
        lower.contains('rap') ||
        lower.contains('hip hop')) {
      return '$_basePath/electronic.png';
    }

    // Fallback: Use Generative AI for new/unknown genres
    // This creates an image pertinent to the genre name on the fly.
    final safeGenre = Uri.encodeComponent(genre);
    // Determine a seed for consistency so the image doesn't change on every reload
    final seed = genre.hashCode;

    // Using Pollinations.ai for free generation
    return "https://image.pollinations.ai/prompt/abstract%20music%20genre%20$safeGenre%20wallpaper%20aesthetic%20vibrant%20minimalist?width=800&height=800&nologo=true&seed=$seed";
  }
}

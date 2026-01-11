class GenreMapper {
  static String? getGenreImage(String genre) {
    final lower = genre.toLowerCase().trim();

    // Strict mapping to basic assets to ensure unique images for variations
    // Only exact matches (or very close aliases) get the static local asset.
    // Everything else gets a unique generated image.

    // switch (lower) {
    //   case 'pop':
    //     return '$_basePath/pop.png';
    //   case 'rock':
    //     return '$_basePath/rock.png';
    //   case 'news':
    //     return '$_basePath/news.png';
    //   case 'italian':
    //     return '$_basePath/italian.png';
    //   case 'lofi':
    //     return '$_basePath/lofi.png';
    //   case 'jazz':
    //     return '$_basePath/jazz.png';
    //   case 'classical':
    //     return '$_basePath/classical.png';
    //   case 'electronic':
    //     return '$_basePath/electronic.png';
    // }

    // Fallback: Use Generative AI for new/unknown genres
    // This creates an image pertinent to the genre name on the fly.
    // Improve prompt specifically for "Mix" or generic terms to ensure vibrant style
    String promptTerm = genre;
    if (lower == 'mix') {
      promptTerm = 'colorful abstract musical variety';
    }
    if (lower == 'favorites') {
      promptTerm = 'colorful abstract favorites music';
    }

    final safeGenre = Uri.encodeComponent(promptTerm);
    // Determine a seed for consistency so the image doesn't change on every reload
    // Use lower case hash to ensure 'Pop' and 'pop' generate the same image
    final seed = lower.hashCode;

    // Using Pollinations.ai for free generation
    //return "https://image.pollinations.ai/prompt/abstract%20music%20genre%20$safeGenre%20wallpaper%20aesthetic%20vibrant%20minimalist?width=800&height=800&nologo=true&seed=$seed";
    return "https://image.pollinations.ai/prompt/music%20genre%20$safeGenre%20wallpaper%20aesthetic%20vibrant%20minimalist?width=800&height=800&nologo=true&seed=$seed";
  }
}

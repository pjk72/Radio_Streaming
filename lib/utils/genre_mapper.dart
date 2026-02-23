class GenreMapper {
  static const String _apiKey = "sk_NRg0o7LdoV85Fm6njUnSdE54eHB6FexS";

  static String? getGenreImage(String genre) {
    final lower = genre.toLowerCase().trim();

    String promptTerm = genre;
    if (lower == 'mix') {
      promptTerm = 'colorful abstract musical variety';
    } else if (lower == 'favorites') {
      promptTerm = 'colorful abstract favorites music';
    } else {
      promptTerm =
          'music genre $promptTerm wallpaper aesthetic vibrant minimalist';
    }

    final safePrompt = Uri.encodeComponent(promptTerm);
    final seed = lower.hashCode.abs();

    return "https://api.stablehorde.net/api/$safePrompt?model=flux&width=800&height=800&seed=$seed&enhance=false&key=$_apiKey";
  }
}

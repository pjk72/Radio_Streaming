class Station {
  final int id;
  final String name;
  final String genre;
  final String url;
  final String? icon; // FontAwesome icon code or name
  final String? logo; // URL to image
  final String color;
  final String category;
  final String? countryCode;

  Station({
    required this.id,
    required this.name,
    required this.genre,
    required this.url,
    this.icon,
    this.logo,
    required this.color,
    required this.category,
    this.countryCode,
  });
  factory Station.fromJson(Map<String, dynamic> json) {
    return Station(
      id: json['id'] as int,
      name: json['name'] as String,
      genre: json['genre'] as String,
      url: json['url'] as String,
      icon: json['icon'] as String?,
      logo: json['logo'] as String?,
      color: json['color'] as String,
      category: json['category'] as String,
      countryCode: json['countryCode'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'genre': genre,
      'url': url,
      'icon': icon,
      'logo': logo,
      'color': color,
      'category': category,
      'countryCode': countryCode,
    };
  }
}

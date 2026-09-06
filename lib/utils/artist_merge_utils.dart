class MergeSuggestion {
  final String source;
  final String target;
  final double similarity;
  final int sourceCount;
  final int targetCount;
  final String? sourceArtist;
  final String? targetArtist;

  const MergeSuggestion({
    required this.source,
    required this.target,
    required this.similarity,
    required this.sourceCount,
    required this.targetCount,
    this.sourceArtist,
    this.targetArtist,
  });
}

class MergeUtils {
  /// Matches the grouping normalization used by the artists grid:
  /// takes the first name of "A • B" or "A, B / C", trims and lowercases.
  static String artistGroupingKey(String raw) {
    return raw
        .split('•')
        .first
        .trim()
        .split(RegExp(r'[,&/]'))
        .first
        .trim()
        .toLowerCase();
  }

  /// Matches the grouping normalization used by the albums grid:
  /// strips parenthesized qualifiers ("(Deluxe)") and bracketed ones
  /// ("[Live]"), trims and lowercases.
  static String albumGroupingKey(String raw) {
    return raw
        .split('(')
        .first
        .trim()
        .split('[')
        .first
        .trim()
        .toLowerCase();
  }

  /// Aggressive normalization used only to compare names:
  /// strips accents, brackets/parentheses content, "feat./ft.", a leading
  /// "the " and any non-alphanumeric character.
  static String similarityKey(String name) {
    String res = _stripDiacritics(name.toLowerCase());
    res = res.replaceAll(RegExp(r'\([^)]*\)'), '');
    res = res.replaceAll(RegExp(r'\[[^\]]*\]'), '');
    res = res.replaceAll('feat.', '');
    res = res.replaceAll('feat', '');
    res = res.replaceAll('ft.', '');
    res = res.replaceAll('ft', '');
    res = res.replaceAll(RegExp(r'^the\s+'), '');
    res = res.replaceAll(RegExp(r'[^a-z0-9]'), '');
    return res.trim();
  }

  static double similarity(String a, String b) {
    final normA = similarityKey(a);
    final normB = similarityKey(b);
    if (normA.isEmpty || normB.isEmpty) return 0.0;
    if (normA == normB) return 100.0;

    final distance = levenshteinDistance(normA, normB);
    final maxLen =
        normA.length > normB.length ? normA.length : normB.length;
    double base = 1.0 - (distance / maxLen);
    base *= 100.0;

    if (normA.length >= 3 && normB.length >= 3) {
      if (normB.startsWith(normA) || normA.startsWith(normB)) {
        base += 20.0;
      }
    }

    return base.clamp(0.0, 100.0);
  }

  static int levenshteinDistance(String a, String b) {
    final m = a.length;
    final n = b.length;
    if (m == 0) return n;
    if (n == 0) return m;

    List<int> prev = List<int>.generate(n + 1, (i) => i);
    List<int> curr = List<int>.filled(n + 1, 0);

    for (int i = 1; i <= m; i++) {
      curr[0] = i;
      for (int j = 1; j <= n; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        final deletion = curr[j - 1] + 1;
        final insertion = prev[j] + 1;
        final substitution = prev[j - 1] + cost;
        curr[j] = deletion < insertion
            ? (deletion < substitution ? deletion : substitution)
            : (insertion < substitution ? insertion : substitution);
      }
      prev = List<int>.from(curr);
    }
    return prev[n];
  }

  static List<MergeSuggestion> findMergeSuggestions(
    Iterable<String> rawValues, {
    required String Function(String) groupingKey,
    double threshold = 70.0,
    Iterable<String>? companions,
    double companionWeight = 0.0,
  }) {
    final groupCounts = <String, int>{};
    final groupDisplay = <String, String>{};
    final rawCounts = <String, int>{};
    final rawCompanions = <String, Map<String, int>>{};

    final rawList = rawValues.toList();
    final compList = companions?.toList();

    for (int i = 0; i < rawList.length; i++) {
      final raw = rawList[i];
      if (raw.trim().isEmpty) continue;
      rawCounts[raw] = (rawCounts[raw] ?? 0) + 1;
      final key = groupingKey(raw);
      groupCounts[key] = (groupCounts[key] ?? 0) + 1;
      if (compList != null && i < compList.length) {
        final companion = compList[i];
        rawCompanions
            .putIfAbsent(raw, () => {})
            .update(companion, (c) => c + 1, ifAbsent: () => 1);
      }
    }

    for (final raw in rawCounts.keys) {
      final key = groupingKey(raw);
      final current = groupDisplay[key];
      if (current == null || (rawCounts[raw] ?? 0) > (rawCounts[current] ?? 0)) {
        groupDisplay[key] = raw;
      }
    }

    final groupCompanion = <String, String>{};
    if (compList != null) {
      for (final key in groupDisplay.keys) {
        final counts = rawCompanions[groupDisplay[key]];
        if (counts == null || counts.isEmpty) continue;
        String? best;
        int bestCount = -1;
        for (final entry in counts.entries) {
          if (entry.value > bestCount) {
            best = entry.key;
            bestCount = entry.value;
          }
        }
        if (best != null) groupCompanion[key] = best;
      }
    }

    final keys = groupCounts.keys.toList();
    final suggestions = <MergeSuggestion>[];
    final seen = <String>{};

    for (int i = 0; i < keys.length; i++) {
      for (int j = i + 1; j < keys.length; j++) {
        final keyA = keys[i];
        final keyB = keys[j];
        final normalA = similarityKey(keyA);
        final normalB = similarityKey(keyB);
        if (normalA.isEmpty || normalB.isEmpty) continue;

        double sim = similarity(keyA, keyB);
        if (compList != null && companionWeight > 0) {
          final companionA = groupCompanion[keyA];
          final companionB = groupCompanion[keyB];
          double companionSim = 1.0;
          if (companionA != null &&
              companionA.trim().isNotEmpty &&
              companionB != null &&
              companionB.trim().isNotEmpty) {
            companionSim = similarity(companionA, companionB);
          }
          sim = sim * (1 - companionWeight) + companionSim * companionWeight;
        }
        if (sim < threshold) continue;

        final countA = groupCounts[keyA]!;
        final countB = groupCounts[keyB]!;
        final displayA = groupDisplay[keyA]!;
        final displayB = groupDisplay[keyB]!;

        final MergeSuggestion suggestion;
        if (countA <= countB) {
          suggestion = MergeSuggestion(
            source: displayA,
            target: displayB,
            similarity: sim,
            sourceCount: countA,
            targetCount: countB,
            sourceArtist: groupCompanion[keyA],
            targetArtist: groupCompanion[keyB],
          );
        } else {
          suggestion = MergeSuggestion(
            source: displayB,
            target: displayA,
            similarity: sim,
            sourceCount: countB,
            targetCount: countA,
            sourceArtist: groupCompanion[keyB],
            targetArtist: groupCompanion[keyA],
          );
        }

        final pairKey =
            '${suggestion.source}\u0001${suggestion.target}';
        if (seen.add(pairKey)) {
          suggestions.add(suggestion);
        }
      }
    }

    suggestions.sort((a, b) {
      final byScore = b.similarity.compareTo(a.similarity);
      if (byScore != 0) return byScore;
      return (a.sourceCount + a.targetCount)
          .compareTo(b.sourceCount + b.targetCount);
    });

    return suggestions;
  }

  static String _stripDiacritics(String s) {
    const withDiacritics = 'àáâãäåçèéêëìíîïñòóôõöùúûüýÿæœ';
    const withoutDiacritics = 'aaaaaaceeeeiiiinooooouuuuyyaeoe';
    final buffer = StringBuffer();
    for (final ch in s.split('')) {
      final idx = withDiacritics.indexOf(ch);
      if (idx != -1) {
        buffer.write(withoutDiacritics[idx]);
      } else {
        buffer.write(ch);
      }
    }
    return buffer.toString();
  }
}
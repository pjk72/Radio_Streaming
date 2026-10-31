import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../services/native_ad_pool.dart';

/// Native ad slot used inside scrollable lists.
///
/// Ads are taken from [NativeAdPool], so in the common case the slot is
/// already loaded and renders on the first frame. While waiting, a fixed
/// height placeholder keeps the list from jumping; when no ad is available the
/// slot collapses instead of leaving a hole.
class NativeAdWidget extends StatefulWidget {
  const NativeAdWidget({super.key});

  @override
  State<NativeAdWidget> createState() => _NativeAdWidgetState();
}

class _NativeAdWidgetState extends State<NativeAdWidget> {
  static const double _adHeight = 90;

  NativeAd? _nativeAd;
  bool _isLoaded = false;
  bool _hasFailed = false;

  @override
  void initState() {
    super.initState();

    NativeAdPool.instance.acquire().then((ad) {
      if (!mounted) {
        if (ad != null) NativeAdPool.instance.recycle(ad);
        return;
      }

      if (ad == null) {
        setState(() => _hasFailed = true);
        return;
      }

      setState(() {
        _nativeAd = ad;
        _isLoaded = true;
      });
    });
  }

  @override
  void dispose() {
    _nativeAd?.dispose();
    _nativeAd = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasFailed) return const SizedBox.shrink();

    if (!_isLoaded || _nativeAd == null) {
      return _buildPlaceholder(context);
    }

    final cardColor = Theme.of(context).cardColor;
    return Container(
      height: _adHeight,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: cardColor.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(0),
        border: Border.all(
          color: Theme.of(context).dividerColor.withValues(alpha: 0.1),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: AdWidget(ad: _nativeAd!),
    );
  }

  Widget _buildPlaceholder(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: _adHeight,
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: theme.cardColor.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(0),
        border: Border.all(
          color: theme.dividerColor.withValues(alpha: 0.08),
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.campaign_outlined,
        size: 22,
        color: theme.dividerColor.withValues(alpha: 0.35),
      ),
    );
  }
}

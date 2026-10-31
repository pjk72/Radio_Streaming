import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

/// Bottom banner ad.
///
/// The slot keeps a fixed height while loading and retries failed requests
/// with a growing delay, so a temporary no-fill or network hiccup no longer
/// leaves the banner blank for the whole session.
class AdMobBannerWidget extends StatefulWidget {
  const AdMobBannerWidget({super.key});

  @override
  State<AdMobBannerWidget> createState() => _AdMobBannerWidgetState();
}

class _AdMobBannerWidgetState extends State<AdMobBannerWidget>
    with WidgetsBindingObserver {
  BannerAd? _bannerAd;
  BannerAd? _loadingAd;
  Timer? _retryTimer;
  bool _isLoaded = false;
  int _failureStreak = 0;

  bool get _isSupported => !kIsWeb && Platform.isAndroid;

  // Test ID: ca-app-pub-3940256099942544/6300978111
  final String _adUnitId = kReleaseMode
      ? 'ca-app-pub-3351319116434923/3527481038'
      : 'ca-app-pub-3940256099942544/6300978111';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (_isSupported) {
      _loadAd();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Coming back from background is a good moment to retry a failed banner.
    if (state == AppLifecycleState.resumed &&
        _isSupported &&
        !_isLoaded &&
        _loadingAd == null) {
      _retryTimer?.cancel();
      _retryTimer = null;
      _loadAd();
    }
  }

  void _loadAd() {
    if (!_isSupported || _loadingAd != null) return;

    _retryTimer?.cancel();
    _retryTimer = null;

    final ad = BannerAd(
      adUnitId: _adUnitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (loadedAd) {
          final banner = loadedAd as BannerAd;
          final isPending = identical(_loadingAd, banner);
          final isDisplayed = identical(_bannerAd, banner);

          if (!mounted) {
            // The widget already disposed the pending ad; never touch the
            // currently displayed one.
            if (isPending) banner.dispose();
            return;
          }

          _loadingAd = null;

          if (isDisplayed) {
            // AdMob auto-refresh of the banner already on screen: nothing to
            // swap, just rebuild so the new creative is shown.
            _failureStreak = 0;
            _retryTimer?.cancel();
            _retryTimer = null;
            setState(() {
              _isLoaded = true;
            });
            return;
          }

          _failureStreak = 0;
          _retryTimer?.cancel();
          _retryTimer = null;

          final previous = _bannerAd;
          setState(() {
            _bannerAd = banner;
            _isLoaded = true;
          });
          previous?.dispose();
        },
        onAdFailedToLoad: (failedAd, error) {
          final banner = failedAd as BannerAd;
          final isPending = identical(_loadingAd, banner);
          final isDisplayed = identical(_bannerAd, banner);

          if (isPending) {
            _loadingAd = null;
            banner.dispose();
          } else if (!isDisplayed) {
            // Stale callback from an ad we no longer track.
            return;
          }

          // A failed auto-refresh keeps the creative already on screen: do not
          // dispose it, just schedule another attempt.
          _onAdFailed(error);
        },
      ),
    );

    _loadingAd = ad;
    ad.load();
  }

  void _onAdFailed(LoadAdError error) {
    debugPrint(
      'Banner Ad failed to load (code ${error.code}): ${error.message}',
    );

    if (!mounted) return;

    _failureStreak++;
    final message = error.message.toLowerCase();
    final isThrottled = message.contains('too many');
    final isNoFill = error.code == 3;
    final baseSeconds = isThrottled ? 300 : (isNoFill ? 60 : 20);
    final exponent = (_failureStreak - 1).clamp(0, 3).toInt();
    final delay = Duration(
      seconds: (baseSeconds * (1 << exponent)).clamp(baseSeconds, 600),
    );

    _retryTimer?.cancel();
    _retryTimer = Timer(delay, () {
      if (mounted) _loadAd();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _retryTimer?.cancel();
    _retryTimer = null;
    _loadingAd?.dispose();
    _loadingAd = null;
    _bannerAd?.dispose();
    _bannerAd = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isSupported) return const SizedBox.shrink();

    if (!_isLoaded || _bannerAd == null) {
      return Container(
        height: 50,
        width: double.infinity,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.05),
          border: Border(
            top: BorderSide(
              color: Colors.white.withValues(alpha: 0.05),
              width: 0.5,
            ),
          ),
        ),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.ads_click,
                size: 12,
                color: Colors.white.withValues(alpha: 0.1),
              ),
              const SizedBox(width: 8),
              Text(
                "ADVERTISEMENT",
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.15),
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.2,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Container(
      alignment: Alignment.center,
      width: double.infinity,
      height: _bannerAd!.size.height.toDouble(),
      decoration: BoxDecoration(
        color: Colors.transparent,
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.05),
            width: 0.5,
          ),
        ),
      ),
      child: SizedBox(
        width: _bannerAd!.size.width.toDouble(),
        height: _bannerAd!.size.height.toDouble(),
        child: AdWidget(ad: _bannerAd!),
      ),
    );
  }
}

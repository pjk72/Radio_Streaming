import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:flutter/foundation.dart';
import 'log_service.dart';

class InterstitialAdService {
  static final InterstitialAdService _instance = InterstitialAdService._internal();
  factory InterstitialAdService() => _instance;
  InterstitialAdService._internal();

  InterstitialAd? _interstitialAd;
  bool _isAdLoading = false;
  int _numAttempts = 0;
  static const int _maxAttempts = 3;

  final String _adUnitId = kReleaseMode
      ? 'ca-app-pub-3351319116434923/1642535796'
      : 'ca-app-pub-3940256099942544/1033173712'; // Test ID for debug

  /// Preload the ad
  void loadAd() {
    if (_isAdLoading || _interstitialAd != null) {
      LogService().log("InterstitialAdService: Ad already loading or loaded.");
      return;
    }
    _isAdLoading = true;

    LogService().log("InterstitialAdService: Starting load for ID: $_adUnitId");

    InterstitialAd.load(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          LogService().log("InterstitialAdService: Ad loaded successfully on attempt ${_numAttempts + 1}.");
          _interstitialAd = ad;
          _isAdLoading = false;
          _numAttempts = 0; // Reset on success

          _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (ad) {
              LogService().log("InterstitialAdService: Ad dismissed.");
              ad.dispose();
              _interstitialAd = null;
              loadAd(); // Pre-load next
            },
            onAdFailedToShowFullScreenContent: (ad, error) {
              LogService().log("InterstitialAdService: Ad failed to show: $error");
              ad.dispose();
              _interstitialAd = null;
              loadAd();
            },
          );
        },
        onAdFailedToLoad: (LoadAdError error) {
          _numAttempts++;
          _isAdLoading = false;
          _interstitialAd = null;
          LogService().log("InterstitialAdService: Ad failed to load (Attempt $_numAttempts): $error");
          
          if (_numAttempts < _maxAttempts) {
             LogService().log("InterstitialAdService: Retrying in 5 seconds...");
             Future.delayed(const Duration(seconds: 5), () => loadAd());
          } else {
             LogService().log("InterstitialAdService: Max load attempts reached.");
          }
        },
      ),
    );
  }

  /// Show the ad if it is loaded
  void showAd() {
    if (_interstitialAd != null) {
      LogService().log("InterstitialAdService: Showing ad.");
      _interstitialAd!.show();
    } else {
      LogService().log("InterstitialAdService: Ad not ready, status: ${_isAdLoading ? 'Loading' : 'Idle'}.");
      if (!_isAdLoading) {
        loadAd();
      }
    }
  }
}

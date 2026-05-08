import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:flutter/foundation.dart';
import 'log_service.dart';
import 'entitlement_service.dart';

class InterstitialAdService {
  static final InterstitialAdService _instance = InterstitialAdService._internal();
  factory InterstitialAdService() => _instance;
  InterstitialAdService._internal();

  InterstitialAd? _interstitialAd;
  bool _isAdLoading = false;
  int _numAttempts = 0;
  static const int _maxAttempts = 3;
  EntitlementService? _entitlements;

  final String _adUnitId = kReleaseMode
      ? 'ca-app-pub-3351319116434923/5813365382'
      : 'ca-app-pub-3940256099942544/1033173712'; // Test ID for debug

  /// Initialize with entitlements and setup listener
  void init(EntitlementService entitlements) {
    LogService().log("InterstitialAdService: Initializing and setup listener...");
    _entitlements = entitlements;
    
    // Listen for config changes so we can load the ad as soon as the feature is enabled
    _entitlements!.addListener(_onEntitlementsChanged);
    
    // Immediate try
    loadAd();
  }

  void _onEntitlementsChanged() {
    if (_interstitialAd == null && !_isAdLoading) {
      if (_entitlements!.isFeatureEnabled('interstitial_ad')) {
        LogService().log("InterstitialAdService: Feature enabled by config change. Loading now...");
        loadAd();
      }
    }
  }

  /// Preload the ad
  void loadAd() {
    if (_isAdLoading) {
      LogService().log("InterstitialAdService: Ad already loading.");
      return;
    }
    if (_interstitialAd != null) {
      LogService().log("InterstitialAdService: Ad already loaded, skipping request.");
      return;
    }

    // Check if feature is enabled BEFORE making the request
    if (_entitlements != null &&
        !_entitlements!.isFeatureEnabled('interstitial_ad')) {
      LogService().log("InterstitialAdService: Ad disabled for this user by Remote Config. Skipping request.");
      return;
    }

    _isAdLoading = true;
    LogService().log("InterstitialAdService: Starting load for ID: $_adUnitId");

    InterstitialAd.load(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          LogService().log("InterstitialAdService: Ad loaded successfully. (AdHash: ${ad.hashCode})");
          _interstitialAd = ad;
          _isAdLoading = false;
          _numAttempts = 0;

          _interstitialAd!.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (ad) {
              LogService().log("InterstitialAdService: Ad dismissed by user.");
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
            onAdShowedFullScreenContent: (ad) {
              LogService().log("InterstitialAdService: Ad displayed successfully.");
            },
          );
        },
        onAdFailedToLoad: (LoadAdError error) {
          _numAttempts++;
          _isAdLoading = false;
          _interstitialAd = null;
          LogService().log("InterstitialAdService: Ad failed to load (Attempt $_numAttempts): $error");
          
          if (_numAttempts < _maxAttempts) {
             LogService().log("InterstitialAdService: Retrying in 15 seconds...");
             Future.delayed(const Duration(seconds: 15), () => loadAd());
          } else {
             LogService().log("InterstitialAdService: Max load attempts reached.");
          }
        },
      ),
    );
  }

  /// Show the ad if it is loaded
  void showAd() {
    LogService().log("InterstitialAdService: showAd() request triggered.");

    if (_entitlements != null &&
        !_entitlements!.isFeatureEnabled('interstitial_ad')) {
      LogService().log("InterstitialAdService: showAd blocked by Remote Config permissions.");
      return;
    }

    if (_interstitialAd == null) {
      LogService().log("InterstitialAdService: Ad NOT showable because _interstitialAd is NULL. State: ${_isAdLoading ? 'Loading' : 'Idle'}");
      if (!_isAdLoading) {
        loadAd();
      }
      return;
    }

    try {
      LogService().log("InterstitialAdService: Attempting to call .show() on AdHash: ${_interstitialAd.hashCode}");
      _interstitialAd!.show();
    } catch (e) {
      LogService().log("InterstitialAdService: Exception during .show(): $e");
      _interstitialAd = null;
      loadAd();
    }
  }

  void dispose() {
    _entitlements?.removeListener(_onEntitlementsChanged);
  }
}

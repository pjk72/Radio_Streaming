import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'entitlement_service.dart';
import 'log_service.dart';

class InterstitialAdService {
  static final InterstitialAdService _instance = InterstitialAdService._internal();
  factory InterstitialAdService() => _instance;
  InterstitialAdService._internal();

  InterstitialAd? _interstitialAd;
  bool _isAdLoading = false;
  bool _isInitialized = false;

  int _numAttempts = 0;
  static const int _maxAttempts = 3;

  EntitlementService? _entitlements;
  Timer? _retryTimer;
  Completer<void>? _loadCompleter;

  final String _adUnitId = kReleaseMode
      ? 'ca-app-pub-3351319116434923/5813365382'
      : 'ca-app-pub-3940256099942544/1033173712';

  void init(EntitlementService entitlements) {
    LogService().log("InterstitialAdService: init()");

    if (_entitlements != null) {
      _entitlements!.removeListener(_onEntitlementsChanged);
    }

    _entitlements = entitlements;
    _entitlements!.addListener(_onEntitlementsChanged);
    _isInitialized = true;

    // Preload iniziale se la feature è attiva
    if (_isInterstitialEnabled) {
      loadAd();
    } else {
      LogService().log("InterstitialAdService: interstitial_ad disabled at init.");
    }
  }

  bool get _isInterstitialEnabled {
    return _entitlements == null ||
        _entitlements!.isFeatureEnabled('interstitial_ad');
  }

  void _onEntitlementsChanged() {
    final enabled = _isInterstitialEnabled;
    LogService().log("InterstitialAdService: Entitlements changed. interstitial_ad enabled = $enabled");

    if (!enabled) {
      _retryTimer?.cancel();
      _retryTimer = null;

      _interstitialAd?.dispose();
      _interstitialAd = null;
      _isAdLoading = false;

      if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
        _loadCompleter!.completeError(Exception("Interstitial disabled by entitlements"));
      }
      _loadCompleter = null;

      LogService().log("InterstitialAdService: Ad disposed because feature is disabled.");
      return;
    }

    if (_interstitialAd == null && !_isAdLoading) {
      loadAd();
    }
  }

  bool get isAdReady => _interstitialAd != null;

  void loadAd() {
    if (!_isInitialized) {
      LogService().log("InterstitialAdService: loadAd() skipped because service is not initialized.");
      return;
    }

    if (!_isInterstitialEnabled) {
      LogService().log("InterstitialAdService: loadAd() skipped - feature disabled.");
      return;
    }

    if (_isAdLoading) {
      LogService().log("InterstitialAdService: Ad already loading.");
      return;
    }

    if (_interstitialAd != null) {
      LogService().log("InterstitialAdService: Ad already loaded, skipping request.");
      return;
    }

    _retryTimer?.cancel();
    _retryTimer = null;

    _isAdLoading = true;
    _loadCompleter ??= Completer<void>();

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

          if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
            _loadCompleter!.complete();
          }
          _loadCompleter = null;

          ad.fullScreenContentCallback = FullScreenContentCallback(
            onAdShowedFullScreenContent: (ad) {
              LogService().log("InterstitialAdService: Ad displayed successfully.");
            },
            onAdImpression: (ad) {
              LogService().log("InterstitialAdService: Ad impression recorded by Google SDK.");
            },
            onAdDismissedFullScreenContent: (ad) {
              LogService().log("InterstitialAdService: Ad dismissed by user.");
              ad.dispose();

              if (identical(_interstitialAd, ad)) {
                _interstitialAd = null;
              }

              // Preload immediato del prossimo ad
              loadAd();
            },
            onAdFailedToShowFullScreenContent: (ad, error) {
              LogService().log("InterstitialAdService: Ad failed to show: $error");
              ad.dispose();

              if (identical(_interstitialAd, ad)) {
                _interstitialAd = null;
              }

              // Riprova a caricare il prossimo
              loadAd();
            },
          );
        },
        onAdFailedToLoad: (LoadAdError error) {
          _numAttempts++;
          _isAdLoading = false;
          _interstitialAd = null;

          LogService().log("InterstitialAdService: Ad failed to load (Attempt $_numAttempts): $error");

          if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
            _loadCompleter!.completeError(error);
          }
          _loadCompleter = null;

          if (_numAttempts < _maxAttempts && _isInterstitialEnabled) {
            LogService().log("InterstitialAdService: Retrying in 15 seconds...");
            _retryTimer = Timer(const Duration(seconds: 15), () {
              loadAd();
            });
          } else {
            LogService().log("InterstitialAdService: Max load attempts reached.");
          }
        },
      ),
    );
  }

  Future<bool> showAdIfAvailable({
    Duration waitTimeout = const Duration(seconds: 3),
  }) async {
    LogService().log("InterstitialAdService: showAdIfAvailable() called.");

    if (!_isInitialized) {
      LogService().log("InterstitialAdService: show blocked - service not initialized.");
      return false;
    }

    if (!_isInterstitialEnabled) {
      LogService().log("InterstitialAdService: show blocked by Remote Config permissions.");
      return false;
    }

    if (_interstitialAd == null) {
      LogService().log("InterstitialAdService: No ad ready, trying to load one before show...");
      loadAd();

      try {
        if (_loadCompleter != null) {
          await _loadCompleter!.future.timeout(waitTimeout);
        }
      } catch (e) {
        LogService().log("InterstitialAdService: Ad not ready within timeout or load failed: $e");
      }
    }

    final ad = _interstitialAd;
    if (ad == null) {
      LogService().log("InterstitialAdService: Ad still not available after waiting.");
      return false;
    }

    try {
      LogService().log("InterstitialAdService: Attempting to call .show() on AdHash: ${ad.hashCode}");

      // Rimuovo subito il riferimento per evitare doppi show
      _interstitialAd = null;

      ad.show();
      return true;
    } catch (e) {
      LogService().log("InterstitialAdService: Exception during .show(): $e");
      _interstitialAd = null;
      loadAd();
      return false;
    }
  }

  void preloadIfNeeded() {
    if (_interstitialAd == null && !_isAdLoading && _isInterstitialEnabled) {
      loadAd();
    }
  }

  void dispose() {
    LogService().log("InterstitialAdService: dispose()");

    _retryTimer?.cancel();
    _retryTimer = null;

    _entitlements?.removeListener(_onEntitlementsChanged);

    _interstitialAd?.dispose();
    _interstitialAd = null;

    _isAdLoading = false;
    _isInitialized = false;

    if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
      _loadCompleter!.completeError(Exception("Service disposed"));
    }
    _loadCompleter = null;
  }
}
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import 'log_service.dart';

class RewardedAdService {
  static final RewardedAdService _instance = RewardedAdService._internal();
  factory RewardedAdService() => _instance;
  RewardedAdService._internal();

  RewardedAd? _rewardedAd;

  bool _isInitialized = false;
  bool _isAdLoading = false;
  bool _isShowingAd = false;

  int _loadAttempts = 0;
  static const int _maxLoadAttempts = 3;

  Timer? _retryTimer;
  Completer<void>? _loadCompleter;

  final String _adUnitId = kReleaseMode
      ? 'ca-app-pub-3351319116434923/2436643024'
      : 'ca-app-pub-3940256099942544/5224354917'; // Test ID for debug

  bool get isAdReady => _rewardedAd != null;

  /// Da chiamare una volta all'avvio dell'app o all'inizializzazione dei servizi
  void init() {
    if (_isInitialized) {
      LogService().log("RewardedAdService: init() skipped, already initialized.");
      return;
    }

    _isInitialized = true;
    LogService().log("RewardedAdService: init() completed. Starting preload...");
    loadRewardedAd();
  }

  /// Carica un rewarded se non ce n'è già uno pronto o in caricamento
  void loadRewardedAd() {
    if (!_isInitialized) {
      LogService().log("RewardedAdService: loadRewardedAd() skipped, service not initialized.");
      return;
    }

    if (_isAdLoading) {
      LogService().log("RewardedAdService: load skipped, ad already loading.");
      return;
    }

    if (_rewardedAd != null) {
      LogService().log("RewardedAdService: load skipped, ad already available.");
      return;
    }

    _retryTimer?.cancel();
    _retryTimer = null;

    _isAdLoading = true;
    _loadCompleter ??= Completer<void>();

    LogService().log("RewardedAdService: Starting load for ID: $_adUnitId");

    RewardedAd.load(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          LogService().log("RewardedAdService: Ad loaded successfully. (AdHash: ${ad.hashCode})");

          _rewardedAd = ad;
          _isAdLoading = false;
          _loadAttempts = 0;

          if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
            _loadCompleter!.complete();
          }
          _loadCompleter = null;

          _attachDefaultCallbacks(ad);
        },
        onAdFailedToLoad: (LoadAdError error) {
          _isAdLoading = false;
          _rewardedAd = null;
          _loadAttempts++;

          LogService().log(
            "RewardedAdService: Ad failed to load (attempt $_loadAttempts): $error",
          );

          if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
            _loadCompleter!.completeError(error);
          }
          _loadCompleter = null;

          if (_loadAttempts < _maxLoadAttempts) {
            LogService().log("RewardedAdService: Retrying load in 10 seconds...");
            _retryTimer = Timer(const Duration(seconds: 10), () {
              loadRewardedAd();
            });
          } else {
            LogService().log("RewardedAdService: Max load attempts reached.");
          }
        },
      ),
    );
  }

  /// Mostra il rewarded se disponibile.
  ///
  /// Se non è pronto, prova ad aspettare fino a [waitTimeout].
  /// Restituisce:
  /// - true se l'ad è stato mostrato e l'utente ha guadagnato la reward
  /// - false in tutti gli altri casi
  Future<bool> showAdIfAvailable({
    required void Function(AdWithoutView ad, RewardItem reward) onUserEarnedReward,
    required VoidCallback onAdNotAvailable,
    Duration waitTimeout = const Duration(seconds: 4),
  }) async {
    LogService().log("RewardedAdService: showAdIfAvailable() called.");

    if (!_isInitialized) {
      LogService().log("RewardedAdService: service not initialized, calling init() automatically.");
      init();
    }

    if (_isShowingAd) {
      LogService().log("RewardedAdService: show blocked, another rewarded ad is already showing.");
      return false;
    }

    if (_rewardedAd == null) {
      LogService().log("RewardedAdService: No ad ready. Trying to load and wait up to ${waitTimeout.inSeconds}s...");
      loadRewardedAd();

      try {
        if (_loadCompleter != null) {
          await _loadCompleter!.future.timeout(waitTimeout);
        }
      } catch (e) {
        LogService().log("RewardedAdService: Ad was not loaded in time or load failed: $e");
      }
    }

    final ad = _rewardedAd;
    if (ad == null) {
      LogService().log("RewardedAdService: Ad not available after waiting.");
      onAdNotAvailable();
      return false;
    }

    _isShowingAd = true;
    _rewardedAd = null;

    final completer = Completer<bool>();
    bool hasEarnedReward = false;

    final oldCallback = ad.fullScreenContentCallback;

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (shownAd) {
        LogService().log("RewardedAdService: onAdShowedFullScreenContent.");
        oldCallback?.onAdShowedFullScreenContent?.call(shownAd);
      },
      onAdImpression: (shownAd) {
        LogService().log("RewardedAdService: onAdImpression.");
        oldCallback?.onAdImpression?.call(shownAd);
      },
      onAdDismissedFullScreenContent: (shownAd) {
        LogService().log("RewardedAdService: onAdDismissedFullScreenContent.");
        oldCallback?.onAdDismissedFullScreenContent?.call(shownAd);

        _isShowingAd = false;

        if (!completer.isCompleted) {
          completer.complete(hasEarnedReward);
        }
      },
      onAdFailedToShowFullScreenContent: (shownAd, error) {
        LogService().log("RewardedAdService: onAdFailedToShowFullScreenContent: $error");
        oldCallback?.onAdFailedToShowFullScreenContent?.call(shownAd, error);

        _isShowingAd = false;

        if (!completer.isCompleted) {
          completer.complete(false);
        }
      },
    );

    try {
      LogService().log("RewardedAdService: Calling show() on AdHash: ${ad.hashCode}");

      ad.show(
        onUserEarnedReward: (rewardAd, reward) {
          hasEarnedReward = true;
          LogService().log(
            "RewardedAdService: User earned reward: ${reward.amount} ${reward.type}",
          );
          onUserEarnedReward(rewardAd, reward);
        },
      );
    } catch (e) {
      LogService().log("RewardedAdService: Exception during show(): $e");

      _isShowingAd = false;
      ad.dispose();
      loadRewardedAd();

      if (!completer.isCompleted) {
        completer.complete(false);
      }
    }

    return completer.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        LogService().log("RewardedAdService: show flow timed out.");
        _isShowingAd = false;
        loadRewardedAd();
        return false;
      },
    );
  }

  /// Callback standard legate al ciclo di vita dell'ad
  void _attachDefaultCallbacks(RewardedAd ad) {
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) {
        LogService().log("RewardedAdService: Ad displayed successfully.");
      },
      onAdImpression: (ad) {
        LogService().log("RewardedAdService: Ad impression recorded by Google SDK.");
      },
      onAdDismissedFullScreenContent: (ad) {
        LogService().log("RewardedAdService: Ad dismissed by user.");
        _isShowingAd = false;
        ad.dispose();
        loadRewardedAd(); // preload del prossimo
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        LogService().log("RewardedAdService: Ad failed to show: $error");
        _isShowingAd = false;
        ad.dispose();
        loadRewardedAd(); // prova a preparare il prossimo
      },
    );
  }

  /// Utile se vuoi forzare il preload in momenti strategici
  void preloadIfNeeded() {
    if (_rewardedAd == null && !_isAdLoading) {
      LogService().log("RewardedAdService: preloadIfNeeded() -> loading ad...");
      loadRewardedAd();
    }
  }

  void dispose() {
    LogService().log("RewardedAdService: dispose()");

    _retryTimer?.cancel();
    _retryTimer = null;

    _rewardedAd?.dispose();
    _rewardedAd = null;

    _isAdLoading = false;
    _isShowingAd = false;
    _isInitialized = false;

    if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
      _loadCompleter!.completeError(Exception("RewardedAdService disposed"));
    }
    _loadCompleter = null;
  }
}
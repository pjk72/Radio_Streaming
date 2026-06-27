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

  /// Carica un rewarded se non ce n'è già uno pronto o in caricamento.
  /// Restituisce il [Completer] corrente così i caller possono attenderne
  /// il completamento anche se il caricamento era già in corso.
  void loadRewardedAd() {
    if (!_isInitialized) {
      LogService().log("RewardedAdService: loadRewardedAd() skipped, service not initialized.");
      return;
    }

    if (_isAdLoading) {
      // FIX Bug 2: se il caricamento è già in corso assicuriamo che il
      // completer esista, così i caller possono aspettarlo.
      _loadCompleter ??= Completer<void>();
      LogService().log("RewardedAdService: load already in progress, caller can await existing completer.");
      return;
    }

    if (_rewardedAd != null) {
      LogService().log("RewardedAdService: load skipped, ad already available.");
      return;
    }

    _retryTimer?.cancel();
    _retryTimer = null;

    _isAdLoading = true;
    // Crea sempre un nuovo completer fresco prima di iniziare il load.
    _loadCompleter = Completer<void>();

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

          _attachDefaultCallbacks(ad);

          if (_loadCompleter != null && !_loadCompleter!.isCompleted) {
            _loadCompleter!.complete();
          }
          _loadCompleter = null;
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
    Duration waitTimeout = const Duration(seconds: 5),
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

    // FIX Bug 2: se l'ad non è pronto avvia (o mantieni) il caricamento e
    // recupera sempre il completer DOPO la chiamata a loadRewardedAd(),
    // così è garantito che esista anche se il load era già in corso.
    if (_rewardedAd == null) {
      LogService().log("RewardedAdService: No ad ready. Trying to load and wait up to ${waitTimeout.inSeconds}s...");
      loadRewardedAd();

      // A questo punto _loadCompleter è sicuramente non-null
      // (creato/verificato dentro loadRewardedAd).
      final completerToAwait = _loadCompleter;
      if (completerToAwait != null) {
        try {
          await completerToAwait.future.timeout(waitTimeout);
        } catch (e) {
          LogService().log("RewardedAdService: Ad was not loaded in time or load failed: $e");
        }
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

    final showCompleter = Completer<bool>();
    bool hasEarnedReward = false;

    // FIX Bug 1: non cattenare la oldCallback (quella di _attachDefaultCallbacks)
    // perché provocherebbe un doppio dispose/loadRewardedAd.
    // Gestiamo direttamente tutto qui: dispose + preload del prossimo ad.
    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (shownAd) {
        LogService().log("RewardedAdService: onAdShowedFullScreenContent.");
      },
      onAdImpression: (shownAd) {
        LogService().log("RewardedAdService: onAdImpression.");
      },
      onAdDismissedFullScreenContent: (shownAd) {
        LogService().log("RewardedAdService: onAdDismissedFullScreenContent.");
        _isShowingAd = false;
        shownAd.dispose();
        loadRewardedAd(); // preload del prossimo

        if (!showCompleter.isCompleted) {
          showCompleter.complete(hasEarnedReward);
        }
      },
      onAdFailedToShowFullScreenContent: (shownAd, error) {
        LogService().log("RewardedAdService: onAdFailedToShowFullScreenContent: $error");
        _isShowingAd = false;
        shownAd.dispose();
        loadRewardedAd();

        if (!showCompleter.isCompleted) {
          showCompleter.complete(false);
        }
      },
    );

    try {
      LogService().log("RewardedAdService: Calling show() on AdHash: ${ad.hashCode}");

      ad.show(
        onUserEarnedReward: (rewardAd, reward) {
          // FIX Bug 1: il premio viene settato prima che onAdDismissedFullScreenContent
          // venga chiamato, quindi hasEarnedReward sarà true quando il
          // completer viene completato.
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

      if (!showCompleter.isCompleted) {
        showCompleter.complete(false);
      }
    }

    return showCompleter.future.timeout(
      const Duration(seconds: 45),
      onTimeout: () {
        LogService().log("RewardedAdService: show flow timed out.");
        _isShowingAd = false;
        loadRewardedAd();
        return false;
      },
    );
  }

  /// Callback standard legate al ciclo di vita dell'ad (usate solo durante il preload,
  /// NON durante la visualizzazione — in quel caso gestisce tutto showAdIfAvailable).
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
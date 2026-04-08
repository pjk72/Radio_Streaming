import 'dart:async';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_remote_config/firebase_remote_config.dart';
import 'log_service.dart';

class RewardedAdService {
  static final RewardedAdService _instance = RewardedAdService._internal();
  factory RewardedAdService() => _instance;
  RewardedAdService._internal();

  RewardedAd? _rewardedAd;
  bool _isAdLoading = false;

  /// Valore del premio da mostrare nella UI per i calcoli stimati.
  /// Questo valore viene aggiornato automaticamente non appena viene ricevuto un premio reale da AdMob.
  static int rewardAmount = 0;
  static const String _keyRewardAmount = 'ad_reward_amount';

  /// Carica l'ultimo valore del premio salvato e lo sincronizza con Firebase Remote Config se possibile.
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    
    // 1. Carica prima il valore locale (cache) per velocità
    rewardAmount = prefs.getInt(_keyRewardAmount) ?? 0;
    
    // 2. Tenta di aggiornare il valore da Firebase Remote Config in tempo reale
    try {
      final remoteConfig = FirebaseRemoteConfig.instance;
      // Il fetch viene già gestito altrove in main.dart o EntitlementService, 
      // ma ci assicuriamo di avere l'ultimo valore disponibile
      final remoteValue = remoteConfig.getInt('ad_reward_amount');
      if (remoteValue > 0 && remoteValue != rewardAmount) {
        rewardAmount = remoteValue;
        await prefs.setInt(_keyRewardAmount, rewardAmount);
        LogService().log("RewardedAdService: Initialized with Firebase Remote Config value: $rewardAmount");
      }
    } catch (e) {
      LogService().log("RewardedAdService: Error reading from Remote Config during init: $e");
    }

    // Pre-carichiamo l'annuncio subito
    RewardedAdService().loadRewardedAd();
  }

  static Future<void> _updateRewardAmount(int amount) async {
    if (amount <= 0 || amount == rewardAmount) return;
    rewardAmount = amount;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyRewardAmount, rewardAmount);
    LogService().log("RewardedAdService: Reward amount updated to $amount and saved.");
  }

  // IDs forniti dall'utente
  final String _adUnitId = kReleaseMode 
      ? 'ca-app-pub-3351319116434923/2436643024' 
      : 'ca-app-pub-3940256099942544/5224354917'; // Test ID for debug

  void loadRewardedAd() {
    if (_isAdLoading || _rewardedAd != null) return;
    _isAdLoading = true;

    RewardedAd.load(
      adUnitId: _adUnitId,
      request: const AdRequest(),
      rewardedAdLoadCallback: RewardedAdLoadCallback(
        onAdLoaded: (ad) {
          LogService().log("RewardedAdService: Ad loaded successfully.");
          _rewardedAd = ad;
          _isAdLoading = false;
          
          _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
            onAdDismissedFullScreenContent: (ad) {
              ad.dispose();
              _rewardedAd = null;
              loadRewardedAd(); // Pre-load next
            },
            onAdFailedToShowFullScreenContent: (ad, error) {
              ad.dispose();
              _rewardedAd = null;
              loadRewardedAd();
            },
          );
        },
        onAdFailedToLoad: (error) {
          LogService().log("RewardedAdService: Ad failed to load: $error");
          _rewardedAd = null;
          _isAdLoading = false;
        },
      ),
    );
  }

  Future<bool> showAdIfAvailable({
    required void Function(AdWithoutView ad, RewardItem reward) onUserEarnedReward,
    required VoidCallback onAdNotAvailable,
  }) async {
    if (_rewardedAd == null) {
      loadRewardedAd();
      onAdNotAvailable();
      return false;
    }

    final completer = Completer<bool>();
    bool earned = false;

    // Extend callback to resolve completer
    final oldCallback = _rewardedAd!.fullScreenContentCallback;
    _rewardedAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: (ad) {
        if (oldCallback?.onAdDismissedFullScreenContent != null) {
          oldCallback!.onAdDismissedFullScreenContent!(ad);
        }
        if (!completer.isCompleted) completer.complete(earned);
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        if (oldCallback?.onAdFailedToShowFullScreenContent != null) {
          oldCallback!.onAdFailedToShowFullScreenContent!(ad, error);
        }
        if (!completer.isCompleted) completer.complete(false);
      },
    );

    await _rewardedAd!.show(onUserEarnedReward: (ad, reward) {
      earned = true;
      // Aggiorna dinamicamente il valore del premio basandosi sull'unità reale
      _updateRewardAmount(reward.amount.toInt());
      onUserEarnedReward(ad, reward);
    });

    return completer.future;
  }
}

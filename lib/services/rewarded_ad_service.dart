import 'dart:async';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:flutter/foundation.dart';
import 'log_service.dart';

class RewardedAdService {
  static final RewardedAdService _instance = RewardedAdService._internal();
  factory RewardedAdService() => _instance;
  RewardedAdService._internal();

  RewardedAd? _rewardedAd;
  bool _isAdLoading = false;

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
      onUserEarnedReward(ad, reward);
    });

    return completer.future;
  }
}

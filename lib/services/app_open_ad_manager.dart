import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'entitlement_service.dart';

class AppOpenAdManager {
  static final AppOpenAdManager _instance = AppOpenAdManager._internal();
  factory AppOpenAdManager() => _instance;
  AppOpenAdManager._internal();

  AppOpenAd? _appOpenAd;
  bool _isShowingAd = false;
  bool _isFirstAdShown = false;
  EntitlementService? _entitlements;

  final String adUnitId = kIsWeb
      ? ''
      : (Platform.isAndroid
            ? 'ca-app-pub-3351319116434923/1642535796'
            : 'ca-app-pub-3351319116434923/1642535796');

  void init(EntitlementService entitlements) {
    _entitlements = entitlements;
    // Try to load only if the feature is enabled (or defer until loaded)
    loadAd();
  }

  void loadAd() {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return;

    AppOpenAd.load(
      adUnitId: adUnitId,
      request: const AdRequest(),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (ad) {
          _appOpenAd = ad;
          if (!_isFirstAdShown) {
            if (_entitlements != null &&
                _entitlements!.isFeatureEnabled('app_open_ad')) {
              showAdIfAvailable();
            }
            _isFirstAdShown = true;
          }
        },
        onAdFailedToLoad: (error) {
          debugPrint('AppOpenAd failed to load: $error');
        },
      ),
    );
  }

  void showAdIfAvailable() {
    if (_entitlements != null &&
        !_entitlements!.isFeatureEnabled('app_open_ad')) {
      return;
    }

    if (!isAdAvailable) {
      loadAd();
      return;
    }
    if (_isShowingAd) {
      return;
    }

    _appOpenAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) {
        _isShowingAd = true;
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        _isShowingAd = false;
        ad.dispose();
        _appOpenAd = null;
        loadAd();
      },
      onAdDismissedFullScreenContent: (ad) {
        _isShowingAd = false;
        ad.dispose();
        _appOpenAd = null;
        loadAd();
      },
    );
    _appOpenAd!.show();
  }

  bool get isAdAvailable => _appOpenAd != null;
}

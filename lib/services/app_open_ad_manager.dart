import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'entitlement_service.dart';
import 'log_service.dart';

class AppOpenAdManager {
  static final AppOpenAdManager _instance = AppOpenAdManager._internal();
  factory AppOpenAdManager() => _instance;
  AppOpenAdManager._internal();

  AppOpenAd? _appOpenAd;
  bool _isShowingAd = false;
  bool get isShowingAd => _isShowingAd;
  bool _isFirstAdShown = false;
  bool _isLoadingAd = false;
  EntitlementService? _entitlements;

  final String adUnitId = kReleaseMode 
      ? 'ca-app-pub-3351319116434923/1642535796'
      : 'ca-app-pub-3940256099942544/9257395915'; // Android App Open Test ID

  void init(EntitlementService entitlements) {
    if (_entitlements != null) {
      _entitlements!.removeListener(_onEntitlementsChanged);
    }
    _entitlements = entitlements;
    _entitlements!.addListener(_onEntitlementsChanged);
    // Try to load only if the feature is enabled (or defer until loaded)
    loadAd();
  }

  void _onEntitlementsChanged() {
    if (_entitlements != null && _entitlements!.isFeatureEnabled('app_open_ad')) {
      if (!isAdAvailable && !_isShowingAd && !_isLoadingAd) {
        loadAd();
      }
    } else {
      // Feature disabled, dispose ad if any
      _appOpenAd?.dispose();
      _appOpenAd = null;
    }
  }

  void loadAd() {
    if (kIsWeb || !Platform.isAndroid) return;
    if (_isLoadingAd) return;

    // Check if feature is enabled BEFORE making the request
    if (_entitlements != null &&
        !_entitlements!.isFeatureEnabled('app_open_ad')) {
      LogService().log('AppOpenAd: Feature disabled for this user. Skipping ad request.');
      return;
    }

    _isLoadingAd = true;
    AppOpenAd.load(
      adUnitId: adUnitId,
      request: const AdRequest(),
      adLoadCallback: AppOpenAdLoadCallback(
        onAdLoaded: (ad) {
          LogService().log('AppOpenAd: onAdLoaded successfully');
          _isLoadingAd = false;
          _appOpenAd = ad;
          if (!_isFirstAdShown) {
            LogService().log('AppOpenAd: First ad loaded, checking entitlements for showAdIfAvailable');
            if (_entitlements != null &&
                _entitlements!.isFeatureEnabled('app_open_ad')) {
              showAdIfAvailable();
            } else {
              LogService().log('AppOpenAd: Entitlements returned false inside onAdLoaded');
            }
            _isFirstAdShown = true;
          }
        },
        onAdFailedToLoad: (error) {
          LogService().log('AppOpenAd: onAdFailedToLoad - Error: $error');
          _isLoadingAd = false;
          debugPrint('AppOpenAd failed to load: $error');
        },
      ),
    );
  }

  void showAdIfAvailable() {
    LogService().log('AppOpenAd: showAdIfAvailable() called');
    if (_entitlements != null &&
        !_entitlements!.isFeatureEnabled('app_open_ad')) {
      LogService().log('AppOpenAd: show blocked by entitlements');
      return;
    }

    if (!isAdAvailable) {
      LogService().log('AppOpenAd: show blocked - Ad is not available yet, calling loadAd()');
      loadAd();
      return;
    }
    if (_isShowingAd) {
      LogService().log('AppOpenAd: show blocked - Ad is already showing');
      return;
    }

    LogService().log('AppOpenAd: Setting up callbacks and attempting to show ad');
    _appOpenAd!.fullScreenContentCallback = FullScreenContentCallback(
      onAdShowedFullScreenContent: (ad) {
        LogService().log('AppOpenAd: onAdShowedFullScreenContent');
        _isShowingAd = true;
      },
      onAdFailedToShowFullScreenContent: (ad, error) {
        LogService().log('AppOpenAd: onAdFailedToShowFullScreenContent - Error: $error');
        _isShowingAd = false;
        ad.dispose();
        _appOpenAd = null;
        loadAd();
      },
      onAdDismissedFullScreenContent: (ad) {
        LogService().log('AppOpenAd: onAdDismissedFullScreenContent');
        _isShowingAd = false;
        ad.dispose();
        _appOpenAd = null;
        loadAd();
      },
    );

    try {
      _appOpenAd!.show();
      LogService().log('AppOpenAd: show() executed without exceptions');
    } catch (e) {
      LogService().log('AppOpenAd: Exception during show(): $e');
    }
  }

  bool get isAdAvailable => _appOpenAd != null;
}

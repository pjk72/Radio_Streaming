import 'package:flutter/material.dart';
import 'dart:io' show Platform;
import 'package:flutter_ironsource_x/ironsource.dart';
import 'package:flutter_ironsource_x/banner.dart';
import '../services/log_service.dart';

class BannerAdWidget extends StatefulWidget {
  const BannerAdWidget({super.key});

  @override
  State<BannerAdWidget> createState() => _BannerAdWidgetState();
}

class _BannerAdWidgetState extends State<BannerAdWidget> {
  // We keep Mobile Ads available if we need to switch later,
  // but this widget now primarily uses IronSource (which mediates AdMob).

  IronSourceBannerAd? _ironSourceBannerAd;

  @override
  void initState() {
    super.initState();
    LogService().log("BannerAdWidget: initState");
    _loadIronSourceAd();
  }

  void _loadIronSourceAd() {
    if (!Platform.isAndroid && !Platform.isIOS) {
      LogService().log("BannerAdWidget: Not Android/iOS, skipping ad load");
      return;
    }

    LogService().log("BannerAdWidget: Attempting to load IronSource Banner...");

    // IronSource Banner
    _ironSourceBannerAd = IronSourceBannerAd(
      keepAlive: true,
      listener: _MyIronSourceBannerListener(),
      size: BannerSize.BANNER, // Explicit standard size
    );
    LogService().log("BannerAdWidget: IronSourceBannerAd instance created.");
  }

  @override
  void dispose() {
    // _ironSourceBannerAd does not require explicit disposal in this plugin version usually,
    // but we respect the widget lifecycle.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isAndroid || Platform.isIOS) {
      // Return the IronSource Banner Widget
      LogService().log("BannerAdWidget: Building Banner View");
      return Container(
        alignment: Alignment.bottomCenter,
        width: double.infinity,
        height: 50, // Standard Banner Height
        child: _ironSourceBannerAd != null
            ? _ironSourceBannerAd!
            : const SizedBox.shrink(),
      );
    }
    return const SizedBox.shrink();
  }
}

class _MyIronSourceBannerListener extends IronSourceBannerListener {
  @override
  void onBannerAdLoaded() {
    LogService().log("IronSource Banner Callback: Loaded");
    debugPrint("IronSource Banner Loaded");
  }

  @override
  void onBannerAdLoadFailed(Map<String, dynamic> error) {
    LogService().log("IronSource Banner Callback: Failed with error: $error");
    debugPrint("IronSource Banner Failed: $error");
  }

  @override
  void onBannerAdClicked() {
    LogService().log("IronSource Banner Callback: Clicked");
    debugPrint("IronSource Banner Clicked");
  }

  @override
  void onBannerAdLeftApplication() {
    LogService().log("IronSource Banner Callback: Left Application");
    debugPrint("IronSource Banner Left App");
  }

  @override
  void onBannerAdScreenPresented() {
    LogService().log("IronSource Banner Callback: Screen Presented");
    debugPrint("IronSource Banner Presented");
  }

  @override
  void onBannerAdScreenDismissed() {
    LogService().log("IronSource Banner Callback: Screen Dismissed");
    debugPrint("IronSource Banner Dismissed");
  }
}

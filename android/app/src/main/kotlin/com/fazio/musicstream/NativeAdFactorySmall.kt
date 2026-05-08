package com.fazio.musicstream

import android.content.Context
import android.view.LayoutInflater
import android.widget.Button
import android.widget.ImageView
import android.widget.TextView
import com.google.android.gms.ads.nativead.NativeAd
import com.google.android.gms.ads.nativead.NativeAdView
import io.flutter.plugins.googlemobileads.GoogleMobileAdsPlugin

class NativeAdFactorySmall(private val context: Context) : GoogleMobileAdsPlugin.NativeAdFactory {
    override fun createNativeAd(
        nativeAd: NativeAd,
        customOptions: Map<String, Any>?
    ): NativeAdView {
        val nativeAdView = LayoutInflater.from(context)
            .inflate(R.layout.native_ad_layout, null) as NativeAdView

        // Bind Views
        nativeAdView.iconView = nativeAdView.findViewById(R.id.ad_app_icon)
        nativeAdView.headlineView = nativeAdView.findViewById(R.id.ad_headline)
        nativeAdView.bodyView = nativeAdView.findViewById(R.id.ad_body)
        nativeAdView.callToActionView = nativeAdView.findViewById(R.id.ad_call_to_action)
        // We do not bind MediaView because we are not showing the main media asset
        // This avoids the validation error "MediaView not used for main image" because we simply don't show it.

        // Populate Views
        nativeAdView.iconView?.let {
            if (nativeAd.icon == null) {
                it.visibility = android.view.View.GONE
            } else {
                (it as ImageView).setImageDrawable(nativeAd.icon?.drawable)
                it.visibility = android.view.View.VISIBLE
            }
        }
        
        nativeAdView.headlineView?.let {
            (it as TextView).text = nativeAd.headline
        }
        
        nativeAdView.bodyView?.let {
             (it as TextView).text = nativeAd.body
        }
        
        nativeAdView.callToActionView?.let {
            if (nativeAd.callToAction == null) {
                it.visibility = android.view.View.INVISIBLE
            } else {
                (it as Button).text = nativeAd.callToAction
                it.visibility = android.view.View.VISIBLE
            }
        }

        nativeAdView.setNativeAd(nativeAd)

        return nativeAdView
    }
}

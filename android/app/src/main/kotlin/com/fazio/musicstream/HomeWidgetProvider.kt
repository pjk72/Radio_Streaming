package com.fazio.musicstream

import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.SharedPreferences
import android.widget.RemoteViews
import android.graphics.BitmapFactory
import android.view.View
import es.antonborri.home_widget.HomeWidgetProvider
import es.antonborri.home_widget.HomeWidgetLaunchIntent
import java.io.File

class HomeWidgetProvider : HomeWidgetProvider() {
    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences
    ) {
        appWidgetIds.forEach { widgetId ->
            val views = RemoteViews(context.packageName, R.layout.widget_layout).apply {
                // Text Updates
                val title = widgetData.getString("title", "MusicStream")
                val subtitle = widgetData.getString("subtitle", "Tap to listen")
                setTextViewText(R.id.widget_title, title)
                setTextViewText(R.id.widget_subtitle, subtitle)

                // Image Update
                val imagePath = widgetData.getString("album_art", null)
                if (imagePath != null) {
                    val file = File(imagePath)
                    if (file.exists()) {
                        val bitmap = BitmapFactory.decodeFile(file.absolutePath)
                        setImageViewBitmap(R.id.widget_image, bitmap)
                    } else {
                         // Default Icon if file missing
                        setImageViewResource(R.id.widget_image, R.mipmap.ic_launcher)
                    }
                } else {
                    // Default Icon
                    setImageViewResource(R.id.widget_image, R.mipmap.ic_launcher)
                }
                
                // PendingIntent to launch app
                val pendingIntent = HomeWidgetLaunchIntent.getActivity(context, MainActivity::class.java)
                setOnClickPendingIntent(R.id.widget_container, pendingIntent)
            }
            appWidgetManager.updateAppWidget(widgetId, views)
        }
    }
}

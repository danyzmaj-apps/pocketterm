package com.danyzmaj.pocketterm

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.Context
import android.widget.RemoteViews

/** A 1×1 tap target (the iPhone's New idea widget): opens pocketterm://add, the add field with the keyboard up. */
class NewIdeaWidget : AppWidgetProvider() {
    override fun onUpdate(c: Context, manager: AppWidgetManager, ids: IntArray) {
        val v = RemoteViews(c.packageName, R.layout.widget_new_idea)
        v.setOnClickPendingIntent(R.id.widget_root, openLink(c, "pocketterm://add"))
        for (id in ids) manager.updateAppWidget(id, v)
    }
}

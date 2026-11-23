package com.taoo.xiutu.ui

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/** 美颜、美体、美发、妆容用"女"还是"男"的那一套。全 App 共用一个开关，记住上次选的。 */
object GenderSetting {
    private const val KEY = "gender.male"

    private var prefs: SharedPreferences? = null
    private var maleState by mutableStateOf(false)

    var isMale: Boolean
        get() = maleState
        set(value) {
            maleState = value
            prefs?.edit()?.putBoolean(KEY, value)?.apply()
        }

    fun init(context: Context) {
        if (prefs != null) return
        val p = context.applicationContext.getSharedPreferences("xiutu", Context.MODE_PRIVATE)
        prefs = p
        maleState = p.getBoolean(KEY, false)
    }
}

/** 面板上的"女 / 男"切换。 */
@Composable
fun GenderToggle(modifier: Modifier = Modifier) {
    val male = GenderSetting.isMale
    Row(modifier.clip(CircleShape).background(Theme.chip).padding(2.dp)) {
        GenderItem("女", !male) { GenderSetting.isMale = false }
        GenderItem("男", male) { GenderSetting.isMale = true }
    }
}

@Composable
private fun GenderItem(title: String, on: Boolean, onClick: () -> Unit) {
    Box(
        Modifier.size(width = 34.dp, height = 26.dp).clip(CircleShape)
            .background(if (on) Theme.accent else Color.Transparent).tap(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            title, fontSize = 13.sp, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal,
            color = if (on) Color.Black else Color.White, maxLines = 1,
        )
    }
}

package com.taoo.xiutu.history

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.taoo.xiutu.editor.EditRecipe
import com.taoo.xiutu.editor.RecipeAction
import com.taoo.xiutu.editor.RecipeStep
import com.taoo.xiutu.ui.PillButton
import com.taoo.xiutu.ui.Theme
import com.taoo.xiutu.ui.sym

/** 历史图库里一张图的处理步骤：从原图开始一步一步做了什么。可以套到一张新照片上。 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun RecipeSheet(recipe: EditRecipe, onDismiss: () -> Unit, onApply: () -> Unit) {
    ModalBottomSheet(onDismissRequest = onDismiss, containerColor = Theme.panel) {
        Text(
            "处理步骤", fontSize = 16.sp, fontWeight = FontWeight.SemiBold, color = Color.White, textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth().padding(bottom = 10.dp),
        )
        Column(Modifier.weight(1f, fill = false).verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)) {
            recipe.steps.forEachIndexed { i, step ->
                StepRow(i + 1, step)
                if (i < recipe.steps.size - 1) {
                    HorizontalDivider(Modifier.padding(start = 64.dp), color = Color.White.copy(alpha = 0.08f))
                }
            }
        }
        PillButton(
            "套用到新照片", Modifier.fillMaxWidth().padding(16.dp), color = Theme.accent, enabled = recipe.copyable > 0,
            onClick = onApply,
        )
    }
}

@Composable
private fun StepRow(n: Int, step: RecipeStep) {
    val skipped = step.action == null
    Row(
        Modifier.fillMaxWidth().alpha(if (skipped) 0.45f else 1f).padding(vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Text("$n", fontSize = 13.sp, fontWeight = FontWeight.SemiBold, color = Theme.dim, textAlign = TextAlign.Center, modifier = Modifier.width(18.dp))
        Box(Modifier.width(26.dp), contentAlignment = Alignment.Center) {
            Icon(sym(step.symbol), null, tint = Color.White, modifier = Modifier.size(20.dp))
        }
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(step.title, fontSize = 15.sp, fontWeight = FontWeight.Medium, color = Color.White)
                if (step.action is RecipeAction.AI) {
                    Text(
                        "AI", fontSize = 10.sp, fontWeight = FontWeight.Bold, color = Color.Black, lineHeight = 13.sp,
                        modifier = Modifier.background(Theme.accent, CircleShape).padding(horizontal = 5.dp, vertical = 1.dp),
                    )
                }
            }
            if (step.detail.isNotEmpty()) {
                Text(step.detail, fontSize = 12.5.sp, color = Theme.dim, maxLines = 2)
            }
        }
        if (skipped) {
            Spacer(Modifier.width(8.dp))
            Text("跳过", fontSize = 12.sp, color = Theme.dim)
        }
    }
}

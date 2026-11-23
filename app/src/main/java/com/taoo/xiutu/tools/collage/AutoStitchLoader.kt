package com.taoo.xiutu.tools.collage

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Rect
import android.net.Uri
import android.provider.MediaStore
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.picker.PhotoLibrary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/** 主页"自动拼图"：从相册里找最近一组连续的截图（同样大小、前后几分钟内截的），拼成长图存到临时文件。 */
object AutoStitchLoader {
    enum class Failure(val message: String) {
        NO_ACCESS("没有相册权限"),
        NOT_ENOUGH("相册里最近没有连续的截图"),
        FAILED("这几张截图拼不起来"),
    }

    /** 成功时 file 是拼好的长图，失败时 failure 说明原因。 */
    class Result(val file: File?, val failure: Failure?)

    /** 一组最多几张。 */
    const val MAX_COUNT = 15
    /** 相邻两张截图最多隔多久还算同一组（毫秒）。 */
    const val MAX_GAP = 5 * 60 * 1000L

    private class Shot(val uri: Uri, val width: Int, val height: Int, val time: Long, val id: Long)

    suspend fun run(context: Context): Result = withContext(Dispatchers.Default) {
        if (!PhotoLibrary.granted(context)) return@withContext Result(null, Failure.NO_ACCESS)
        val shots = runCatching { recentGroup(context) }.getOrDefault(emptyList())
        if (shots.size < 2) return@withContext Result(null, Failure.NOT_ENOUGH)
        // 先一张一张读出来算每一行的缩略，读完就扔：十几张整图同时放在内存里太大。
        val sigs = ArrayList<AutoStitch.Signature>()
        val used = ArrayList<Shot>()
        for (shot in shots) {
            val img = decode(context, shot) ?: continue
            sigs += AutoStitch.Signature.of(img.width, img.height) { y, out -> img.getPixels(out, 0, img.width, 0, y, img.width, 1) }
            used += shot
            img.recycle()
        }
        if (sigs.size < 2) return@withContext Result(null, Failure.NOT_ENOUGH)
        val plan = AutoStitch.plan(sigs) ?: return@withContext Result(null, Failure.FAILED)
        val file = runCatching { draw(context, used, plan) }.getOrNull()
        if (file == null) Result(null, Failure.FAILED) else Result(file, null)
    }

    /** 按拼法把每一段画到长图上，存成 PNG。 */
    private fun draw(context: Context, shots: List<Shot>, plan: AutoStitch.Plan): File? {
        val out = Bitmap.createBitmap(plan.width, plan.height, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        var y = 0
        for (piece in plan.pieces) {
            val img = decode(context, shots[piece.index])
            if (img != null && img.width == plan.width) {
                canvas.drawBitmap(img, Rect(0, piece.from, plan.width, piece.from + piece.rows), Rect(0, y, plan.width, y + piece.rows), null)
                img.recycle()
            }
            y += piece.rows
        }
        // 上一次拼的临时文件用不着了
        context.cacheDir.listFiles { f -> f.name.startsWith("autostitch-") }?.forEach { it.delete() }
        val file = File(context.cacheDir, "autostitch-${UUID.randomUUID()}.png")
        val ok = file.outputStream().use { out.compress(Bitmap.CompressFormat.PNG, 100, it) }
        out.recycle()
        return if (ok) file else null
    }

    /** 原尺寸读一张截图；读出来的大小和相册记的不一样就不要。 */
    private fun decode(context: Context, shot: Shot): Bitmap? {
        val img = Img.decode(context, shot.uri) ?: return null
        if (shot.width > 0 && shot.height > 0 && (img.width != shot.width || img.height != shot.height)) return null
        return img
    }

    /** 最新的那张截图往前数，大小一样、前后隔得不久的算一组。按时间先后返回。 */
    private fun recentGroup(context: Context): List<Shot> {
        val all = ArrayList<Shot>()
        val path = MediaStore.Images.Media.RELATIVE_PATH
        val bucket = MediaStore.Images.Media.BUCKET_DISPLAY_NAME
        val names = listOf("%Screenshot%", "%截屏%", "%截图%")
        val selection = names.joinToString(" OR ") { "$path LIKE ? OR $bucket LIKE ?" }
        val args = names.flatMap { listOf(it, it) }.toTypedArray()
        context.contentResolver.query(
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
            arrayOf(
                MediaStore.Images.Media._ID, MediaStore.Images.Media.WIDTH, MediaStore.Images.Media.HEIGHT,
                MediaStore.Images.Media.DATE_TAKEN, MediaStore.Images.Media.DATE_ADDED,
            ),
            selection, args, "${MediaStore.Images.Media.DATE_ADDED} DESC",
        )?.use { c ->
            while (c.moveToNext() && all.size < 60) {
                val id = c.getLong(0)
                val taken = if (c.isNull(3)) 0L else c.getLong(3)
                val time = if (taken > 0) taken else c.getLong(4) * 1000
                all += Shot(ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id), c.getInt(1), c.getInt(2), time, id)
            }
        }
        // 同一秒里截的几张按拍摄时间（毫秒）和编号排准
        all.sortWith(compareByDescending<Shot> { it.time }.thenByDescending { it.id })
        val group = ArrayList<Shot>()
        for (shot in all) {
            val last = group.lastOrNull()
            if (last != null && (shot.width != last.width || shot.height != last.height || last.time - shot.time > MAX_GAP)) break
            group += shot
            if (group.size >= MAX_COUNT) break
        }
        return group.reversed()
    }
}

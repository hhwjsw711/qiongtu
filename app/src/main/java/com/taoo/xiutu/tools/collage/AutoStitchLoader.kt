package com.taoo.xiutu.tools.collage

import android.content.ContentUris
import android.content.Context
import android.graphics.Bitmap
import android.net.Uri
import android.provider.MediaStore
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.picker.PhotoLibrary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

/** 自动拼图的结果：按顺序的截图文件，和每张沿竖直方向裁掉的开头、结尾比例。打开拼接页时预先摆好。 */
class AutoStitchJob(val files: List<File>, val cropStart: List<Float>, val cropEnd: List<Float>)

/** 主页"自动拼图"：从相册里找最近一组连续的截图（同样大小、前后几分钟内截的），算好怎么接。 */
object AutoStitchLoader {
    enum class Failure(val message: String) {
        NO_ACCESS("没有相册权限"),
        NOT_ENOUGH("相册里最近没有连续的截图"),
        FAILED("这几张截图拼不起来"),
    }

    /** 成功时 job 是算好的拼法，失败时 failure 说明原因。 */
    class Result(val job: AutoStitchJob?, val failure: Failure?)

    /** 主页算好、等编辑器拿走的那一组。 */
    var pending: AutoStitchJob? = null

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
        val plan = AutoStitch.plan(sigs, navBarHeight(context, sigs[0].width, sigs[0].rows)) ?: return@withContext Result(null, Failure.FAILED)
        val job = runCatching { copy(context, used, plan, sigs[0].rows) }.getOrNull()
        if (job == null) Result(null, Failure.FAILED) else Result(job, null)
    }

    /** 截图和本机屏幕一样大（竖屏）时，底部系统导航栏 / 手势条的高度；别的设备截的图返回 0。 */
    private fun navBarHeight(context: Context, width: Int, height: Int): Int {
        val res = context.resources
        val dm = res.displayMetrics
        val wm = context.getSystemService(android.view.WindowManager::class.java) ?: return 0
        val bounds = wm.maximumWindowMetrics.bounds
        if (width != minOf(bounds.width(), bounds.height()) || height != maxOf(bounds.width(), bounds.height())) return 0
        val id = res.getIdentifier("navigation_bar_height", "dimen", "android")
        return if (id > 0) res.getDimensionPixelSize(id) else (24 * dm.density).toInt()
    }

    /** 用到的截图原文件复制到缓存目录，算出每张两头裁掉的比例。 */
    private fun copy(context: Context, shots: List<Shot>, plan: AutoStitch.Plan, rows: Int): AutoStitchJob? {
        // 上一次的临时文件用不着了
        context.cacheDir.listFiles { f -> f.name.startsWith("autostitch-") }?.forEach { it.deleteRecursively() }
        val dir = File(context.cacheDir, "autostitch-${UUID.randomUUID()}").apply { mkdirs() }
        val h = rows.toFloat()
        val files = ArrayList<File>()
        val starts = ArrayList<Float>()
        val ends = ArrayList<Float>()
        for ((k, piece) in plan.pieces.withIndex()) {
            val file = File(dir, "$k")
            val ok = context.contentResolver.openInputStream(shots[piece.index].uri)?.use { input ->
                file.outputStream().use { input.copyTo(it) }
                true
            } ?: false
            if (!ok) return null
            files += file
            starts += piece.from / h
            ends += (rows - piece.from - piece.rows) / h
        }
        return AutoStitchJob(files, starts, ends)
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

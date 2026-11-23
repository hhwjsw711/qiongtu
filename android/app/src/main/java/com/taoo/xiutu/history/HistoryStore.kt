package com.taoo.xiutu.history

import android.content.Context
import android.content.SharedPreferences
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.os.Handler
import android.os.Looper
import android.util.LruCache
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.taoo.xiutu.core.Img
import com.taoo.xiutu.core.Saver
import com.taoo.xiutu.editor.EditRecipe
import com.taoo.xiutu.editor.SaveOptions
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import kotlin.math.max
import kotlin.math.roundToInt

/** 历史图库里的一张图。date 是毫秒时间戳；source 是从哪个功能存进来的；ext 是 jpg / heic / png。 */
@Serializable
data class HistoryItem(val id: String, val date: Long, val source: String, val ext: String, val width: Int, val height: Int)

/**
 * 历史图库：保存图片时可以顺手在 App 里留一份。图存在 App 私有目录里，不进相册。
 * 可以设密码：只存一份加盐的 SHA-256 摘要；它锁的是进图库的门。
 */
object HistoryStore {
    /** 新的在前。 */
    var items by mutableStateOf<List<HistoryItem>>(emptyList())
        private set
    /** 保存图片时要不要同时存一份进来。 */
    var enabled by mutableStateOf(true)
        private set
    var hasPassword by mutableStateOf(false)
        private set
    val count: Int get() = items.size

    private var folder: File? = null
    private var prefs: SharedPreferences? = null
    private val lock = Any()
    /** 真正的列表（后台线程也会改），items 是主线程上的那份拷贝。 */
    private var all: List<HistoryItem> = emptyList()
    private val main = Handler(Looper.getMainLooper())
    private val thumbs = LruCache<String, Bitmap>(240)
    private val json = Json { ignoreUnknownKeys = true }
    private const val PASSWORD_KEY = "history.password"

    fun init(context: Context) {
        if (folder != null) return
        val dir = File(context.filesDir, "History").apply { mkdirs() }
        folder = dir
        val p = context.getSharedPreferences("history", Context.MODE_PRIVATE)
        prefs = p
        enabled = p.getBoolean("history.enabled", true)
        hasPassword = !p.getString(PASSWORD_KEY, "").isNullOrEmpty()
        val list = runCatching { json.decodeFromString<List<HistoryItem>>(File(dir, "index.json").readText()) }.getOrDefault(emptyList())
        // 文件不在了的条目不要
        all = list.filter { file(it).exists() }
        items = all
    }

    fun setEnabled(context: Context, on: Boolean) {
        init(context)
        enabled = on
        prefs?.edit()?.putBoolean("history.enabled", on)?.apply()
    }

    // MARK: 文件

    fun file(item: HistoryItem): File = File(folder, item.id + "." + item.ext)

    private fun thumbFile(id: String) = File(folder, "$id.thumb.jpg")

    private fun recipeFile(id: String) = File(folder, "$id.recipe.json")

    /** 这张图的处理步骤（从修图存进来的才有）。读文件，别在主线程上反复调。 */
    fun recipe(id: String): EditRecipe? {
        val f = recipeFile(id)
        if (folder == null || !f.exists()) return null
        return runCatching { EditRecipe.decode(f.readText()) }.getOrNull()
    }

    private fun saveIndex(list: List<HistoryItem>) {
        val dir = folder ?: return
        val tmp = File(dir, "index.json.tmp")
        runCatching {
            tmp.writeText(json.encodeToString(list))
            tmp.renameTo(File(dir, "index.json"))
        }
    }

    /** 状态只在主线程改。 */
    private fun publish() {
        val sync = { items = synchronized(lock) { all } }
        if (Looper.myLooper() == Looper.getMainLooper()) sync() else main.post(sync)
    }

    /** 存一张进来（阻塞，在后台线程调用）。ext 是 jpg / heic / png；recipe 是从修图存进来时的处理步骤。 */
    fun add(context: Context, data: ByteArray, ext: String, source: String, recipe: EditRecipe? = null) {
        init(context)
        val dir = folder ?: return
        val id = UUID.randomUUID().toString()
        if (recipe != null && recipe.steps.isNotEmpty()) runCatching { recipeFile(id).writeText(recipe.encode()) }
        val f = File(dir, "$id.$ext")
        runCatching { f.writeBytes(data) }.onFailure { return }
        var w = 0
        var h = 0
        val thumb = runCatching {
            ImageDecoder.decodeBitmap(ImageDecoder.createSource(java.nio.ByteBuffer.wrap(data))) { d, info, _ ->
                d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
                w = info.size.width
                h = info.size.height
                val long = max(w, h)
                if (long > 480) {
                    val k = 480f / long
                    d.setTargetSize((w * k).roundToInt().coerceAtLeast(1), (h * k).roundToInt().coerceAtLeast(1))
                }
            }
        }.getOrNull()
        if (thumb == null) { f.delete(); recipeFile(id).delete(); return }
        runCatching { thumbFile(id).writeBytes(Img.jpeg(Img.soft(thumb), 80)) }
        val item = HistoryItem(id, System.currentTimeMillis(), source, ext, w, h)
        synchronized(lock) {
            all = listOf(item) + all
            saveIndex(all)
        }
        publish()
    }

    fun add(context: Context, image: Bitmap, source: String) = add(context, Img.jpeg(image, 95), "jpg", source)

    /** 小图：先看内存里有没有，没有就从文件读。 */
    suspend fun thumbnail(item: HistoryItem): Bitmap? {
        thumbs.get(item.id)?.let { return it }
        val image = withContext(Dispatchers.IO) {
            Img.decode(thumbFile(item.id)) ?: Img.decode(file(item), 480)
        }
        if (image != null) thumbs.put(item.id, image)
        return image
    }

    fun delete(ids: Set<String>) {
        if (ids.isEmpty()) return
        synchronized(lock) {
            for (item in all) if (item.id in ids) {
                file(item).delete()
                thumbFile(item.id).delete()
                recipeFile(item.id).delete()
                thumbs.remove(item.id)
            }
            all = all.filter { it.id !in ids }
            saveIndex(all)
        }
        publish()
    }

    fun clear() = delete(synchronized(lock) { all.map { it.id }.toSet() })

    /** 存到系统相册。 */
    fun saveToGallery(context: Context, item: HistoryItem): Boolean = runCatching {
        val format = when (item.ext.lowercase()) {
            "png" -> SaveOptions.Format.PNG
            "heic", "heif" -> SaveOptions.Format.HEIC
            else -> SaveOptions.Format.JPEG
        }
        Saver.saveToGallery(context, file(item).readBytes(), format)
        true
    }.getOrDefault(false)

    // MARK: 密码

    private fun digest(password: String, salt: String): String =
        MessageDigest.getInstance("SHA-256").digest((salt + password).toByteArray()).joinToString("") { "%02x".format(it) }

    fun setPassword(password: String) {
        val salt = UUID.randomUUID().toString()
        prefs?.edit()?.putString(PASSWORD_KEY, salt + ":" + digest(password, salt))?.apply()
        hasPassword = true
    }

    fun removePassword() {
        prefs?.edit()?.remove(PASSWORD_KEY)?.apply()
        hasPassword = false
    }

    fun check(password: String): Boolean {
        val parts = prefs?.getString(PASSWORD_KEY, "").orEmpty().split(":", limit = 2)
        if (parts.size != 2) return false
        return digest(password, parts[0]) == parts[1]
    }
}

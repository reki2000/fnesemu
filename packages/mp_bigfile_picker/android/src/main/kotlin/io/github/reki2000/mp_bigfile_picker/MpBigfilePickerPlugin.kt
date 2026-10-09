package io.github.reki2000.mp_bigfile_picker

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry
import java.util.concurrent.Executors

/** directories and files of the Storage Access Framework: picks, walks and
 *  opens the documents. the documents are read by the file descriptors on the
 *  Dart side. */
class MpBigfilePickerPlugin : FlutterPlugin, ActivityAware, MethodCallHandler,
    PluginRegistry.ActivityResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private var activity: ActivityPluginBinding? = null
    private var pending: Result? = null
    private val executor = Executors.newSingleThreadExecutor()
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "mp_bigfile_picker")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity?.removeActivityResultListener(this)
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) =
        onAttachedToActivity(binding)

    override fun onDetachedFromActivityForConfigChanges() = onDetachedFromActivity()

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "pickDirectory" ->
                pick(result, REQUEST_DIRECTORY, Intent(Intent.ACTION_OPEN_DOCUMENT_TREE))
            "pickFiles" -> pick(result, REQUEST_FILES,
                Intent(Intent.ACTION_OPEN_DOCUMENT)
                    .addCategory(Intent.CATEGORY_OPENABLE)
                    .setType("*/*")
                    .putExtra(Intent.EXTRA_ALLOW_MULTIPLE, call.argument<Boolean>("multiple") == true))
            "restoreDirectory" -> background(result) {
                val tree = Uri.parse(call.arguments as String)
                if (isGranted(tree)) nameOf(tree) else null
            }
            "restoreFile" -> background(result) {
                val doc = Uri.parse(call.arguments as String)
                if (isGranted(doc)) displayName(doc) else null
            }
            "releaseDirectory" -> background(result) {
                release(Uri.parse(call.arguments as String))
                null
            }
            "walk" -> background(result) { walk(Uri.parse(call.arguments as String)) }
            "openFd" -> background(result) {
                context.contentResolver
                    .openFileDescriptor(Uri.parse(call.arguments as String), "r")
                    ?.detachFd()
            }
            else -> result.notImplemented()
        }
    }

    private fun pick(result: Result, request: Int, intent: Intent) {
        val a = activity?.activity
        if (a == null || pending != null) {
            result.error("busy", "no activity, or already picking", null)
            return
        }
        pending = result
        a.startActivityForResult(intent, request)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode != REQUEST_DIRECTORY && requestCode != REQUEST_FILES) return false
        val result = pending ?: return true
        pending = null
        val tree = data?.data
        if (resultCode != Activity.RESULT_OK || data == null ||
            (requestCode == REQUEST_DIRECTORY && tree == null)) {
            result.success(null)
            return true
        }
        if (tree != null && requestCode == REQUEST_DIRECTORY) {
            persist(tree)
            background(result) { mapOf("uri" to tree.toString(), "name" to nameOf(tree)) }
        } else {
            val clip = data.clipData
            val docs = if (clip != null) (0 until clip.itemCount).map { clip.getItemAt(it).uri }
                else listOfNotNull(data.data)
            docs.forEach { persist(it) }
            background(result) {
                docs.map { mapOf("uri" to it.toString(), "name" to displayName(it)) }
            }
        }
        return true
    }

    /** the permission is kept after a restart */
    private fun persist(uri: Uri) {
        try {
            context.contentResolver.takePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (e: SecurityException) {
            // not persistable: readable until the app ends
        }
    }

    /** gives back the permission kept by [persist] */
    private fun release(uri: Uri) {
        try {
            context.contentResolver.releasePersistableUriPermission(
                uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
        } catch (e: SecurityException) {
            // not persisted
        }
    }

    private fun isGranted(uri: Uri) = context.contentResolver.persistedUriPermissions
        .any { it.uri == uri && it.isReadPermission }

    private fun displayName(doc: Uri): String {
        context.contentResolver.query(doc, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)
            ?.use { if (it.moveToFirst()) return it.getString(0) }
        return doc.lastPathSegment?.substringAfterLast('/') ?: ""
    }

    private fun background(result: Result, f: () -> Any?) {
        executor.execute {
            try {
                val r = f()
                main.post { result.success(r) }
            } catch (e: Exception) {
                main.post { result.error("error", e.toString(), null) }
            }
        }
    }

    private fun nameOf(tree: Uri) = displayName(
        DocumentsContract.buildDocumentUriUsingTree(tree, DocumentsContract.getTreeDocumentId(tree)))

    /** [path, uri, path, uri, ...] of the files below the tree */
    private fun walk(tree: Uri): List<String> {
        val out = ArrayList<String>()
        val dirs = ArrayDeque<Pair<String, String>>() // document id, prefix
        dirs.add(DocumentsContract.getTreeDocumentId(tree) to "")
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID, Document.COLUMN_DISPLAY_NAME, Document.COLUMN_MIME_TYPE)
        while (dirs.isNotEmpty()) {
            val (id, prefix) = dirs.removeLast()
            val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, id)
            try {
                context.contentResolver.query(children, columns, null, null, null)?.use {
                    while (it.moveToNext()) {
                        val childId = it.getString(0)
                        val name = it.getString(1)
                        if (it.getString(2) == Document.MIME_TYPE_DIR) {
                            dirs.add(childId to "$prefix$name/")
                        } else {
                            out.add("$prefix$name")
                            out.add(DocumentsContract.buildDocumentUriUsingTree(tree, childId).toString())
                        }
                    }
                }
            } catch (e: Exception) {
                // an unreadable directory is skipped
            }
        }
        return out
    }

    companion object {
        private const val REQUEST_DIRECTORY = 0x6d62 // 'mb'
        private const val REQUEST_FILES = 0x6d63
    }
}

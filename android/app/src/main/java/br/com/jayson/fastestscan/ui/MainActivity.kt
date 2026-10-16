package br.com.jayson.fastestscan.ui

import android.Manifest
import android.content.ClipData
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.os.Bundle
import android.os.Environment
import android.util.Log
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.widget.Button
import android.widget.CheckBox
import android.widget.EditText
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.core.content.FileProvider
import br.com.jayson.fastestscan.R
import br.com.jayson.fastestscan.core.FrameFormat
import br.com.jayson.fastestscan.core.PdfName
import br.com.jayson.fastestscan.core.ScanOptions
import br.com.jayson.fastestscan.core.ScanSession
import br.com.jayson.fastestscan.core.ScanStatus
import br.com.jayson.fastestscan.source.CameraSource
import br.com.jayson.fastestscan.source.VideoFileSource
import java.io.File
import java.time.ZonedDateTime
import java.util.Date
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The one screen of the app. It has two sources for a scan:
 * - the camera: the pages come while the user films the book;
 * - a recorded video: the decoder runs one time through the file.
 *
 * The two sources give their frames to a [ScanSession]. The screen shows what the
 * library finds. When the scan has ended, the user saves the PDF, or shares it with
 * another app. [PdfName] gives the file name.
 *
 * The screen turns with the phone, and the camera frames turn with the screen. The
 * activity is not made new for a turn: it puts its views in the other direction
 * ([arrange]). During a scan with the camera, the screen keeps its direction: a
 * session has one rotation for all its frames.
 */
class MainActivity : ComponentActivity() {
    private lateinit var root: LinearLayout
    private lateinit var picture: View
    private lateinit var panel: View
    private lateinit var buttons: LinearLayout
    private lateinit var previewView: PreviewView
    private lateinit var overlay: PageOverlayView
    private lateinit var statusText: TextView
    private lateinit var lastPageView: ImageView
    private lateinit var cameraButton: Button
    private lateinit var videoButton: Button
    private lateinit var saveButton: Button
    private lateinit var shareButton: Button
    private lateinit var videoCheck: CheckBox
    private lateinit var nameGroup: View
    private lateinit var nameField: EditText
    private lateinit var prefixCheck: CheckBox
    private lateinit var preferences: SharedPreferences

    private var camera: CameraSource? = null

    /** The text about the video file of the last scan with the camera, or null. */
    private var videoNote: String? = null

    /** True when the camera gives its preview: a scan with the camera can start. */
    private var cameraReady = false

    /** The scan with the pages for the PDF. Only the main thread changes it. */
    private var session: ScanSession? = null

    /** The local date and time when the user started the last scan: the prefix of the PDF name. */
    private var scanStart: ZonedDateTime = ZonedDateTime.now()

    private var state = State.IDLE

    /** One thread for the slow steps that are not a render: the decoder, the end of a scan, the PDF files. */
    private val background: ExecutorService = Executors.newSingleThreadExecutor()
    private val cancelled = AtomicBoolean(false)

    /** True while a status waits for the main thread: the screen takes the last status only. */
    private val statusPending = AtomicBoolean(false)

    @Volatile
    private var lastStatus: Pair<Matrix?, ScanStatus>? = null

    /** The map from the upright frame to the preview view. Only the main thread uses it. */
    private val frameToView = Matrix()

    private enum class State { IDLE, CAMERA_SCAN, VIDEO_SCAN, FINISHING }

    private val cameraPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        if (granted) openCamera() else statusText.setText(R.string.status_camera_refused)
    }
    private val pickVideo = registerForActivityResult(ActivityResultContracts.GetContent()) { uri ->
        if (uri != null) scanVideo(uri)
    }
    private val createPdf = registerForActivityResult(ActivityResultContracts.CreateDocument(PDF_MIME_TYPE)) { uri ->
        if (uri != null) writePdf(uri)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        root = findViewById(R.id.root)
        picture = findViewById(R.id.picture)
        panel = findViewById(R.id.panel)
        buttons = findViewById(R.id.buttons)
        previewView = findViewById(R.id.preview)
        overlay = findViewById(R.id.overlay)
        statusText = findViewById(R.id.status)
        lastPageView = findViewById(R.id.last_page)
        cameraButton = findViewById(R.id.camera_button)
        videoButton = findViewById(R.id.video_button)
        saveButton = findViewById(R.id.save_button)
        shareButton = findViewById(R.id.share_button)
        videoCheck = findViewById(R.id.video_check)
        nameGroup = findViewById(R.id.name_group)
        nameField = findViewById(R.id.name_field)
        prefixCheck = findViewById(R.id.prefix_check)
        preferences = getSharedPreferences(PREFERENCES_NAME, MODE_PRIVATE)
        // The whole frame is in view, at the start of its part of the screen: the
        // free end of that part is next to the panel.
        previewView.scaleType = PreviewView.ScaleType.FIT_START
        arrange(resources.configuration.orientation)

        cameraButton.setOnClickListener { if (state == State.CAMERA_SCAN) stopCameraScan() else startCameraScan() }
        videoButton.setOnClickListener { if (state == State.VIDEO_SCAN) cancelled.set(true) else pickVideo.launch(VIDEO_MIME_TYPE) }
        saveButton.setOnClickListener { createPdf.launch(pdfFileName()) }
        shareButton.setOnClickListener { sharePdf() }
        videoCheck.setOnClickListener { setVideoStream(videoCheck.isChecked) }
        prefixCheck.isChecked = preferences.getBoolean(PREFERENCE_NAME_PREFIX, DEFAULT_NAME_PREFIX)
        prefixCheck.setOnClickListener { preferences.edit().putBoolean(PREFERENCE_NAME_PREFIX, prefixCheck.isChecked).apply() }
        showState(State.IDLE)

        // Another app opened a video with this app: scan it. The camera stays off.
        val opened = intent?.takeIf { it.action == Intent.ACTION_VIEW }?.data
        if (opened != null && savedInstanceState == null) {
            scanVideo(opened)
        } else if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            openCamera()
        } else {
            cameraPermission.launch(Manifest.permission.CAMERA)
        }
    }

    override fun onDestroy() {
        cancelled.set(true)
        camera?.close()
        background.shutdown()
        val old = session
        session = null
        // The close waits for the pages in work: not on the main thread.
        if (old != null) Thread { old.close() }.start()
        super.onDestroy()
    }

    /** The screen turned by a quarter turn: the manifest gives such a change to this activity. */
    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        arrange(newConfig.orientation)
    }

    /** The system asks for memory: the idle workers give their large blocks back. */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        session?.releaseMemory()
    }

    // region: the camera as the source

    private fun openCamera() {
        camera = CameraSource(this, this, previewView).also { source ->
            source.open(
                onReady = {
                    cameraReady = true
                    updateButtons()
                },
                // The app stays in use with no camera: it can open a video.
                onError = { error -> statusText.text = getString(R.string.status_camera_error, error.message ?: error.javaClass.simpleName) },
            )
        }
    }

    private fun startCameraScan() {
        val source = camera ?: return
        startNewScan()
        videoNote = null
        showState(State.CAMERA_SCAN)
        source.startScan(
            createSession = ::createSession,
            listener = { uprightToSensor, status -> postStatus(uprightToSensor, status) },
            onError = ::scanFailed,
            videoFile = if (videoCheck.isChecked) newVideoFile() else null,
            onVideoEnd = ::videoEnded,
        )
    }

    /** The user turned the video of a scan on or off. */
    private fun setVideoStream(enabled: Boolean) {
        val source = camera ?: return
        if (!source.setVideoStream(enabled) && enabled) {
            videoCheck.isChecked = false
            statusText.setText(R.string.status_no_video_stream)
        }
    }

    /** A new file for the video of a scan, in the directory of the app for movies. */
    private fun newVideoFile(): File {
        val directory = getExternalFilesDir(Environment.DIRECTORY_MOVIES) ?: filesDir
        return File(directory, String.format(Locale.ROOT, VIDEO_FILE_NAME, Date()))
    }

    /** The video file of a scan is complete, or it has an error. Runs on the main thread. */
    private fun videoEnded(file: File, error: Throwable?) {
        val note = if (error == null) {
            Log.i(LOG_TAG, "video of the scan: ${file.absolutePath}")
            getString(R.string.status_video_saved, file.name)
        } else {
            Log.w(LOG_TAG, "the video of the scan has an error", error)
            getString(R.string.status_video_error, error.message ?: error.javaClass.simpleName)
        }
        videoNote = note
        // The scan can end before the file or after it.
        if (state == State.IDLE) statusText.append(" $note")
    }

    private fun stopCameraScan() {
        val source = camera ?: return
        showState(State.FINISHING)
        source.stopScan { stopped -> background.execute { finishScan(stopped) } }
    }

    // endregion: the camera as the source

    // region: a recorded video as the source

    private fun scanVideo(uri: Uri) {
        startNewScan()
        cancelled.set(false)
        showState(State.VIDEO_SCAN)
        background.execute {
            try {
                val scanned = VideoFileSource(this, uri).run(
                    createSession = ::createSession,
                    progress = { fraction, status ->
                        runOnUiThread { statusText.text = getString(R.string.status_video, (fraction * PERCENT).toInt(), status.spreads, status.completePages) }
                    },
                    isCancelled = cancelled::get,
                )
                runOnUiThread { showState(State.FINISHING) }
                finishScan(scanned)
            } catch (error: Throwable) {
                scanFailed(error)
            }
        }
    }

    // endregion: a recorded video as the source

    // region: the scan

    /** Runs on the thread of the source, with the first frame. */
    private fun createSession(format: FrameFormat): ScanSession =
        ScanSession(format, ScanOptions(), onPagesChanged = { showLastPage() }, onError = ::scanFailed).also { created ->
            runOnUiThread { session = created }
        }

    /** The source has no more frames: make the last pages. Runs on the background thread. */
    private fun finishScan(finished: ScanSession?) {
        try {
            if (finished != null) {
                finished.finish()
                while (finished.isBusy) Thread.sleep(BUSY_POLL_MILLISECONDS)
            }
            runOnUiThread {
                showState(State.IDLE)
                val pages = finished?.pageCount ?: 0
                statusText.text = resources.getQuantityString(R.plurals.status_done, pages, pages)
                videoNote?.let { statusText.append(" $it") }
                showPdfControls(pages > 0)
            }
        } catch (error: Throwable) {
            scanFailed(error)
        }
    }

    /** The user starts a scan. The pages, the name, and the shared files of the last scan go. */
    private fun startNewScan() {
        dropOldSession()
        scanStart = ZonedDateTime.now()
        nameField.setText(R.string.default_pdf_name)
        // The background thread runs its tasks in order: no share of the new scan starts before this.
        background.execute(::deleteSharedFiles)
    }

    private fun dropOldSession() {
        val old = session ?: return
        session = null
        showPdfControls(false)
        lastPageView.setImageDrawable(null)
        background.execute { old.close() }
    }

    private fun scanFailed(error: Throwable) {
        runOnUiThread {
            camera?.stopVideo()
            showState(State.IDLE)
            statusText.text = getString(R.string.status_error, error.message ?: error.javaClass.simpleName)
        }
    }

    // endregion: the scan

    // region: the screen

    /** Runs on the thread of the source. The main thread takes the last status only. */
    private fun postStatus(uprightToSensor: Matrix?, status: ScanStatus) {
        lastStatus = uprightToSensor to status
        if (!statusPending.compareAndSet(false, true)) return
        runOnUiThread {
            statusPending.set(false)
            val (lastUprightToSensor, last) = lastStatus ?: return@runOnUiThread
            if (state != State.CAMERA_SCAN) return@runOnUiThread
            // The preview view knows where each point of the sensor is on the screen.
            val sensorToView = previewView.sensorToViewTransform
            if (lastUprightToSensor != null && sensorToView != null) {
                frameToView.set(lastUprightToSensor)
                frameToView.postConcat(sensorToView)
                overlay.show(frameToView, last)
            } else {
                overlay.clear()
            }
            val hint = when {
                last.captured -> R.string.hint_turn
                last.steady -> R.string.hint_hold
                last.pages.isEmpty() -> R.string.hint_no_page
                else -> R.string.hint_steady
            }
            statusText.text = getString(R.string.status_camera, getString(hint), last.spreads, last.completePages)
        }
    }

    /** Runs on a render thread, when a page is complete: show a small picture of the last page. */
    private fun showLastPage() {
        val current = session ?: return
        val page = current.page(current.pageCount - 1) ?: return
        val options = BitmapFactory.Options().apply { inSampleSize = THUMBNAIL_SAMPLE }
        val bitmap: Bitmap = BitmapFactory.decodeByteArray(page.jpeg, 0, page.jpeg.size, options) ?: return
        runOnUiThread { lastPageView.setImageBitmap(bitmap) }
    }

    private fun showState(next: State) {
        state = next
        // A session has the rotation of its first frame: no turn during a scan with the camera.
        requestedOrientation = if (next == State.CAMERA_SCAN) ActivityInfo.SCREEN_ORIENTATION_LOCKED else ActivityInfo.SCREEN_ORIENTATION_FULL_USER
        updateButtons()
        if (next != State.IDLE) showPdfControls(false)
        if (next != State.CAMERA_SCAN) overlay.clear()
        when (next) {
            State.IDLE -> statusText.setText(R.string.status_idle)
            State.FINISHING -> statusText.setText(R.string.status_finishing)
            else -> Unit
        }
    }

    /**
     * Put the panel below the picture when the screen is upright, and at the side of
     * the picture when the screen is on its side.
     */
    private fun arrange(orientation: Int) {
        val sideways = orientation == Configuration.ORIENTATION_LANDSCAPE
        root.orientation = if (sideways) LinearLayout.HORIZONTAL else LinearLayout.VERTICAL
        picture.layoutParams = LinearLayout.LayoutParams(if (sideways) 0 else MATCH_PARENT, if (sideways) MATCH_PARENT else 0, 1f)
        panel.layoutParams = LinearLayout.LayoutParams(
            if (sideways) resources.getDimensionPixelSize(R.dimen.side_panel_width) else MATCH_PARENT,
            if (sideways) MATCH_PARENT else WRAP_CONTENT,
        )
        buttons.orientation = if (sideways) LinearLayout.VERTICAL else LinearLayout.HORIZONTAL
        val gap = resources.getDimensionPixelSize(R.dimen.button_gap)
        for (index in 0 until buttons.childCount) {
            val gapBefore = if (index == 0) 0 else gap
            buttons.getChildAt(index).layoutParams = if (sideways) {
                LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = gapBefore }
            } else {
                LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f).apply { marginStart = gapBefore }
            }
        }
    }

    private fun updateButtons() {
        cameraButton.isEnabled = (state == State.IDLE || state == State.CAMERA_SCAN) && cameraReady
        // The camera starts again for the video stream: not during a scan.
        videoCheck.isEnabled = state == State.IDLE && cameraReady
        videoButton.isEnabled = state == State.IDLE || state == State.VIDEO_SCAN
        cameraButton.setText(if (state == State.CAMERA_SCAN) R.string.button_stop else R.string.button_camera)
        videoButton.setText(if (state == State.VIDEO_SCAN) R.string.button_cancel else R.string.button_video)
    }

    /** The name field, its check box, and the two buttons for the PDF: for a scan with pages only. */
    private fun showPdfControls(enabled: Boolean) {
        saveButton.isEnabled = enabled
        shareButton.isEnabled = enabled
        nameGroup.visibility = if (enabled) View.VISIBLE else View.GONE
    }

    // endregion: the screen

    // region: the PDF

    /** The file name of the PDF, from the start of the scan, the name field, and the check box. */
    private fun pdfFileName(): String =
        PdfName.fileName(scanStart, nameField.text.toString(), prefixCheck.isChecked, getString(R.string.default_pdf_name))

    private fun writePdf(uri: Uri) {
        val current = session ?: return
        background.execute {
            try {
                contentResolver.openOutputStream(uri)?.buffered()?.use(current::writePdf)
                runOnUiThread { statusText.setText(R.string.status_saved) }
            } catch (error: Throwable) {
                scanFailed(error)
            }
        }
    }

    /**
     * Write the PDF to the share directory, with the name of [pdfFileName], and let
     * the user choose an app for it. The bytes are the bytes of "Save PDF".
     */
    private fun sharePdf() {
        val current = session ?: return
        val name = pdfFileName()
        background.execute {
            try {
                val directory = File(cacheDir, SHARE_DIRECTORY)
                directory.mkdirs()
                val file = File(directory, name)
                file.outputStream().buffered().use(current::writePdf)
                runOnUiThread { startShare(file) }
            } catch (error: Throwable) {
                scanFailed(error)
            }
        }
    }

    /**
     * Give the file to the share sheet of the system. The other app gets a content URI
     * and a read permission for it only. The URI is in [Intent.EXTRA_STREAM] and in the
     * clip data: the share sheet shows the clip, and the permission covers the clip.
     */
    private fun startShare(file: File) {
        val uri = FileProvider.getUriForFile(this, packageName + FILE_PROVIDER_SUFFIX, file)
        val send = Intent(Intent.ACTION_SEND).apply {
            type = PDF_MIME_TYPE
            putExtra(Intent.EXTRA_STREAM, uri)
            clipData = ClipData.newUri(contentResolver, file.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        startActivity(Intent.createChooser(send, getString(R.string.share_title)))
    }

    /**
     * Delete the files of the last shares: only the files in the share directory, in
     * no other directory. Runs on the background thread.
     */
    private fun deleteSharedFiles() {
        val files = File(cacheDir, SHARE_DIRECTORY).listFiles() ?: return
        for (file in files) {
            if (file.isFile && !file.delete()) Log.w(LOG_TAG, "cannot delete the shared file ${file.name}")
        }
    }

    // endregion: the PDF

    private companion object {
        const val LOG_TAG = "fastscan"
        const val PDF_MIME_TYPE = "application/pdf"

        /** The directory of the shared PDF files, in the cache directory. res/xml/file_paths.xml has the same path. */
        const val SHARE_DIRECTORY = "share"

        /** The authority of the FileProvider is the package name and this suffix, as in the manifest. */
        const val FILE_PROVIDER_SUFFIX = ".fileprovider"

        /** The settings of the user. */
        const val PREFERENCES_NAME = "settings"

        /** True: the name of the PDF starts with the date and the time of the scan. */
        const val PREFERENCE_NAME_PREFIX = "pdf_name_date_prefix"
        const val DEFAULT_NAME_PREFIX = true

        /** The name of the video file of a scan, with the date and the time of its start. */
        const val VIDEO_FILE_NAME = "scan-%1\$tY%1\$tm%1\$td-%1\$tH%1\$tM%1\$tS.mp4"
        const val VIDEO_MIME_TYPE = "video/*"
        const val PERCENT = 100

        /** The small picture of a page has one pixel for each 4 x 4 pixels of the page. */
        const val THUMBNAIL_SAMPLE = 4
        const val BUSY_POLL_MILLISECONDS = 100L
    }
}

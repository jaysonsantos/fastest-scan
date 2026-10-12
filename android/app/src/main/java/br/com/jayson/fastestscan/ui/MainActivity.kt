package br.com.jayson.fastestscan.ui

import android.Manifest
import android.content.Intent
import android.content.pm.ActivityInfo
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.WindowManager
import android.widget.Button
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.result.contract.ActivityResultContracts
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import br.com.jayson.fastestscan.R
import br.com.jayson.fastestscan.core.FrameFormat
import br.com.jayson.fastestscan.core.ScanOptions
import br.com.jayson.fastestscan.core.ScanSession
import br.com.jayson.fastestscan.core.ScanStatus
import br.com.jayson.fastestscan.source.CameraSource
import br.com.jayson.fastestscan.source.VideoFileSource
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean

/**
 * The one screen of the app. It has two sources for a scan:
 * - the camera: the pages come while the user films the book;
 * - a recorded video: the decoder runs one time through the file.
 *
 * The two sources give their frames to a [ScanSession]. The screen shows what the
 * library finds, and writes the PDF when the scan has ended.
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

    private var camera: CameraSource? = null

    /** True when the camera gives its preview: a scan with the camera can start. */
    private var cameraReady = false

    /** The scan with the pages for the PDF. Only the main thread changes it. */
    private var session: ScanSession? = null
    private var state = State.IDLE

    /** One thread for the slow steps that are not a render: the decoder, the end of a scan, the PDF file. */
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
        // The whole frame is in view, at the start of its part of the screen: the
        // free end of that part is next to the panel.
        previewView.scaleType = PreviewView.ScaleType.FIT_START
        arrange(resources.configuration.orientation)

        cameraButton.setOnClickListener { if (state == State.CAMERA_SCAN) stopCameraScan() else startCameraScan() }
        videoButton.setOnClickListener { if (state == State.VIDEO_SCAN) cancelled.set(true) else pickVideo.launch(VIDEO_MIME_TYPE) }
        saveButton.setOnClickListener { createPdf.launch(getString(R.string.default_file_name)) }
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
        dropOldSession()
        showState(State.CAMERA_SCAN)
        source.startScan(::createSession, { uprightToSensor, status -> postStatus(uprightToSensor, status) }, ::scanFailed)
    }

    private fun stopCameraScan() {
        val source = camera ?: return
        showState(State.FINISHING)
        source.stopScan { stopped -> background.execute { finishScan(stopped) } }
    }

    // endregion: the camera as the source

    // region: a recorded video as the source

    private fun scanVideo(uri: Uri) {
        dropOldSession()
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
                saveButton.isEnabled = pages > 0
            }
        } catch (error: Throwable) {
            scanFailed(error)
        }
    }

    private fun dropOldSession() {
        val old = session ?: return
        session = null
        saveButton.isEnabled = false
        lastPageView.setImageDrawable(null)
        background.execute { old.close() }
    }

    private fun scanFailed(error: Throwable) {
        runOnUiThread {
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
        if (next != State.IDLE) saveButton.isEnabled = false
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
        videoButton.isEnabled = state == State.IDLE || state == State.VIDEO_SCAN
        cameraButton.setText(if (state == State.CAMERA_SCAN) R.string.button_stop else R.string.button_camera)
        videoButton.setText(if (state == State.VIDEO_SCAN) R.string.button_cancel else R.string.button_video)
    }

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

    // endregion: the screen

    private companion object {
        const val PDF_MIME_TYPE = "application/pdf"
        const val VIDEO_MIME_TYPE = "video/*"
        const val PERCENT = 100

        /** The small picture of a page has one pixel for each 4 x 4 pixels of the page. */
        const val THUMBNAIL_SAMPLE = 4
        const val BUSY_POLL_MILLISECONDS = 100L
    }
}

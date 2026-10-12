package br.com.jayson.fastestscan.source

import android.content.Context
import android.graphics.Matrix
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Size
import androidx.camera.core.AspectRatio
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.UseCase
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.FallbackStrategy
import androidx.camera.video.FileOutputOptions
import androidx.camera.video.Quality
import androidx.camera.video.QualitySelector
import androidx.camera.video.Recorder
import androidx.camera.video.Recording
import androidx.camera.video.VideoCapture
import androidx.camera.video.VideoRecordEvent
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import br.com.jayson.fastestscan.R
import br.com.jayson.fastestscan.core.ColorMatrix
import br.com.jayson.fastestscan.core.ColorRange
import br.com.jayson.fastestscan.core.FrameFormat
import br.com.jayson.fastestscan.core.ScanSession
import br.com.jayson.fastestscan.core.ScanStatus
import java.io.File
import java.util.Locale
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * The camera as a source of frames. The camera gives two streams: the preview for
 * the screen, and full-size YUV frames for the library. No video file is written:
 * the library keeps the few frames that a spread needs.
 *
 * The two streams follow the rotation of the screen: the frames for the library
 * are upright when the picture on the screen is upright.
 *
 * The camera can give a third stream for a video file of a scan ([setVideoStream]).
 * The video is for a test: the desktop program can do the same scan again from
 * it. The library does not use it.
 *
 * When the library is slower than the camera, the camera drops frames: the library
 * measures the frame rate from the times of the frames that it gets.
 */
class CameraSource(
    private val context: Context,
    private val owner: LifecycleOwner,
    private val previewView: PreviewView,
) {
    /** Gets the status of each frame, on the camera thread. */
    fun interface Listener {
        /**
         * [uprightToSensor] maps a point of the upright frame, which is where the
         * corners of [status] are, to a point of the camera sensor. With
         * `PreviewView.getSensorToViewTransform`, it gives the place of the point on
         * the screen. Null when the camera gives no such map. Do not change it.
         */
        fun onFrame(uprightToSensor: Matrix?, status: ScanStatus)
    }

    private val frameThread: ExecutorService = Executors.newSingleThreadExecutor()
    private val displays = context.getSystemService(DisplayManager::class.java)
    private var provider: ProcessCameraProvider? = null
    private var preview: Preview? = null
    private var analysis: ImageAnalysis? = null

    /** The stream for a video file, or null when it is off. Only the main thread uses it and [recording]. */
    private var video: VideoCapture<Recorder>? = null
    private var recording: Recording? = null

    /** A turn of the screen by a half turn changes no configuration: only this listener sees it. */
    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = Unit

        override fun onDisplayRemoved(displayId: Int) = Unit

        override fun onDisplayChanged(displayId: Int) = followDisplay()
    }

    @Volatile
    private var session: ScanSession? = null

    /** The format of the first frame of [session], and the map of its frames. Only the camera thread uses them. */
    private var sessionFormat: FrameFormat? = null
    private var uprightToSensor: Matrix? = null

    /** The frames since the last line of the log, and the time that the library took for them. Only the camera thread uses them. */
    private var loggedFrames = 0
    private var libraryNanos = 0L
    private var logStartNanos = 0L

    @Volatile
    private var scanning = false

    /**
     * Show the camera on the screen. The frames go nowhere until [startScan].
     * [onReady] or [onError] runs on the main thread: a phone can have no camera
     * that the app can use.
     */
    fun open(onReady: () -> Unit, onError: (Throwable) -> Unit) {
        val future = ProcessCameraProvider.getInstance(context)
        future.addListener({
            try {
                val cameraProvider = future.get()
                provider = cameraProvider
                // The preview has the shape of the frames for the library: the screen
                // then shows all that the library sees, and no more.
                val newPreview = Preview.Builder()
                    .setResolutionSelector(ResolutionSelector.Builder().setAspectRatioStrategy(FRAME_SHAPE).build())
                    .build()
                newPreview.setSurfaceProvider(previewView.surfaceProvider)
                val newAnalysis = ImageAnalysis.Builder()
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setAspectRatioStrategy(FRAME_SHAPE)
                            .setResolutionStrategy(ResolutionStrategy(TARGET_FRAME_SIZE, ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
                            .build(),
                    )
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                    // A frame that comes while the library works on the frame before it is dropped.
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                newAnalysis.setAnalyzer(frameThread, ::analyze)
                preview = newPreview
                analysis = newAnalysis
                bind(cameraProvider)
                displays.registerDisplayListener(displayListener, Handler(Looper.getMainLooper()))
                onReady()
            } catch (error: Throwable) {
                onError(error)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /** Start the camera with its streams: the preview, the frames, and the video when it is on. */
    private fun bind(cameraProvider: ProcessCameraProvider) {
        val streams = listOfNotNull<UseCase>(preview, analysis, video)
        cameraProvider.unbindAll()
        cameraProvider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, *streams.toTypedArray())
        followDisplay()
    }

    /**
     * Turn the stream for a video file on or off. The camera starts again, so the
     * preview stops for a moment. Returns false when the camera cannot give the
     * third stream: it then runs with no video stream. Runs on the main thread,
     * not during a scan.
     */
    fun setVideoStream(enabled: Boolean): Boolean {
        val cameraProvider = provider ?: return false
        if (enabled == (video != null)) return true
        video = if (enabled) {
            // The video has the shape of the frames for the library, and their size
            // when the camera gives a third stream of that size. On the phone of
            // the tests it does not: the video then has the size of the preview.
            val recorder = Recorder.Builder()
                .setAspectRatio(AspectRatio.RATIO_4_3)
                .setQualitySelector(QualitySelector.from(Quality.UHD, FallbackStrategy.lowerQualityOrHigherThan(Quality.UHD)))
                .setTargetVideoEncodingBitRate(VIDEO_BITS_PER_SECOND)
                .build()
            VideoCapture.withOutput(recorder)
        } else {
            null
        }
        return try {
            bind(cameraProvider)
            true
        } catch (error: IllegalArgumentException) {
            // The camera has no such set of streams.
            Log.w(TAG, "the camera gives no video stream next to the two other streams", error)
            video = null
            bind(cameraProvider)
            false
        }
    }

    /** Give the rotation of the screen to the streams. Runs on the main thread. */
    private fun followDisplay() {
        val rotation = previewView.display?.rotation ?: return
        preview?.targetRotation = rotation
        analysis?.targetRotation = rotation
        video?.targetRotation = rotation
    }

    private var createSession: ((FrameFormat) -> ScanSession)? = null
    private var listener: Listener? = null
    private var onError: ((Throwable) -> Unit)? = null

    /**
     * Start to give the frames to a session. [createSession] makes the session with
     * the first frame, when the size and the rotation of the frames are known. The
     * screen must keep its rotation until [stopScan]: a session has one rotation.
     *
     * With [videoFile] and the video stream on, the camera writes a video of the
     * scan to that file. [onVideoEnd] gets the file when it is complete, or the
     * error, on the main thread. Runs on the main thread.
     */
    fun startScan(
        createSession: (FrameFormat) -> ScanSession,
        listener: Listener,
        onError: (Throwable) -> Unit,
        videoFile: File? = null,
        onVideoEnd: (File, Throwable?) -> Unit = { _, _ -> },
    ) {
        val stream = video
        if (videoFile != null && stream != null) {
            recording = stream.output
                .prepareRecording(context, FileOutputOptions.Builder(videoFile).build())
                .start(ContextCompat.getMainExecutor(context)) { event ->
                    if (event is VideoRecordEvent.Finalize) {
                        val error = if (event.hasError()) event.cause ?: IllegalStateException("video error ${event.error}") else null
                        onVideoEnd(videoFile, error)
                    }
                }
        }
        frameThread.execute {
            this.createSession = createSession
            this.listener = listener
            this.onError = onError
            session = null
            loggedFrames = 0
            libraryNanos = 0L
            scanning = true
        }
    }

    /**
     * Stop to give frames. [onStopped] gets the session, or null when no frame
     * came, on the camera thread. The caller calls `finish` and `close` on it.
     * Runs on the main thread.
     */
    fun stopScan(onStopped: (ScanSession?) -> Unit) {
        stopVideo()
        frameThread.execute {
            scanning = false
            val stopped = session
            session = null
            onStopped(stopped)
        }
    }

    /** End the video file of a scan. Runs on the main thread. */
    fun stopVideo() {
        recording?.stop()
        recording = null
    }

    fun close() {
        stopVideo()
        displays.unregisterDisplayListener(displayListener)
        provider?.unbindAll()
        frameThread.shutdown()
    }

    private fun analyze(image: ImageProxy) {
        image.use {
            if (!scanning) return
            try {
                val crop = image.cropRect
                val format = FrameFormat(
                    width = crop.width(),
                    height = crop.height(),
                    rotationDegrees = image.imageInfo.rotationDegrees,
                    // The YUV frames of an Android camera have the full range and the matrix of JPEG.
                    colorRange = ColorRange.FULL,
                    colorMatrix = ColorMatrix.BT601,
                )
                val current = session ?: createSession!!(format).also {
                    session = it
                    sessionFormat = format
                    uprightToSensor = mapUprightToSensor(crop, format.rotationDegrees, image.imageInfo.sensorToBufferTransformMatrix)
                    Log.i(TAG, "camera frames: $format")
                }
                check(format == sessionFormat) { context.getString(R.string.error_turned) }
                val planes = image.planes.map { FramePlane(it.buffer, it.rowStride, it.pixelStride) }
                val before = System.nanoTime()
                val status = current.pushFrame(planes, crop, image.imageInfo.timestamp / NANOSECONDS_PER_SECOND)
                logSpeed(before, System.nanoTime(), status)
                listener?.onFrame(uprightToSensor, status)
            } catch (error: Throwable) {
                // The owner of the session closes it. The next scan gets a new one.
                scanning = false
                session = null
                onError?.invoke(error)
            }
        }
    }

    /**
     * Write the speed of the scan to the log, one line for each [LOG_FRAMES]
     * frames: how many frames in a second the library gets, and how long it works
     * on a frame. The camera drops the frames that come while the library works.
     */
    private fun logSpeed(before: Long, after: Long, status: ScanStatus) {
        if (loggedFrames == 0) logStartNanos = before
        loggedFrames += 1
        libraryNanos += after - before
        if (loggedFrames < LOG_FRAMES) return
        val seconds = (after - logStartNanos) / NANOSECONDS_PER_SECOND
        val milliseconds = libraryNanos / NANOSECONDS_PER_MILLISECOND / loggedFrames
        Log.i(
            TAG,
            "camera speed: %.1f frames in a second, %.1f ms in the library for each frame, %d frames in memory, %d pages in view"
                .format(Locale.ROOT, loggedFrames / seconds, milliseconds, status.heldFrames, status.pages.size),
        )
        loggedFrames = 0
        libraryNanos = 0L
    }

    private companion object {
        const val TAG = "fastscan"

        /**
         * The bit rate of the video of a scan. The encoder of a phone takes much
         * less for a small video by default, and the text of a page is then not
         * sharp enough to do the scan again from the video.
         */
        const val VIDEO_BITS_PER_SECOND = 16_000_000

        /** The log gets one line about the speed for this many frames. */
        const val LOG_FRAMES = 60
        const val NANOSECONDS_PER_MILLISECOND = 1_000_000.0

        /**
         * The shape of the frames: 4 x 3 parts, the shape of most camera sensors. An
         * open book has about 3 x 2 parts: it fills such a frame better than a frame
         * of 16 x 9 parts.
         */
        val FRAME_SHAPE: AspectRatioStrategy = AspectRatioStrategy.RATIO_4_3_FALLBACK_AUTO_STRATEGY

        /**
         * The short side has the 2160 pixels of the videos that the library was
         * tested with. A page of a spread is then about 1300 pixels wide, and a frame
         * takes 9 MB.
         */
        val TARGET_FRAME_SIZE = Size(2880, 2160)
        const val NANOSECONDS_PER_SECOND = 1_000_000_000.0

        const val QUARTER_TURN_DEGREES = 90
        const val HALF_TURN_DEGREES = 180
        const val THREE_QUARTER_TURN_DEGREES = 270

        /**
         * The map from a point of the upright frame to a point of the camera sensor.
         * The upright frame is the part [crop] of the buffer after a clockwise turn
         * by [rotationDegrees]: the frame that the library works on. Null when
         * [sensorToBuffer] has no inverse.
         */
        fun mapUprightToSensor(crop: Rect, rotationDegrees: Int, sensorToBuffer: Matrix): Matrix? {
            val bufferToSensor = Matrix()
            if (!sensorToBuffer.invert(bufferToSensor)) return null
            val left = crop.left.toFloat()
            val top = crop.top.toFloat()
            val right = crop.right.toFloat()
            val bottom = crop.bottom.toFloat()
            // Each row gives one buffer coordinate from the upright x, the upright y, and 1.
            val uprightToBuffer = when (rotationDegrees) {
                QUARTER_TURN_DEGREES -> floatArrayOf(0f, 1f, left, -1f, 0f, bottom, 0f, 0f, 1f)
                HALF_TURN_DEGREES -> floatArrayOf(-1f, 0f, right, 0f, -1f, bottom, 0f, 0f, 1f)
                THREE_QUARTER_TURN_DEGREES -> floatArrayOf(0f, -1f, right, 1f, 0f, top, 0f, 0f, 1f)
                else -> floatArrayOf(1f, 0f, left, 0f, 1f, top, 0f, 0f, 1f)
            }
            return Matrix().apply {
                setValues(uprightToBuffer)
                postConcat(bufferToSensor)
            }
        }
    }
}

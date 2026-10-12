package br.com.jayson.fastestscan.source

import android.content.Context
import android.graphics.Matrix
import android.graphics.Rect
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Size
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.AspectRatioStrategy
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.LifecycleOwner
import br.com.jayson.fastestscan.R
import br.com.jayson.fastestscan.core.ColorMatrix
import br.com.jayson.fastestscan.core.ColorRange
import br.com.jayson.fastestscan.core.FrameFormat
import br.com.jayson.fastestscan.core.ScanSession
import br.com.jayson.fastestscan.core.ScanStatus
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
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, newPreview, newAnalysis)
                preview = newPreview
                analysis = newAnalysis
                followDisplay()
                displays.registerDisplayListener(displayListener, Handler(Looper.getMainLooper()))
                onReady()
            } catch (error: Throwable) {
                onError(error)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    /** Give the rotation of the screen to the two streams. Runs on the main thread. */
    private fun followDisplay() {
        val rotation = previewView.display?.rotation ?: return
        preview?.targetRotation = rotation
        analysis?.targetRotation = rotation
    }

    private var createSession: ((FrameFormat) -> ScanSession)? = null
    private var listener: Listener? = null
    private var onError: ((Throwable) -> Unit)? = null

    /**
     * Start to give the frames to a session. [createSession] makes the session with
     * the first frame, when the size and the rotation of the frames are known. The
     * screen must keep its rotation until [stopScan]: a session has one rotation.
     */
    fun startScan(createSession: (FrameFormat) -> ScanSession, listener: Listener, onError: (Throwable) -> Unit) {
        frameThread.execute {
            this.createSession = createSession
            this.listener = listener
            this.onError = onError
            session = null
            scanning = true
        }
    }

    /**
     * Stop to give frames. [onStopped] gets the session, or null when no frame
     * came, on the camera thread. The caller calls `finish` and `close` on it.
     */
    fun stopScan(onStopped: (ScanSession?) -> Unit) {
        frameThread.execute {
            scanning = false
            val stopped = session
            session = null
            onStopped(stopped)
        }
    }

    fun close() {
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
                val status = current.pushFrame(planes, crop, image.imageInfo.timestamp / NANOSECONDS_PER_SECOND)
                listener?.onFrame(uprightToSensor, status)
            } catch (error: Throwable) {
                // The owner of the session closes it. The next scan gets a new one.
                scanning = false
                session = null
                onError?.invoke(error)
            }
        }
    }

    private companion object {
        const val TAG = "fastscan"

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

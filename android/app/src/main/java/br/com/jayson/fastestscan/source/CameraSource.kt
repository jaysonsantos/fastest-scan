package br.com.jayson.fastestscan.source

import android.content.Context
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
        fun onFrame(format: FrameFormat, status: ScanStatus)
    }

    private val frameThread: ExecutorService = Executors.newSingleThreadExecutor()
    private var provider: ProcessCameraProvider? = null

    @Volatile
    private var session: ScanSession? = null

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
                // The preview has the shape of the frames for the library, so that the
                // outline of a page is at the place of the page.
                val preview = Preview.Builder()
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setAspectRatioStrategy(AspectRatioStrategy.RATIO_16_9_FALLBACK_AUTO_STRATEGY)
                            .build(),
                    )
                    .build()
                preview.setSurfaceProvider(previewView.surfaceProvider)
                val analysis = ImageAnalysis.Builder()
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(ResolutionStrategy(TARGET_FRAME_SIZE, ResolutionStrategy.FALLBACK_RULE_CLOSEST_LOWER_THEN_HIGHER))
                            .build(),
                    )
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
                    // A frame that comes while the library works on the frame before it is dropped.
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .build()
                analysis.setAnalyzer(frameThread, ::analyze)
                cameraProvider.unbindAll()
                cameraProvider.bindToLifecycle(owner, CameraSelector.DEFAULT_BACK_CAMERA, preview, analysis)
                onReady()
            } catch (error: Throwable) {
                onError(error)
            }
        }, ContextCompat.getMainExecutor(context))
    }

    private var createSession: ((FrameFormat) -> ScanSession)? = null
    private var listener: Listener? = null
    private var onError: ((Throwable) -> Unit)? = null

    /**
     * Start to give the frames to a session. [createSession] makes the session with
     * the first frame, when the size and the rotation of the frames are known.
     */
    fun startScan(createSession: (FrameFormat) -> ScanSession, listener: Listener, onError: (Throwable) -> Unit) {
        frameThread.execute {
            this.createSession = createSession
            this.listener = listener
            this.onError = onError
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
                    Log.i(TAG, "camera frames: $format")
                }
                val planes = image.planes.map { FramePlane(it.buffer, it.rowStride, it.pixelStride) }
                val status = current.pushFrame(planes, crop, image.imageInfo.timestamp / NANOSECONDS_PER_SECOND)
                listener?.onFrame(format, status)
            } catch (error: Throwable) {
                scanning = false
                onError?.invoke(error)
            }
        }
    }

    private companion object {
        const val TAG = "fastscan"

        /** The largest frames that the library was tested with. A page of a spread is then about 1300 pixels wide. */
        val TARGET_FRAME_SIZE = Size(3840, 2160)
        const val NANOSECONDS_PER_SECOND = 1_000_000_000.0
    }
}

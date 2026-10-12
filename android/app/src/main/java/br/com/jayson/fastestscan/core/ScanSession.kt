package br.com.jayson.fastestscan.core

import java.io.OutputStream
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * One scan: frames go in, in the order of the video, and pages come out while the
 * video runs.
 *
 * The class keeps the thread rules of the native library:
 * - One thread at a time calls a function of the native stream: [lock] guards them.
 * - The render of a job runs on a thread of [renderThreads], with the working
 *   memory of that thread only.
 *
 * [push] and [finish] run on the thread of the source: the camera thread or the
 * decoder thread. [onPagesChanged] runs on a render thread.
 */
class ScanSession(
    format: FrameFormat,
    private val options: ScanOptions,
    private val onPagesChanged: (pageCount: Int) -> Unit,
    private val onError: (Throwable) -> Unit,
) : AutoCloseable {
    private val lock = Any()
    private var stream: Long = Native.streamCreate(
        format.width,
        format.height,
        format.rotationDegrees,
        format.colorRange.code,
        format.colorMatrix.code,
        format.framesPerSecond,
        options.layout.code,
        options.donorFrames,
        options.maxHeldFrames,
        options.maxPageHeight,
        options.jpegQuality,
        options.dpi,
        options.fingers.code,
    )

    /** The working memory of the thread that pushes frames. */
    private val pushWorker: Long = createWorker()

    /** The working memory of the render threads. A thread takes one for a job. */
    private val idleWorkers = ConcurrentLinkedQueue<Long>()
    private val allWorkers = ConcurrentLinkedQueue<Long>()
    private val renderThreads: ExecutorService = Executors.newFixedThreadPool(options.renderThreads)
    private val statusValues = FloatArray(Native.STATUS_LENGTH)

    /**
     * Take the next frame of the video. The three buffers are the planes of an
     * `android.media.Image`: direct buffers. The library reads them during the call
     * only, so the caller can close the image after the call.
     */
    fun push(
        y: ByteBuffer,
        u: ByteBuffer,
        v: ByteBuffer,
        yStride: Int,
        chromaStride: Int,
        chromaStep: Int,
        seconds: Double,
    ): ScanStatus = synchronized(lock) {
        check(stream != 0L) { "the session is closed" }
        val result = Native.streamPush(stream, pushWorker, y, u, v, yStride, chromaStride, chromaStep, seconds, statusValues)
        if (result != Native.OK) throw ScanException(result)
        startJobs()
        ScanStatus.fromValues(statusValues)
    }

    /** The video has no more frames. The spreads that were open become pages. */
    fun finish() = synchronized(lock) {
        check(stream != 0L) { "the session is closed" }
        val result = Native.streamFinish(stream, pushWorker)
        if (result != Native.OK) throw ScanException(result)
        startJobs()
    }

    /** True while a page is in work. */
    val isBusy: Boolean
        get() = synchronized(lock) { stream != 0L && Native.streamBusy(stream) }

    val pageCount: Int
        get() = synchronized(lock) { if (stream == 0L) 0 else Native.streamPageCount(stream) }

    /** A copy of one complete page, or null when the page does not exist. */
    fun page(index: Int): ScanPage? = synchronized(lock) {
        if (stream == 0L) return null
        val info = IntArray(Native.PAGE_INFO_LENGTH)
        if (Native.streamPageInfo(stream, index, info) != Native.OK) return null
        val jpeg = Native.streamPageJpeg(stream, index) ?: return null
        ScanPage(
            width = info[Native.PAGE_INFO_WIDTH],
            height = info[Native.PAGE_INFO_HEIGHT],
            gray = info[Native.PAGE_INFO_GRAY] != 0,
            jpeg = jpeg,
        )
    }

    /** Write the pages that are complete as a PDF. */
    fun writePdf(output: OutputStream) = synchronized(lock) {
        check(stream != 0L) { "the session is closed" }
        val result = Native.streamWritePdf(stream, output)
        if (result != Native.OK) throw ScanException(result)
    }

    /** Give the memory that the workers keep back to the system. */
    fun releaseMemory() {
        // A worker that a thread uses now is not in the list of idle workers.
        val idle = generateSequence { idleWorkers.poll() }.toList()
        idle.forEach(Native::workerReleaseMemory)
        idleWorkers.addAll(idle)
    }

    /** Wait for the pages in work, then free the native objects. */
    override fun close() {
        renderThreads.shutdown()
        renderThreads.awaitTermination(CLOSE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        synchronized(lock) {
            if (stream == 0L) return
            // A job that no thread took has no pages: the stream frees it.
            while (true) {
                val job = Native.streamTakeJob(stream)
                if (job == 0L) break
                Native.streamCompleteJob(stream, job, RESULT_NOT_RUN)
            }
            // A render that did not end in time still has its job. The stream must
            // stay then: a small leak is better than a crash.
            if (!renderThreads.isTerminated) return
            Native.streamDestroy(stream)
            stream = 0L
            Native.workerDestroy(pushWorker)
            allWorkers.forEach(Native::workerDestroy)
            allWorkers.clear()
            idleWorkers.clear()
        }
    }

    /** Give each job that is ready to a render thread. The caller holds [lock]. */
    private fun startJobs() {
        while (true) {
            val job = Native.streamTakeJob(stream)
            if (job == 0L) return
            try {
                renderThreads.execute { render(job) }
            } catch (rejected: java.util.concurrent.RejectedExecutionException) {
                Native.streamCompleteJob(stream, job, RESULT_NOT_RUN)
            }
        }
    }

    private fun render(job: Long) {
        var result = RESULT_NOT_RUN
        var failure: Throwable? = null
        try {
            val worker = idleWorkers.poll() ?: createWorker().also(allWorkers::add)
            try {
                result = Native.jobRun(job, worker)
            } finally {
                // The large blocks of the job go back to the system: a phone has
                // more use for the memory than for the time of the page faults.
                Native.workerReleaseMemory(worker)
                idleWorkers.add(worker)
            }
            if (result != Native.OK) failure = ScanException(result)
        } catch (error: Throwable) {
            failure = error
        }
        // The stream gets each job back, also after an error.
        val pages = synchronized(lock) {
            Native.streamCompleteJob(stream, job, result)
            Native.streamPageCount(stream)
        }
        if (failure != null) onError(failure) else onPagesChanged(pages)
    }

    private fun createWorker(): Long {
        val worker = Native.workerCreate()
        if (worker == 0L) throw OutOfMemoryError("no memory for a worker of the scan")
        return worker
    }

    private companion object {
        /** A result for a job that did not run. Any value that is not 0. */
        const val RESULT_NOT_RUN = -1

        /** The render of one spread takes some seconds on a phone. */
        const val CLOSE_TIMEOUT_SECONDS = 60L
    }
}

package br.com.jayson.fastestscan

import android.net.Uri
import android.os.Debug
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import br.com.jayson.fastestscan.core.ScanOptions
import br.com.jayson.fastestscan.core.ScanSession
import br.com.jayson.fastestscan.source.VideoFileSource
import java.io.File
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * A scan of a recorded video on a phone or an emulator, with the decoder of the
 * device. The video is not in the repository: the test takes it from the files
 * directory of the app. `scripts/test-android.sh <video> <pages>` copies the video
 * to the device, runs this test, and copies the results back.
 *
 * The test writes the PDF (`scan.pdf`) and a report with the times and the memory
 * (`scan-report.txt`) next to the video. Gradle removes the files of the app after
 * its own test run, so the script starts this test with `adb`.
 *
 * With no video, the test does not run.
 */
@RunWith(AndroidJUnit4::class)
class VideoScanTest {
    @Test
    fun aRecordedVideoGivesItsPages() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val arguments = InstrumentationRegistry.getArguments()
        val directory = context.getExternalFilesDir(null)!!
        val video = File(directory, arguments.getString(ARGUMENT_VIDEO) ?: DEFAULT_VIDEO_NAME)
        assumeTrue("no video at ${video.path}", video.exists())
        val expectedPages = arguments.getString(ARGUMENT_PAGES)?.toInt()

        // The largest native memory of the process during the scan.
        val peakNativeBytes = AtomicLong(0)
        val scanning = AtomicBoolean(true)
        val memoryWatch = Thread {
            while (scanning.get()) {
                peakNativeBytes.accumulateAndGet(Debug.getNativeHeapAllocatedSize(), ::maxOf)
                Thread.sleep(MEMORY_POLL_MILLISECONDS)
            }
        }.also(Thread::start)

        val failures = ConcurrentLinkedQueue<Throwable>()
        var frames = 0
        var maxHeldFrames = 0
        val start = System.nanoTime()
        val session = VideoFileSource(context, Uri.fromFile(video)).run(
            createSession = { format ->
                Log.i(TAG, "frames: $format")
                ScanSession(format, ScanOptions(), onPagesChanged = { pages -> Log.i(TAG, "pages: $pages") }, onError = failures::add)
            },
            progress = { _, status ->
                frames++
                maxHeldFrames = maxOf(maxHeldFrames, status.heldFrames)
            },
            isCancelled = { false },
        )
        requireNotNull(session) { "the video gave no frame" }
        val decodedSeconds = (System.nanoTime() - start) / NANOSECONDS_PER_SECOND
        session.use {
            session.finish()
            while (session.isBusy) Thread.sleep(BUSY_POLL_MILLISECONDS)
            val totalSeconds = (System.nanoTime() - start) / NANOSECONDS_PER_SECOND
            scanning.set(false)
            memoryWatch.join()

            val pages = session.pageCount
            File(directory, PDF_NAME).outputStream().buffered().use(session::writePdf)
            val report = buildString {
                appendLine("video: ${video.name}")
                appendLine("frames: $frames")
                appendLine("pages: $pages")
                appendLine("seconds until the last frame: %.1f".format(decodedSeconds))
                appendLine("seconds until the last page: %.1f".format(totalSeconds))
                appendLine("milliseconds for each frame: %.1f".format(decodedSeconds * MILLISECONDS_PER_SECOND / maxOf(frames, 1)))
                appendLine("full-size frames in memory, at most: $maxHeldFrames")
                appendLine("native memory, at most: ${peakNativeBytes.get() / BYTES_PER_MEGABYTE} MB")
                appendLine("render errors: ${failures.size}")
            }
            File(directory, REPORT_NAME).writeText(report)
            Log.i(TAG, report)

            assertTrue("a render failed: $failures", failures.isEmpty())
            if (expectedPages != null) assertEquals(expectedPages, pages) else assertTrue("the scan has no page", pages > 0)
        }
    }

    private companion object {
        const val TAG = "fastscan-test"
        const val ARGUMENT_VIDEO = "video"
        const val ARGUMENT_PAGES = "pages"
        const val DEFAULT_VIDEO_NAME = "video.mp4"
        const val PDF_NAME = "scan.pdf"
        const val REPORT_NAME = "scan-report.txt"
        const val BUSY_POLL_MILLISECONDS = 100L
        const val MEMORY_POLL_MILLISECONDS = 200L
        const val NANOSECONDS_PER_SECOND = 1_000_000_000.0
        const val MILLISECONDS_PER_SECOND = 1000.0
        const val BYTES_PER_MEGABYTE = 1024 * 1024
    }
}

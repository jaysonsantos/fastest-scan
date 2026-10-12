package br.com.jayson.fastestscan

import androidx.test.ext.junit.runners.AndroidJUnit4
import br.com.jayson.fastestscan.core.ColorMatrix
import br.com.jayson.fastestscan.core.ColorRange
import br.com.jayson.fastestscan.core.FrameFormat
import br.com.jayson.fastestscan.core.ScanOptions
import br.com.jayson.fastestscan.core.ScanSession
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.ConcurrentLinkedQueue
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

/**
 * The native library on a phone or an emulator: it loads, and a scan of a
 * synthetic video gives its pages. The video has two pages, each in view for 12
 * frames, with the desk between them. The frames have the layout of a camera
 * frame: a row stride larger than the width, and the U and the V samples in turn.
 *
 * `tests/jni/NativeSmoke.java` is the same check for the Java machine of a desktop.
 */
@RunWith(AndroidJUnit4::class)
class NativeLibraryTest {
    @Test
    fun aSyntheticVideoGivesTwoPagesAndAPdf() {
        val failures = ConcurrentLinkedQueue<Throwable>()
        val format = FrameFormat(WIDTH, HEIGHT, rotationDegrees = 0, ColorRange.LIMITED, ColorMatrix.BT709, FRAMES_PER_SECOND.toFloat())
        val options = ScanOptions(maxPageHeight = MAX_PAGE_HEIGHT)
        ScanSession(format, options, onPagesChanged = {}, onError = failures::add).use { session ->
            // The sizes of the plane buffers of an Android frame: to the last sample, not to the end of the row.
            val luma = ByteBuffer.allocateDirect(STRIDE * (HEIGHT - 1) + WIDTH)
            val chroma = ByteBuffer.allocateDirect(STRIDE * (HEIGHT / 2 - 1) + WIDTH)
            val u = chroma.duplicate()
            val v = chroma.duplicate().also { it.position(1) }.slice()

            var index = 0
            var captured = false
            var spreads = 0
            for (seed in intArrayOf(1, 0, 2, 0)) {
                fillFrame(luma, chroma, seed)
                repeat(if (seed == 0) TURN_FRAMES else PAGE_FRAMES) {
                    val status = session.push(luma, u, v, STRIDE, STRIDE, CHROMA_STEP, index.toDouble() / FRAMES_PER_SECOND)
                    index++
                    assertEquals("a page in frame $index", seed != 0, status.pages.isNotEmpty())
                    if (seed != 0) {
                        val corners = status.pages.single().points
                        assertEquals(PAGE_LEFT.toFloat(), corners[0].x, CORNER_TOLERANCE)
                        assertEquals(PAGE_TOP.toFloat(), corners[0].y, CORNER_TOLERANCE)
                        assertEquals(PAGE_RIGHT.toFloat(), corners[2].x, CORNER_TOLERANCE)
                        assertEquals(PAGE_BOTTOM.toFloat(), corners[2].y, CORNER_TOLERANCE)
                    }
                    captured = captured || status.captured
                    spreads = status.spreads
                }
            }
            assertTrue("no view was long enough for a spread", captured)
            assertEquals(2, spreads)

            session.finish()
            while (session.isBusy) Thread.sleep(BUSY_POLL_MILLISECONDS)
            assertTrue("a render failed: $failures", failures.isEmpty())
            assertEquals(2, session.pageCount)
            for (number in 0 until 2) {
                val page = session.page(number)!!
                assertEquals(MAX_PAGE_HEIGHT, page.height)
                assertTrue(page.width in 1 until MAX_PAGE_HEIGHT)
                // A JPEG file starts with the marker FF D8.
                assertEquals(0xFF, page.jpeg[0].toInt() and 0xFF)
                assertEquals(0xD8, page.jpeg[1].toInt() and 0xFF)
            }
            val pdf = ByteArrayOutputStream()
            session.writePdf(pdf)
            assertEquals("%PDF-", String(pdf.toByteArray(), 0, 5, Charsets.US_ASCII))
        }
    }

    /**
     * A dark desk and, when the seed is not 0, a bright page with dots and a dark
     * bar. Two seeds are two different pages.
     */
    private fun fillFrame(luma: ByteBuffer, chroma: ByteBuffer, seed: Int) {
        for (index in 0 until luma.capacity()) luma.put(index, DESK_LUMA)
        for (row in 0 until HEIGHT / 2) {
            for (column in 0 until WIDTH / 2) {
                chroma.put(row * STRIDE + 2 * column, NEUTRAL_CHROMA)
                chroma.put(row * STRIDE + 2 * column + 1, DESK_CHROMA)
            }
        }
        if (seed == 0) return
        val barTop = 0.25f + 0.1f * (seed % 5)
        for (row in PAGE_TOP until PAGE_BOTTOM) {
            for (column in PAGE_LEFT until PAGE_RIGHT) {
                val across = (column - PAGE_LEFT).toFloat() / (PAGE_RIGHT - PAGE_LEFT)
                val down = (row - PAGE_TOP).toFloat() / (PAGE_BOTTOM - PAGE_TOP)
                val onBar = across > 0.2f && across < 0.8f && down > barTop && down < barTop + 0.12f
                val dotColumn = (across * 40.0f).toInt()
                val dotRow = (down * 50.0f).toInt()
                val dot = (dotColumn * (7 + seed) + dotRow * (13 + 2 * seed)) % 11 == 0
                luma.put(row * STRIDE + column, if (onBar) BAR_LUMA else if (dot) DOT_LUMA else PAPER_LUMA)
                chroma.put((row / 2) * STRIDE + 2 * (column / 2) + 1, NEUTRAL_CHROMA)
            }
        }
    }

    private companion object {
        const val WIDTH = 320
        const val HEIGHT = 240
        const val STRIDE = 336
        const val CHROMA_STEP = 2
        const val FRAMES_PER_SECOND = 30
        const val PAGE_FRAMES = 12
        const val TURN_FRAMES = 8
        const val PAGE_LEFT = 80
        const val PAGE_TOP = 30
        const val PAGE_RIGHT = 230
        const val PAGE_BOTTOM = 210
        const val MAX_PAGE_HEIGHT = 360
        const val CORNER_TOLERANCE = 4f
        const val BUSY_POLL_MILLISECONDS = 20L

        const val DESK_LUMA: Byte = 70
        const val PAPER_LUMA = 200.toByte()
        const val DOT_LUMA: Byte = 120
        const val BAR_LUMA: Byte = 40
        const val NEUTRAL_CHROMA = 128.toByte()
        const val DESK_CHROMA = 150.toByte()
    }
}

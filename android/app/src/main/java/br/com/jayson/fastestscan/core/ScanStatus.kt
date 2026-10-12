package br.com.jayson.fastestscan.core

/** A point in pixels of the upright full-size frame. */
data class FramePoint(val x: Float, val y: Float)

/** The corners of a page: top left, top right, bottom right, bottom left. */
data class PageCorners(val points: List<FramePoint>)

/** What the library knows after one frame. */
data class ScanStatus(
    /** The pages that the frame shows: none, one page, or the two pages of a spread. */
    val pages: List<PageCorners>,
    /** True when the pages stay at one place: a spread is in view. */
    val steady: Boolean,
    /** True when the view is long enough for a spread: the user can turn the page. */
    val captured: Boolean,
    /** The spreads of the document so far. */
    val spreads: Int,
    /** The pages that are complete. */
    val completePages: Int,
    /** The full-size frames in memory. */
    val heldFrames: Int,
) {
    companion object {
        private const val VALUES_PER_PAGE = 8

        /** The status from the values that `Native.streamPush` wrote. */
        fun fromValues(values: FloatArray): ScanStatus {
            val detected = values[Native.STATUS_DETECTED] != 0f
            val pageCount = if (detected) values[Native.STATUS_PAGE_COUNT].toInt() else 0
            val pages = List(pageCount) { page ->
                val first = Native.STATUS_CORNERS + page * VALUES_PER_PAGE
                PageCorners(List(VALUES_PER_PAGE / 2) { corner -> FramePoint(values[first + 2 * corner], values[first + 2 * corner + 1]) })
            }
            return ScanStatus(
                pages = pages,
                steady = values[Native.STATUS_STEADY] != 0f,
                captured = values[Native.STATUS_CAPTURED] != 0f,
                spreads = values[Native.STATUS_SPREADS].toInt(),
                completePages = values[Native.STATUS_PAGES].toInt(),
                heldFrames = values[Native.STATUS_HELD_FRAMES].toInt(),
            )
        }
    }
}

/** One complete page of the document. */
data class ScanPage(
    val width: Int,
    val height: Int,
    val gray: Boolean,
    /** A complete JPEG file. */
    val jpeg: ByteArray,
)

/** An error of the native library. */
class ScanException(val result: Int) : RuntimeException(Native.resultMessage(result))

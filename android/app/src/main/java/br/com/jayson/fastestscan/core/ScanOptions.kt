package br.com.jayson.fastestscan.core

/** How the 8-bit luma and chroma codes of a frame map to light. */
enum class ColorRange(val code: Int) {
    /** Luma 16..235: video. */
    LIMITED(0),

    /** Luma 0..255: most camera frames. */
    FULL(1),
}

enum class ColorMatrix(val code: Int) {
    /** HD video. */
    BT709(0),

    /** SD video, JPEG, and most camera frames. */
    BT601(1),
}

enum class PageLayout(val code: Int) {
    AUTO(0),

    /** One page in view. */
    SINGLE(1),

    /** Two pages side by side. */
    SPREAD(2),
}

/** What to do with a finger that holds the page in all frames. */
enum class FingerPaint(val code: Int) {
    /** Paint over it with the colour of the paper. */
    ALL(0),

    /** Paint only when the paper around it is blank. */
    BLANK(1),

    /** Leave it. */
    KEEP(2),
}

/**
 * The frames of one source. The size is the size of the buffers, before the
 * rotation.
 */
data class FrameFormat(
    val width: Int,
    val height: Int,
    /** The turn, clockwise, that brings a frame to the upright view: 0, 90, 180, or 270. */
    val rotationDegrees: Int,
    val colorRange: ColorRange,
    val colorMatrix: ColorMatrix,
    /** The frame rate of the source. 0: the library measures it from the frame times. */
    val framesPerSecond: Float = 0f,
)

/**
 * The settings of a scan. The defaults are for a phone: the memory of a scan grows
 * with each of the first four values. See docs/decisions/0019 in the repository.
 */
data class ScanOptions(
    /** The other frames that the library keeps for a spread, to repair glare: 0 to 12. */
    val donorFrames: Int = DEFAULT_DONOR_FRAMES,
    /** The largest number of full-size frames in memory. A frame of 3840 x 2160 pixels takes 12 MB. */
    val maxHeldFrames: Int = DEFAULT_MAX_HELD_FRAMES,
    /** The largest height of a page image in pixels. */
    val maxPageHeight: Int = DEFAULT_MAX_PAGE_HEIGHT,
    /** The number of threads that render pages. Each one takes some hundred MB while it works. */
    val renderThreads: Int = DEFAULT_RENDER_THREADS,
    val layout: PageLayout = PageLayout.AUTO,
    val fingers: FingerPaint = FingerPaint.ALL,
    /** 1 (worst) to 100 (best). */
    val jpegQuality: Int = DEFAULT_JPEG_QUALITY,
    /** Pixels per inch of the pages. It sets the paper size in the PDF. */
    val dpi: Int = DEFAULT_DPI,
) {
    companion object {
        const val DEFAULT_DONOR_FRAMES = 4
        const val DEFAULT_MAX_HELD_FRAMES = 24
        const val DEFAULT_MAX_PAGE_HEIGHT = 2000
        const val DEFAULT_RENDER_THREADS = 2
        const val DEFAULT_JPEG_QUALITY = 85
        const val DEFAULT_DPI = 300
    }
}

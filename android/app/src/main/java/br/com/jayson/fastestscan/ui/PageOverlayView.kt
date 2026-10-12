package br.com.jayson.fastestscan.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import android.view.View
import br.com.jayson.fastestscan.core.PageCorners
import br.com.jayson.fastestscan.core.ScanStatus
import kotlin.math.min

/**
 * The outline of each page that the library finds, on top of the camera preview.
 * The colour says what the user can do: wait, or turn the page.
 *
 * The view and the preview show the upright frame in the same way: the whole
 * frame, as large as the view allows, in the middle.
 */
class PageOverlayView @JvmOverloads constructor(context: Context, attributes: AttributeSet? = null) : View(context, attributes) {
    private var frameWidth = 0
    private var frameHeight = 0
    private var pages: List<PageCorners> = emptyList()
    private var color = COLOR_SEARCHING
    private val outline = Path()
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = STROKE_DP * resources.displayMetrics.density
        strokeJoin = Paint.Join.ROUND
    }

    /** Show the pages of a frame. The size is the size of the upright frame in pixels. */
    fun show(uprightWidth: Int, uprightHeight: Int, status: ScanStatus) {
        frameWidth = uprightWidth
        frameHeight = uprightHeight
        pages = status.pages
        color = when {
            status.captured -> COLOR_CAPTURED
            status.steady -> COLOR_STEADY
            else -> COLOR_SEARCHING
        }
        invalidate()
    }

    fun clear() {
        pages = emptyList()
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        if (frameWidth == 0 || frameHeight == 0 || pages.isEmpty()) return
        val scale = min(width.toFloat() / frameWidth, height.toFloat() / frameHeight)
        val left = (width - frameWidth * scale) / 2
        val top = (height - frameHeight * scale) / 2
        paint.color = color
        for (page in pages) {
            outline.rewind()
            page.points.forEachIndexed { index, point ->
                val x = left + point.x * scale
                val y = top + point.y * scale
                if (index == 0) outline.moveTo(x, y) else outline.lineTo(x, y)
            }
            outline.close()
            canvas.drawPath(outline, paint)
        }
    }

    private companion object {
        const val STROKE_DP = 3f

        /** White: the library sees a page that moves. */
        const val COLOR_SEARCHING = 0xFFFFFFFF.toInt()

        /** Yellow: the page is steady. Hold the phone. */
        const val COLOR_STEADY = 0xFFFFD54F.toInt()

        /** Green: the library has the page. Turn to the next page. */
        const val COLOR_CAPTURED = 0xFF66BB6A.toInt()
    }
}

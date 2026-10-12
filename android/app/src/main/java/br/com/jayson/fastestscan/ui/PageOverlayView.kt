package br.com.jayson.fastestscan.ui

import android.content.Context
import android.graphics.Canvas
import android.graphics.Matrix
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import android.view.View
import br.com.jayson.fastestscan.core.PageCorners
import br.com.jayson.fastestscan.core.ScanStatus

/**
 * The outline of each page that the library finds, on top of the camera preview.
 * The colour says what the user can do: wait, or turn the page.
 *
 * The view has the place and the size of the preview view: a point of the preview
 * view is the same point of this view.
 */
class PageOverlayView @JvmOverloads constructor(context: Context, attributes: AttributeSet? = null) : View(context, attributes) {
    private val frameToView = Matrix()
    private var pages: List<PageCorners> = emptyList()
    private var color = COLOR_SEARCHING
    private val outline = Path()
    private val point = FloatArray(2)
    private val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = STROKE_DP * resources.displayMetrics.density
        strokeJoin = Paint.Join.ROUND
    }

    /**
     * Show the pages of a frame. [frameToView] maps a point of the upright frame,
     * which is where the corners of [status] are, to a point of this view.
     */
    fun show(frameToView: Matrix, status: ScanStatus) {
        this.frameToView.set(frameToView)
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
        if (pages.isEmpty()) return
        paint.color = color
        for (page in pages) {
            outline.rewind()
            page.points.forEachIndexed { index, corner ->
                point[0] = corner.x
                point[1] = corner.y
                frameToView.mapPoints(point)
                if (index == 0) outline.moveTo(point[0], point[1]) else outline.lineTo(point[0], point[1])
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

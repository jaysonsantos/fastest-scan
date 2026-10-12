package br.com.jayson.fastestscan.source

import android.graphics.Rect
import br.com.jayson.fastestscan.core.ScanSession
import br.com.jayson.fastestscan.core.ScanStatus
import java.nio.ByteBuffer

/**
 * One plane of a YUV 4:2:0 frame of Android: the buffer of
 * `android.media.Image.Plane` or of a CameraX `PlaneProxy`.
 */
class FramePlane(val buffer: ByteBuffer, val rowStride: Int, val pixelStride: Int)

/**
 * Give one frame to the session. [crop] is the part of the buffers that holds the
 * picture: a decoder can give buffers that are larger than the picture.
 */
fun ScanSession.pushFrame(planes: List<FramePlane>, crop: Rect, seconds: Double): ScanStatus {
    require(planes.size == PLANE_COUNT) { "a YUV 4:2:0 frame has three planes" }
    val (y, u, v) = planes
    return push(
        y = y.startingAt(crop.left, crop.top),
        u = u.startingAt(crop.left / CHROMA_SUBSAMPLING, crop.top / CHROMA_SUBSAMPLING),
        v = v.startingAt(crop.left / CHROMA_SUBSAMPLING, crop.top / CHROMA_SUBSAMPLING),
        yStride = y.rowStride,
        chromaStride = u.rowStride,
        chromaStep = u.pixelStride,
        seconds = seconds,
    )
}

/**
 * The buffer of the plane from the sample at a column and a row. The native code
 * takes the address of the first byte of a buffer, so a part of a plane needs a
 * buffer of its own: a slice, which shares the memory.
 */
private fun FramePlane.startingAt(column: Int, row: Int): ByteBuffer {
    val offset = row * rowStride + column * pixelStride
    if (offset == 0) return buffer
    val view = buffer.duplicate()
    view.position(offset)
    return view.slice()
}

private const val PLANE_COUNT = 3
private const val CHROMA_SUBSAMPLING = 2

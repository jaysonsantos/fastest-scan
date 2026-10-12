package br.com.jayson.fastestscan.source

import android.content.Context
import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaExtractor
import android.media.MediaFormat
import android.net.Uri
import br.com.jayson.fastestscan.core.ColorMatrix
import br.com.jayson.fastestscan.core.ColorRange
import br.com.jayson.fastestscan.core.FrameFormat
import br.com.jayson.fastestscan.core.ScanSession
import br.com.jayson.fastestscan.core.ScanStatus

/**
 * A recorded video as a source of frames: the decoder of the phone runs one time
 * through the file, in order, and each frame goes to the session.
 *
 * The decoder gives its frames in buffers of its own (no surface), so the native
 * code reads them with no copy. The frames have 8 bits per sample: a video with 10
 * bits (HDR) is not supported.
 */
class VideoFileSource(private val context: Context, private val uri: Uri) {
    /** Tells the caller how far the decoder is, and what the session knows. */
    fun interface Progress {
        /** [fraction] is the part of the video that is done, 0 to 1. */
        fun onFrame(fraction: Float, status: ScanStatus)
    }

    /**
     * Decode the video and push each frame. [createSession] makes the session when
     * the size of the frames is known: with the first frame. [isCancelled] stops
     * the run between two frames. Returns the session, or null when the video has
     * no frame. The caller calls `finish` and `close` on it.
     */
    fun run(
        createSession: (FrameFormat) -> ScanSession,
        progress: Progress,
        isCancelled: () -> Boolean,
    ): ScanSession? {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        var session: ScanSession? = null
        try {
            extractor.setDataSource(context, uri, null)
            val track = (0 until extractor.trackCount).firstOrNull { index ->
                extractor.getTrackFormat(index).getString(MediaFormat.KEY_MIME)?.startsWith(VIDEO_MIME_PREFIX) == true
            } ?: throw IllegalArgumentException("the file has no video track")
            extractor.selectTrack(track)
            val trackFormat = extractor.getTrackFormat(track)
            val mime = trackFormat.getString(MediaFormat.KEY_MIME)!!
            val durationUs = if (trackFormat.containsKey(MediaFormat.KEY_DURATION)) trackFormat.getLong(MediaFormat.KEY_DURATION) else 0L
            // The decoder does not turn the frames: the library does it.
            val rotation = if (trackFormat.containsKey(MediaFormat.KEY_ROTATION)) trackFormat.getInteger(MediaFormat.KEY_ROTATION) else 0
            val frameRate = frameRate(trackFormat)

            trackFormat.setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatYUV420Flexible)
            val decoder = MediaCodec.createDecoderByType(mime)
            codec = decoder
            decoder.configure(trackFormat, null, null, 0)
            decoder.start()

            val info = MediaCodec.BufferInfo()
            var inputDone = false
            while (!isCancelled()) {
                if (!inputDone) {
                    val inputIndex = decoder.dequeueInputBuffer(DEQUEUE_TIMEOUT_US)
                    if (inputIndex >= 0) {
                        val size = extractor.readSampleData(decoder.getInputBuffer(inputIndex)!!, 0)
                        if (size < 0) {
                            decoder.queueInputBuffer(inputIndex, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                            inputDone = true
                        } else {
                            decoder.queueInputBuffer(inputIndex, 0, size, extractor.sampleTime, 0)
                            extractor.advance()
                        }
                    }
                }
                val outputIndex = decoder.dequeueOutputBuffer(info, DEQUEUE_TIMEOUT_US)
                if (outputIndex < 0) continue
                try {
                    val image = if (info.size > 0) decoder.getOutputImage(outputIndex) else null
                    if (image != null) {
                        image.use {
                            val crop = image.cropRect
                            val current = session ?: createSession(
                                FrameFormat(
                                    width = crop.width(),
                                    height = crop.height(),
                                    rotationDegrees = rotation,
                                    colorRange = colorRange(decoder.outputFormat),
                                    colorMatrix = colorMatrix(decoder.outputFormat),
                                    framesPerSecond = frameRate,
                                ),
                            ).also { session = it }
                            val planes = image.planes.map { FramePlane(it.buffer, it.rowStride, it.pixelStride) }
                            val status = current.pushFrame(planes, crop, info.presentationTimeUs / MICROSECONDS_PER_SECOND)
                            val fraction = if (durationUs > 0) info.presentationTimeUs.toFloat() / durationUs else 0f
                            progress.onFrame(fraction.coerceIn(0f, 1f), status)
                        }
                    }
                } finally {
                    decoder.releaseOutputBuffer(outputIndex, false)
                }
                if (info.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) break
            }
            return session
        } catch (error: Throwable) {
            session?.close()
            throw error
        } finally {
            codec?.let {
                runCatching { it.stop() }
                it.release()
            }
            extractor.release()
        }
    }

    private companion object {
        const val VIDEO_MIME_PREFIX = "video/"

        /** The decoder gets this much time for an input or an output buffer. */
        const val DEQUEUE_TIMEOUT_US = 10_000L
        const val MICROSECONDS_PER_SECOND = 1_000_000.0

        /**
         * The frame rate of the track, or 0 when the file does not give one: the
         * library then measures it. A file can have the value as a whole number or
         * as a number with a fraction.
         */
        fun frameRate(format: MediaFormat): Float {
            if (!format.containsKey(MediaFormat.KEY_FRAME_RATE)) return 0f
            return try {
                format.getInteger(MediaFormat.KEY_FRAME_RATE).toFloat()
            } catch (notWhole: ClassCastException) {
                format.getFloat(MediaFormat.KEY_FRAME_RATE)
            }
        }

        /** Phone video has the limited range, when the file does not say another one. */
        fun colorRange(format: MediaFormat): ColorRange {
            if (!format.containsKey(MediaFormat.KEY_COLOR_RANGE)) return ColorRange.LIMITED
            return if (format.getInteger(MediaFormat.KEY_COLOR_RANGE) == MediaFormat.COLOR_RANGE_FULL) ColorRange.FULL else ColorRange.LIMITED
        }

        /** HD video has the matrix BT.709, when the file does not say another one. */
        fun colorMatrix(format: MediaFormat): ColorMatrix {
            if (!format.containsKey(MediaFormat.KEY_COLOR_STANDARD)) return ColorMatrix.BT709
            return when (format.getInteger(MediaFormat.KEY_COLOR_STANDARD)) {
                MediaFormat.COLOR_STANDARD_BT601_PAL, MediaFormat.COLOR_STANDARD_BT601_NTSC -> ColorMatrix.BT601
                else -> ColorMatrix.BT709
            }
        }
    }
}

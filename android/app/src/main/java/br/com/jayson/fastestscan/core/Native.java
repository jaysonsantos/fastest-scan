package br.com.jayson.fastestscan.core;

import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;

/**
 * The functions of the native library {@code fastscan_jni}: the C interface of
 * {@code include/fastscan.h}, one function for one function.
 *
 * <p>A handle is the address of a native object. The value 0 is no object. The class
 * {@code ScanSession} keeps the handles and the thread rules: use that class, not
 * this one.
 *
 * <p>This file is Java, not Kotlin, so that a test on a desktop Java machine can
 * compile it with no Android tool: {@code scripts/test-jni.sh}.
 */
public final class Native {
    /** The number of values that {@link #streamPush} writes into {@code status}. */
    public static final int STATUS_LENGTH = 24;

    /** Positions in the {@code status} array of {@link #streamPush}. */
    public static final int STATUS_DETECTED = 0;
    public static final int STATUS_PAGE_COUNT = 1;
    /**
     * The first of 16 values: for each of two pages, x and y of the top left, the
     * top right, the bottom right, and the bottom left corner, in pixels of the
     * upright full-size frame.
     */
    public static final int STATUS_CORNERS = 2;
    public static final int STATUS_STEADY = 18;
    public static final int STATUS_CAPTURED = 19;
    public static final int STATUS_SPREADS = 20;
    public static final int STATUS_PAGES = 21;
    public static final int STATUS_JOBS_READY = 22;
    public static final int STATUS_HELD_FRAMES = 23;

    /** The number of values that {@link #streamPageInfo} writes into {@code info}. */
    public static final int PAGE_INFO_LENGTH = 5;

    public static final int PAGE_INFO_WIDTH = 0;
    public static final int PAGE_INFO_HEIGHT = 1;
    public static final int PAGE_INFO_GRAY = 2;
    public static final int PAGE_INFO_SPREAD = 3;
    public static final int PAGE_INFO_INDEX = 4;

    /** The result of a function that had no error. */
    public static final int OK = 0;

    static {
        System.loadLibrary("fastscan_jni");
    }

    private Native() {}

    public static native String version();

    public static native String resultMessage(int result);

    /** Returns a worker handle, or 0 when the memory is full. */
    public static native long workerCreate();

    public static native void workerDestroy(long worker);

    public static native void workerReleaseMemory(long worker);

    /**
     * Returns a stream handle.
     *
     * @throws IllegalArgumentException when a value is not valid
     * @throws OutOfMemoryError when the memory is full
     */
    public static native long streamCreate(
            int width,
            int height,
            int rotationDegrees,
            int colorRange,
            int colorMatrix,
            float framesPerSecond,
            int layout,
            int donorFrames,
            int maxHeldFrames,
            int maxPageHeight,
            int jpegQuality,
            int dpi,
            int fingers);

    public static native void streamDestroy(long stream);

    /**
     * Take the next frame. The three buffers are direct buffers: the planes of an
     * {@code android.media.Image}. The native code reads them during the call only.
     *
     * @param status gets {@link #STATUS_LENGTH} values, or null
     * @return a result code
     */
    public static native int streamPush(
            long stream,
            long worker,
            ByteBuffer y,
            ByteBuffer u,
            ByteBuffer v,
            int yStride,
            int chromaStride,
            int chromaStep,
            double seconds,
            float[] status);

    public static native int streamFinish(long stream, long worker);

    /** Returns a job handle, or 0 when no job is ready. */
    public static native long streamTakeJob(long stream);

    /** The slow step. It can run on another thread than the functions of the stream. */
    public static native int jobRun(long job, long worker);

    public static native void streamCompleteJob(long stream, long job, int runResult);

    public static native boolean streamBusy(long stream);

    public static native int streamPageCount(long stream);

    /** Returns a copy of the JPEG file of a page, or null when the page does not exist. */
    public static native byte[] streamPageJpeg(long stream, int index);

    /**
     * @param info gets {@link #PAGE_INFO_LENGTH} values
     * @return a result code
     */
    public static native int streamPageInfo(long stream, int index, int[] info);

    /**
     * Write the complete pages as a PDF. Returns a result code.
     *
     * @throws IOException the exception of {@code output}, when a write fails
     */
    public static native int streamWritePdf(long stream, OutputStream output) throws IOException;
}

import br.com.jayson.fastestscan.core.Native;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.StandardCharsets;

/**
 * A test of the JNI layer on the Java machine of a desktop: the same native code
 * and the same class {@code Native} as in the Android app. {@code
 * scripts/test-jni.sh} builds and runs it.
 *
 * <p>The video is synthetic: two pages, each in view for 12 frames, with the desk
 * between them. The frames have the layout of an Android camera frame: a row
 * stride larger than the width, and the U and the V samples in turn in one buffer.
 */
public final class NativeSmoke {
    private static final int WIDTH = 320;
    private static final int HEIGHT = 240;
    private static final int STRIDE = 336;
    private static final int CHROMA_STEP = 2;
    private static final int FRAMES_PER_SECOND = 30;
    private static final int PAGE_FRAMES = 12;
    private static final int TURN_FRAMES = 8;
    private static final int PAGE_LEFT = 80;
    private static final int PAGE_TOP = 30;
    private static final int PAGE_RIGHT = 230;
    private static final int PAGE_BOTTOM = 210;
    private static final int MAX_PAGE_HEIGHT = 360;
    private static final int CORNER_TOLERANCE = 4;

    private static final int COLOR_RANGE_LIMITED = 0;
    private static final int COLOR_MATRIX_BT709 = 0;
    private static final int LAYOUT_AUTO = 0;
    private static final int FINGERS_ALL = 0;
    private static final int DONOR_FRAMES = 4;
    private static final int JPEG_QUALITY = 85;
    private static final int DPI = 300;
    private static final int RESULT_INVALID_FRAME = 3;
    private static final int RESULT_STREAM_ENDED = 4;

    private static final byte DESK_LUMA = 70;
    private static final byte PAPER_LUMA = (byte) 200;
    private static final byte DOT_LUMA = 120;
    private static final byte BAR_LUMA = 40;
    private static final byte NEUTRAL_CHROMA = (byte) 128;
    private static final byte DESK_CHROMA = (byte) 150;

    private NativeSmoke() {}

    private static void check(boolean condition, String what) {
        if (!condition) throw new AssertionError(what);
    }

    /**
     * A dark desk and, when the seed is not 0, a bright page with dots and a dark bar.
     * Two seeds are two different pages.
     */
    private static void fillFrame(ByteBuffer luma, ByteBuffer chroma, int seed) {
        for (int index = 0; index < luma.capacity(); index++) luma.put(index, DESK_LUMA);
        for (int row = 0; row < HEIGHT / 2; row++) {
            for (int column = 0; column < WIDTH / 2; column++) {
                chroma.put(row * STRIDE + 2 * column, NEUTRAL_CHROMA);
                chroma.put(row * STRIDE + 2 * column + 1, DESK_CHROMA);
            }
        }
        if (seed == 0) return;
        float barTop = 0.25f + 0.1f * (seed % 5);
        for (int row = PAGE_TOP; row < PAGE_BOTTOM; row++) {
            for (int column = PAGE_LEFT; column < PAGE_RIGHT; column++) {
                float across = (float) (column - PAGE_LEFT) / (PAGE_RIGHT - PAGE_LEFT);
                float down = (float) (row - PAGE_TOP) / (PAGE_BOTTOM - PAGE_TOP);
                boolean onBar = across > 0.2f && across < 0.8f && down > barTop && down < barTop + 0.12f;
                int dotColumn = (int) (across * 40.0f);
                int dotRow = (int) (down * 50.0f);
                boolean dot = (dotColumn * (7 + seed) + dotRow * (13 + 2 * seed)) % 11 == 0;
                luma.put(row * STRIDE + column, onBar ? BAR_LUMA : dot ? DOT_LUMA : PAPER_LUMA);
                chroma.put((row / 2) * STRIDE + 2 * (column / 2) + 1, NEUTRAL_CHROMA);
            }
        }
    }

    /** Run each job that is ready. Returns the number of jobs. */
    private static int runJobs(long stream, long worker) {
        int count = 0;
        while (true) {
            long job = Native.streamTakeJob(stream);
            if (job == 0) return count;
            int result = Native.jobRun(job, worker);
            Native.streamCompleteJob(stream, job, result);
            check(result == Native.OK, "job: " + Native.resultMessage(result));
            count++;
        }
    }

    public static void main(String[] arguments) throws IOException {
        check(!Native.version().isEmpty(), "the version is empty");
        check(Native.resultMessage(Native.OK).equals("no error"), "the text of the result 0");

        boolean refused = false;
        try {
            Native.streamCreate(WIDTH, HEIGHT, 45, COLOR_RANGE_LIMITED, COLOR_MATRIX_BT709, 0, LAYOUT_AUTO,
                    DONOR_FRAMES, 0, MAX_PAGE_HEIGHT, JPEG_QUALITY, DPI, FINGERS_ALL);
        } catch (IllegalArgumentException expected) {
            refused = true;
        }
        check(refused, "a rotation of 45 degrees must be an error");

        long stream = Native.streamCreate(WIDTH, HEIGHT, 0, COLOR_RANGE_LIMITED, COLOR_MATRIX_BT709,
                FRAMES_PER_SECOND, LAYOUT_AUTO, DONOR_FRAMES, 0, MAX_PAGE_HEIGHT, JPEG_QUALITY, DPI, FINGERS_ALL);
        long worker = Native.workerCreate();
        check(stream != 0 && worker != 0, "the stream and the worker");

        // The sizes of the plane buffers of an Android frame: to the last sample, not to the end of the row.
        ByteBuffer luma = ByteBuffer.allocateDirect(STRIDE * (HEIGHT - 1) + WIDTH);
        ByteBuffer chroma = ByteBuffer.allocateDirect(STRIDE * (HEIGHT / 2 - 1) + WIDTH);
        ByteBuffer u = chroma.duplicate();
        // The V samples start one byte after the U samples.
        ByteBuffer v = chroma.duplicate().position(1).slice();

        float[] status = new float[Native.STATUS_LENGTH];
        int[] seeds = {1, 0, 2, 0};
        int index = 0;
        int jobs = 0;
        boolean captured = false;
        for (int seed : seeds) {
            fillFrame(luma, chroma, seed);
            int frames = seed == 0 ? TURN_FRAMES : PAGE_FRAMES;
            for (int step = 0; step < frames; step++) {
                double seconds = (double) index / FRAMES_PER_SECOND;
                index++;
                int result = Native.streamPush(stream, worker, luma, u, v, STRIDE, STRIDE, CHROMA_STEP, seconds, status);
                check(result == Native.OK, "push: " + Native.resultMessage(result));
                check((status[Native.STATUS_DETECTED] != 0) == (seed != 0), "detected, frame " + index);
                if (seed != 0) {
                    check(status[Native.STATUS_PAGE_COUNT] == 1, "one page");
                    check(Math.abs(status[Native.STATUS_CORNERS] - PAGE_LEFT) < CORNER_TOLERANCE, "left side");
                    check(Math.abs(status[Native.STATUS_CORNERS + 1] - PAGE_TOP) < CORNER_TOLERANCE, "top side");
                    check(Math.abs(status[Native.STATUS_CORNERS + 4] - PAGE_RIGHT) < CORNER_TOLERANCE, "right side");
                    check(Math.abs(status[Native.STATUS_CORNERS + 5] - PAGE_BOTTOM) < CORNER_TOLERANCE, "bottom side");
                }
                captured = captured || status[Native.STATUS_CAPTURED] != 0;
                jobs += runJobs(stream, worker);
            }
        }
        check(captured, "no view was long enough for a spread");
        check(status[Native.STATUS_SPREADS] == 2, "two spreads");
        check(jobs == 1, "the first page must be complete while the video runs");
        check(Native.streamPageCount(stream) == 1, "one page before the end");

        // A buffer that is too short for the frame size must not reach the library.
        ByteBuffer small = ByteBuffer.allocateDirect(16);
        check(Native.streamPush(stream, worker, small, u, v, STRIDE, STRIDE, CHROMA_STEP, 0, null) == RESULT_INVALID_FRAME,
                "a short buffer must be an error");

        check(Native.streamFinish(stream, worker) == Native.OK, "finish");
        check(Native.streamPush(stream, worker, luma, u, v, STRIDE, STRIDE, CHROMA_STEP, 0, null) == RESULT_STREAM_ENDED,
                "a frame after the end must be an error");
        check(Native.streamBusy(stream), "a job must be ready after the end");
        check(runJobs(stream, worker) == 1, "the job of the last page");
        check(!Native.streamBusy(stream), "no job after the last one");
        check(Native.streamPageCount(stream) == 2, "two pages");

        int[] info = new int[Native.PAGE_INFO_LENGTH];
        for (int page = 0; page < 2; page++) {
            check(Native.streamPageInfo(stream, page, info) == Native.OK, "page info");
            check(info[Native.PAGE_INFO_HEIGHT] == MAX_PAGE_HEIGHT, "the page height");
            check(info[Native.PAGE_INFO_WIDTH] > 0 && info[Native.PAGE_INFO_WIDTH] < MAX_PAGE_HEIGHT, "the page width");
            check(info[Native.PAGE_INFO_SPREAD] == page && info[Native.PAGE_INFO_INDEX] == 0, "the place of the page");
            byte[] jpeg = Native.streamPageJpeg(stream, page);
            check(jpeg != null && jpeg.length > 100, "the JPEG of the page");
            check((jpeg[0] & 0xFF) == 0xFF && (jpeg[1] & 0xFF) == 0xD8, "the start marker of the JPEG");
        }
        check(Native.streamPageJpeg(stream, 2) == null, "no third page");

        ByteArrayOutputStream pdf = new ByteArrayOutputStream();
        check(Native.streamWritePdf(stream, pdf) == Native.OK, "the PDF");
        String head = new String(pdf.toByteArray(), 0, 5, StandardCharsets.US_ASCII);
        check(head.equals("%PDF-"), "the PDF header");
        check(pdf.size() > 1000, "the PDF size");

        // An error of the Java stream comes back as an exception.
        OutputStream broken = new OutputStream() {
            @Override
            public void write(int value) throws IOException {
                throw new IOException("the disk is full");
            }
        };
        boolean failed = false;
        try {
            Native.streamWritePdf(stream, broken);
        } catch (IOException expected) {
            failed = expected.getMessage().equals("the disk is full");
        }
        check(failed, "the exception of the Java stream must come back");

        Native.workerReleaseMemory(worker);
        Native.workerDestroy(worker);
        Native.streamDestroy(stream);
        System.out.println("jni: 2 pages, " + pdf.size() + " bytes of PDF, fastscan " + Native.version());
    }
}

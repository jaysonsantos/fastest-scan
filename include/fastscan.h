/* fastscan: turn frames of a filmed book or document into a PDF.
 *
 * The C interface of the library in src/lib/. It is the base for a JNI layer or a
 * binding in another language.
 *
 * The flow is a stream session. The frames of a video go in one time, in the order
 * of the video: from a camera, or from a decoder that runs one time through a file.
 * The pages of the document come out while the video runs.
 *
 *   fastscan_options options;
 *   fastscan_options_init(&options);
 *   options.width = 3840;
 *   options.height = 2160;
 *   fastscan_stream *stream;
 *   fastscan_stream_create(&options, &stream);
 *   fastscan_worker *worker = fastscan_worker_create();
 *
 *   for each frame:
 *     fastscan_stream_push(stream, worker, &frame, &status);
 *     while ((job = fastscan_stream_take_job(stream)) != NULL) {
 *       int result = fastscan_job_run(job, worker);   (can run on another thread)
 *       fastscan_stream_complete_job(stream, job, result);
 *     }
 *   fastscan_stream_finish(stream, worker);
 *   run the jobs that are left, as above
 *   fastscan_stream_write_pdf(stream, write, context);
 *
 * Threads:
 * - One thread at a time calls the functions of a stream. The library has no lock.
 * - fastscan_job_run works on the job only. It can run on another thread while the
 *   stream takes frames. Each thread has its own worker.
 * - A worker is the working memory of one thread. One thread at a time uses it.
 *
 * Results: each function with the type int returns FASTSCAN_OK or an error code.
 * fastscan_result_message gives a text for a code.
 */
#ifndef FASTSCAN_H
#define FASTSCAN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* region: results */

#define FASTSCAN_OK 0
#define FASTSCAN_OUT_OF_MEMORY 1
#define FASTSCAN_INVALID_ARGUMENT 2
/* The frame has another size than the stream, or a plane is too short. */
#define FASTSCAN_INVALID_FRAME 3
/* A frame came after fastscan_stream_finish. */
#define FASTSCAN_STREAM_ENDED 4
/* A side of the page is zero or above 65535 pixels. */
#define FASTSCAN_UNSUPPORTED_DIMENSIONS 5
/* The write function of the caller returned an error. */
#define FASTSCAN_WRITE_FAILED 6

/* The version of the library. The string lives as long as the program. */
const char *fastscan_version(void);

/* A text for a result code. The string lives as long as the program. */
const char *fastscan_result_message(int result);

/* endregion: results */

/* region: options */

#define FASTSCAN_RANGE_LIMITED 0 /* luma 16..235: video */
#define FASTSCAN_RANGE_FULL 1    /* luma 0..255: most camera frames */

#define FASTSCAN_MATRIX_BT709 0 /* HD video */
#define FASTSCAN_MATRIX_BT601 1 /* SD video, JPEG, most camera frames */

#define FASTSCAN_LAYOUT_AUTO 0
#define FASTSCAN_LAYOUT_SINGLE 1 /* one page in view */
#define FASTSCAN_LAYOUT_SPREAD 2 /* two pages side by side */

/* A finger that holds the page in all frames. */
#define FASTSCAN_FINGERS_ALL 0   /* paint over it with the colour of the paper */
#define FASTSCAN_FINGERS_BLANK 1 /* only when the paper around it is blank */
#define FASTSCAN_FINGERS_KEEP 2  /* leave it */

typedef struct fastscan_options {
    /* sizeof(fastscan_options). fastscan_options_init sets it. */
    uint32_t struct_size;
    /* The size of the frames in pixels, as the source gives them: before the rotation. */
    uint32_t width;
    uint32_t height;
    /* The turn, clockwise, that brings a frame to the upright view: 0, 90, 180, or
     * 270. This is the rotation of a video track and of a camera frame on Android. */
    uint32_t rotation_degrees;
    uint32_t color_range;
    uint32_t color_matrix;
    /* The frame rate of the source. 0: the session measures it from the frame times. */
    float frames_per_second;
    uint32_t layout;
    /* The other frames that the session keeps for a spread, to repair glare and
     * covered parts: 0 to 12. Half as many views from near come in addition. Each
     * frame of 3840 x 2160 pixels takes 12 MB. */
    uint32_t donor_frames;
    /* The largest number of full-size frames in the session and its jobs. A spread
     * gets fewer other frames when the limit is near. 0: no limit. */
    uint32_t max_held_frames;
    /* The largest height of a page image in pixels. The working memory of a job
     * grows with the area of the page. */
    uint32_t max_page_height;
    /* 1 (worst) to 100 (best). */
    uint32_t jpeg_quality;
    /* Pixels per inch of the pages. It sets the paper size in the PDF. */
    uint32_t dpi;
    uint32_t fingers;
} fastscan_options;

/* Fill the options with the defaults. The caller then sets width and height. */
void fastscan_options_init(fastscan_options *options);

/* endregion: options */

/* region: workers */

/* The working memory of one thread. It keeps its large blocks for the next call. */
typedef struct fastscan_worker fastscan_worker;

/* Returns NULL when the memory is full. */
fastscan_worker *fastscan_worker_create(void);
void fastscan_worker_destroy(fastscan_worker *worker);

/* Give the large blocks that the worker keeps back to the system. The worker stays
 * in use. An app calls this when the system asks for memory. */
void fastscan_worker_release_memory(fastscan_worker *worker);

/* endregion: workers */

/* region: stream */

typedef struct fastscan_stream fastscan_stream;
typedef struct fastscan_job fastscan_job;

/* One frame of the source: YUV 4:2:0 with 8 bits per sample. The planes have the
 * size of the options of the stream. The library reads the frame during the call
 * only. */
typedef struct fastscan_frame {
    const uint8_t *y;
    const uint8_t *u;
    const uint8_t *v;
    /* The distance in bytes between two rows of the luma plane. */
    uint32_t y_stride;
    /* The distance in bytes between two rows of a chroma plane. */
    uint32_t chroma_stride;
    /* The distance in bytes between two samples of a chroma row: 1 for planar
     * frames (I420), 2 when the U and the V samples take turns (NV12, NV21). */
    uint32_t chroma_step;
    uint32_t reserved;
    /* The time of the frame in seconds. */
    double seconds;
} fastscan_frame;

#define FASTSCAN_MAX_PAGES 2

/* What the session knows after a frame. */
typedef struct fastscan_status {
    /* 1 when the frame shows a page. */
    uint32_t detected;
    /* 1 for a single page, 2 for a spread. */
    uint32_t page_count;
    /* For each page: x and y of the top left, the top right, the bottom right, and
     * the bottom left corner, in pixels of the upright full-size frame. */
    float corners[FASTSCAN_MAX_PAGES][8];
    /* 1 when the pages stay at one place: a spread is in view. */
    uint32_t steady;
    /* 1 when the view is long enough for a spread: the user can turn the page. */
    uint32_t captured;
    /* The spreads of the document so far. The last one can still change. */
    uint32_t spreads;
    /* The pages that are complete. */
    uint32_t pages;
    /* The jobs that wait for fastscan_stream_take_job. */
    uint32_t jobs_ready;
    /* The full-size frames in the session and its jobs. */
    uint32_t held_frames;
} fastscan_status;

/* One page of the document as a baseline JPEG file. */
typedef struct fastscan_page {
    const uint8_t *jpeg;
    size_t jpeg_size;
    uint32_t width;
    uint32_t height;
    /* 1 for a page with one grey component, 0 for a page with colour. */
    uint32_t gray;
    /* The number of the spread of the page in the video. */
    uint32_t spread;
    /* 0 for a single page or the left page, 1 for the right page. */
    uint32_t index;
    uint32_t reserved;
} fastscan_page;

/* Gets the bytes of the PDF in order. Returns 0, or another value to stop. */
typedef int (*fastscan_write_fn)(void *context, const uint8_t *bytes, size_t size);

int fastscan_stream_create(const fastscan_options *options, fastscan_stream **out);

/* Free a session. Give each job back with fastscan_stream_complete_job first. */
void fastscan_stream_destroy(fastscan_stream *stream);

/* Take the next frame of the video. status can be NULL. */
int fastscan_stream_push(fastscan_stream *stream, fastscan_worker *worker,
        const fastscan_frame *frame, fastscan_status *status);

/* The video has no more frames. The spreads that were open become jobs. */
int fastscan_stream_finish(fastscan_stream *stream, fastscan_worker *worker);

/* The next job, or NULL when no job is ready. A job holds the frames of one
 * spread. */
fastscan_job *fastscan_stream_take_job(fastscan_stream *stream);

/* Render the pages of a job. This is the slow step of a scan: it takes seconds,
 * not milliseconds. Run it on a thread that can wait. */
int fastscan_job_run(fastscan_job *job, fastscan_worker *worker);

/* Give a job back to its session. run_result is the result of fastscan_job_run,
 * or a value that is not FASTSCAN_OK when the job did not run. The session frees
 * the job. */
void fastscan_stream_complete_job(fastscan_stream *stream, fastscan_job *job, int run_result);

/* 1 when a job is ready or the caller has a job that it did not give back. */
int fastscan_stream_busy(const fastscan_stream *stream);

/* The number of pages that are complete, in the order of the document. The list
 * can change after each call of push, finish, and complete_job: a new page comes,
 * and a better view of a spread takes the place of an old one. */
uint32_t fastscan_stream_page_count(const fastscan_stream *stream);

/* One page. The bytes belong to the session: they are valid until the next call
 * of push, finish, complete_job, or destroy. */
int fastscan_stream_page(const fastscan_stream *stream, uint32_t index, fastscan_page *out);

/* The size of each page image. FASTSCAN_INVALID_ARGUMENT while the session does
 * not know it: the first two spreads give it. */
int fastscan_stream_page_size(const fastscan_stream *stream, uint32_t *width, uint32_t *height);

/* Write the pages that are complete as a PDF. */
int fastscan_stream_write_pdf(
        const fastscan_stream *stream, fastscan_write_fn write, void *context);

/* endregion: stream */

#ifdef __cplusplus
}
#endif

#endif /* FASTSCAN_H */

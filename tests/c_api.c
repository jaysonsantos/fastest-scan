/* A C program that uses the library through include/fastscan.h only: the check
 * that the header and src/lib/c_api.zig agree. `zig build test` builds and runs it.
 *
 * The video is synthetic: two pages, each in view for 12 frames, with the desk
 * between them. The result must be a PDF with two pages.
 */
#include "fastscan.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    WIDTH = 320,
    HEIGHT = 240,
    FRAMES_PER_SECOND = 30,
    PAGE_FRAMES = 12,
    TURN_FRAMES = 8,
    PAGE_LEFT = 80,
    PAGE_TOP = 30,
    PAGE_RIGHT = 230,
    PAGE_BOTTOM = 210,
    MAX_PAGE_HEIGHT = 360,
    PDF_CAPACITY = 1 << 20,
};

static const uint8_t DESK_LUMA = 70;
static const uint8_t PAPER_LUMA = 200;
static const uint8_t DOT_LUMA = 120;
static const uint8_t BAR_LUMA = 40;
static const uint8_t NEUTRAL_CHROMA = 128;
static const uint8_t DESK_CHROMA = 150;

#define CHECK(condition) \
    do { \
        if (!(condition)) { \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #condition); \
            return 1; \
        } \
    } while (0)

/* A planar frame: a dark desk and, when seed is not 0, a bright page with dots and
 * a dark bar. Two seeds are two different pages. */
static void fill_frame(uint8_t *y, uint8_t *u, uint8_t *v, unsigned seed) {
    memset(y, DESK_LUMA, (size_t)WIDTH * HEIGHT);
    memset(u, NEUTRAL_CHROMA, (size_t)(WIDTH / 2) * (HEIGHT / 2));
    memset(v, DESK_CHROMA, (size_t)(WIDTH / 2) * (HEIGHT / 2));
    if (seed == 0) return;
    const float bar_top = 0.25f + 0.1f * (float)(seed % 5);
    for (int row = PAGE_TOP; row < PAGE_BOTTOM; row++) {
        for (int column = PAGE_LEFT; column < PAGE_RIGHT; column++) {
            const float across = (float)(column - PAGE_LEFT) / (float)(PAGE_RIGHT - PAGE_LEFT);
            const float down = (float)(row - PAGE_TOP) / (float)(PAGE_BOTTOM - PAGE_TOP);
            const int on_bar =
                    across > 0.2f && across < 0.8f && down > bar_top && down < bar_top + 0.12f;
            const unsigned dot_column = (unsigned)(across * 40.0f);
            const unsigned dot_row = (unsigned)(down * 50.0f);
            const int dot = (dot_column * (7 + seed) + dot_row * (13 + 2 * seed)) % 11 == 0;
            y[row * WIDTH + column] = on_bar ? BAR_LUMA : dot ? DOT_LUMA : PAPER_LUMA;
            v[(row / 2) * (WIDTH / 2) + column / 2] = NEUTRAL_CHROMA;
        }
    }
}

typedef struct {
    uint8_t *bytes;
    size_t size;
} pdf_buffer;

static int collect(void *context, const uint8_t *bytes, size_t size) {
    pdf_buffer *buffer = context;
    if (buffer->size + size > PDF_CAPACITY) return 1;
    memcpy(buffer->bytes + buffer->size, bytes, size);
    buffer->size += size;
    return 0;
}

/* Run each job that is ready. Returns the number of jobs, or -1 after an error. */
static int run_jobs(fastscan_stream *stream, fastscan_worker *worker) {
    int count = 0;
    fastscan_job *job;
    while ((job = fastscan_stream_take_job(stream)) != NULL) {
        const int result = fastscan_job_run(job, worker);
        fastscan_stream_complete_job(stream, job, result);
        if (result != FASTSCAN_OK) {
            fprintf(stderr, "job: %s\n", fastscan_result_message(result));
            return -1;
        }
        count++;
    }
    return count;
}

int main(void) {
    CHECK(strlen(fastscan_version()) > 0);
    CHECK(strcmp(fastscan_result_message(FASTSCAN_OK), "no error") == 0);

    fastscan_options options;
    fastscan_options_init(&options);
    CHECK(options.struct_size == sizeof(fastscan_options));
    CHECK(options.color_range == FASTSCAN_RANGE_LIMITED);
    CHECK(options.jpeg_quality == 85);
    fastscan_stream *stream = NULL;
    /* No frame size yet. */
    CHECK(fastscan_stream_create(&options, &stream) == FASTSCAN_INVALID_ARGUMENT);
    options.width = WIDTH;
    options.height = HEIGHT;
    options.frames_per_second = FRAMES_PER_SECOND;
    options.max_page_height = MAX_PAGE_HEIGHT;
    CHECK(fastscan_stream_create(&options, &stream) == FASTSCAN_OK);
    fastscan_worker *worker = fastscan_worker_create();
    CHECK(worker != NULL);

    uint8_t *y = malloc((size_t)WIDTH * HEIGHT);
    uint8_t *u = malloc((size_t)(WIDTH / 2) * (HEIGHT / 2));
    uint8_t *v = malloc((size_t)(WIDTH / 2) * (HEIGHT / 2));
    CHECK(y != NULL && u != NULL && v != NULL);
    fastscan_frame frame = {
            .y = y,
            .u = u,
            .v = v,
            .y_stride = WIDTH,
            .chroma_stride = WIDTH / 2,
            .chroma_step = 1,
    };

    static const unsigned seeds[] = {1, 0, 2, 0};
    fastscan_status status;
    int index = 0;
    int jobs = 0;
    int captured = 0;
    for (size_t part = 0; part < sizeof(seeds) / sizeof(seeds[0]); part++) {
        fill_frame(y, u, v, seeds[part]);
        const int frames = seeds[part] == 0 ? TURN_FRAMES : PAGE_FRAMES;
        for (int step = 0; step < frames; step++) {
            frame.seconds = (double)index / FRAMES_PER_SECOND;
            index++;
            CHECK(fastscan_stream_push(stream, worker, &frame, &status) == FASTSCAN_OK);
            CHECK(status.detected == (seeds[part] != 0));
            if (status.detected) {
                CHECK(status.page_count == 1);
                /* The top left corner and the bottom right corner of the page. */
                CHECK(status.corners[0][0] > PAGE_LEFT - 3 && status.corners[0][0] < PAGE_LEFT + 3);
                CHECK(status.corners[0][1] > PAGE_TOP - 3 && status.corners[0][1] < PAGE_TOP + 3);
                CHECK(status.corners[0][4] > PAGE_RIGHT - 4 &&
                        status.corners[0][4] < PAGE_RIGHT + 3);
                CHECK(status.corners[0][5] > PAGE_BOTTOM - 4 &&
                        status.corners[0][5] < PAGE_BOTTOM + 3);
            }
            captured = captured || status.captured;
            const int done = run_jobs(stream, worker);
            CHECK(done >= 0);
            jobs += done;
        }
    }
    CHECK(captured);
    CHECK(status.spreads == 2);
    /* The first page is complete while the video still runs. */
    CHECK(jobs == 1);
    CHECK(fastscan_stream_page_count(stream) == 1);

    CHECK(fastscan_stream_finish(stream, worker) == FASTSCAN_OK);
    CHECK(fastscan_stream_push(stream, worker, &frame, NULL) == FASTSCAN_STREAM_ENDED);
    CHECK(fastscan_stream_busy(stream) == 1);
    CHECK(run_jobs(stream, worker) == 1);
    CHECK(fastscan_stream_busy(stream) == 0);
    CHECK(fastscan_stream_page_count(stream) == 2);

    uint32_t page_width = 0;
    uint32_t page_height = 0;
    CHECK(fastscan_stream_page_size(stream, &page_width, &page_height) == FASTSCAN_OK);
    CHECK(page_height == MAX_PAGE_HEIGHT);
    CHECK(page_width > 0 && page_width < page_height);
    for (uint32_t number = 0; number < 2; number++) {
        fastscan_page page;
        CHECK(fastscan_stream_page(stream, number, &page) == FASTSCAN_OK);
        CHECK(page.width == page_width && page.height == page_height);
        CHECK(page.spread == number && page.index == 0);
        /* A JPEG file starts with the marker FF D8 and ends with FF D9. */
        CHECK(page.jpeg_size > 100);
        CHECK(page.jpeg[0] == 0xFF && page.jpeg[1] == 0xD8);
        CHECK(page.jpeg[page.jpeg_size - 2] == 0xFF && page.jpeg[page.jpeg_size - 1] == 0xD9);
    }
    fastscan_page none;
    CHECK(fastscan_stream_page(stream, 2, &none) == FASTSCAN_INVALID_ARGUMENT);

    pdf_buffer pdf = {.bytes = malloc(PDF_CAPACITY), .size = 0};
    CHECK(pdf.bytes != NULL);
    CHECK(fastscan_stream_write_pdf(stream, collect, &pdf) == FASTSCAN_OK);
    CHECK(pdf.size > 1000);
    CHECK(memcmp(pdf.bytes, "%PDF-", 5) == 0);

    fastscan_worker_release_memory(worker);
    fastscan_worker_destroy(worker);
    fastscan_stream_destroy(stream);
    free(pdf.bytes);
    free(y);
    free(u);
    free(v);
    printf("c_api: 2 pages, %zu bytes of PDF, fastscan %s\n", pdf.size, fastscan_version());
    return 0;
}

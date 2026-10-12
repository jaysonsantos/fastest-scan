/* The JNI layer of the Android app: the native functions of the class
 * br.com.jayson.fastestscan.core.Native, on top of include/fastscan.h.
 *
 * This file has no logic of its own. It converts the arguments, checks the sizes of
 * the buffers, and calls the library. `zig build android` compiles it for Android,
 * and `zig build jni` compiles it for the Java machine of a desktop, for the test
 * in tests/jni/.
 */
#include <jni.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>

#include "fastscan.h"

#define NATIVE(name) Java_br_com_jayson_fastestscan_core_Native_##name

/* The same values as in Native.java. */
enum {
    STATUS_LENGTH = 24,
    STATUS_DETECTED = 0,
    STATUS_PAGE_COUNT = 1,
    STATUS_CORNERS = 2,
    STATUS_STEADY = 18,
    STATUS_CAPTURED = 19,
    STATUS_SPREADS = 20,
    STATUS_PAGES = 21,
    STATUS_JOBS_READY = 22,
    STATUS_HELD_FRAMES = 23,
    CORNER_VALUES = 8,
    PAGE_INFO_LENGTH = 5,
    /* The PDF goes to the Java stream in parts of this size. */
    WRITE_CHUNK_BYTES = 64 * 1024,
};

/* A stream with the frame size of its options: the size of each buffer of a frame
 * follows from it. */
typedef struct {
    fastscan_stream *stream;
    uint32_t width;
    uint32_t height;
} session;

static session *session_of(jlong handle) {
    return (session *)(intptr_t)handle;
}
static fastscan_worker *worker_of(jlong handle) {
    return (fastscan_worker *)(intptr_t)handle;
}
static fastscan_job *job_of(jlong handle) {
    return (fastscan_job *)(intptr_t)handle;
}

static void throw_new(JNIEnv *env, const char *class_name, const char *message) {
    jclass exception = (*env)->FindClass(env, class_name);
    if (exception != NULL) (*env)->ThrowNew(env, exception, message);
}

/* region: version and workers */

JNIEXPORT jstring JNICALL NATIVE(version)(JNIEnv *env, jclass clazz) {
    (void)clazz;
    return (*env)->NewStringUTF(env, fastscan_version());
}

JNIEXPORT jstring JNICALL NATIVE(resultMessage)(JNIEnv *env, jclass clazz, jint result) {
    (void)clazz;
    return (*env)->NewStringUTF(env, fastscan_result_message(result));
}

JNIEXPORT jlong JNICALL NATIVE(workerCreate)(JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;
    return (jlong)(intptr_t)fastscan_worker_create();
}

JNIEXPORT void JNICALL NATIVE(workerDestroy)(JNIEnv *env, jclass clazz, jlong worker) {
    (void)env;
    (void)clazz;
    fastscan_worker_destroy(worker_of(worker));
}

JNIEXPORT void JNICALL NATIVE(workerReleaseMemory)(JNIEnv *env, jclass clazz, jlong worker) {
    (void)env;
    (void)clazz;
    fastscan_worker_release_memory(worker_of(worker));
}

/* endregion: version and workers */

/* region: stream */

JNIEXPORT jlong JNICALL NATIVE(streamCreate)(JNIEnv *env, jclass clazz, jint width, jint height,
        jint rotation_degrees, jint color_range, jint color_matrix, jfloat frames_per_second,
        jint layout, jint donor_frames, jint max_held_frames, jint max_page_height,
        jint jpeg_quality, jint dpi, jint fingers) {
    (void)clazz;
    if (width <= 0 || height <= 0 || rotation_degrees < 0 || color_range < 0 || color_matrix < 0 ||
            layout < 0 || donor_frames < 0 || max_held_frames < 0 || max_page_height < 0 ||
            jpeg_quality < 0 || dpi < 0 || fingers < 0) {
        throw_new(
                env, "java/lang/IllegalArgumentException", "a value of the options is below zero");
        return 0;
    }
    fastscan_options options;
    fastscan_options_init(&options);
    options.width = (uint32_t)width;
    options.height = (uint32_t)height;
    options.rotation_degrees = (uint32_t)rotation_degrees;
    options.color_range = (uint32_t)color_range;
    options.color_matrix = (uint32_t)color_matrix;
    options.frames_per_second = frames_per_second;
    options.layout = (uint32_t)layout;
    options.donor_frames = (uint32_t)donor_frames;
    options.max_held_frames = (uint32_t)max_held_frames;
    options.max_page_height = (uint32_t)max_page_height;
    options.jpeg_quality = (uint32_t)jpeg_quality;
    options.dpi = (uint32_t)dpi;
    options.fingers = (uint32_t)fingers;

    session *created = malloc(sizeof(session));
    if (created == NULL) {
        throw_new(
                env, "java/lang/OutOfMemoryError", fastscan_result_message(FASTSCAN_OUT_OF_MEMORY));
        return 0;
    }
    created->width = options.width;
    created->height = options.height;
    const int result = fastscan_stream_create(&options, &created->stream);
    if (result != FASTSCAN_OK) {
        free(created);
        const char *exception = "java/lang/IllegalArgumentException";
        if (result == FASTSCAN_OUT_OF_MEMORY) exception = "java/lang/OutOfMemoryError";
        throw_new(env, exception, fastscan_result_message(result));
        return 0;
    }
    return (jlong)(intptr_t)created;
}

JNIEXPORT void JNICALL NATIVE(streamDestroy)(JNIEnv *env, jclass clazz, jlong stream) {
    (void)env;
    (void)clazz;
    session *target = session_of(stream);
    if (target == NULL) return;
    fastscan_stream_destroy(target->stream);
    free(target);
}

/* The address of a direct buffer, when the buffer has `needed` bytes or more. */
static const uint8_t *plane_of(JNIEnv *env, jobject buffer, uint64_t needed) {
    if (buffer == NULL) return NULL;
    const void *address = (*env)->GetDirectBufferAddress(env, buffer);
    const jlong capacity = (*env)->GetDirectBufferCapacity(env, buffer);
    if (address == NULL || capacity < 0 || (uint64_t)capacity < needed) return NULL;
    return address;
}

JNIEXPORT jint JNICALL NATIVE(streamPush)(JNIEnv *env, jclass clazz, jlong stream, jlong worker,
        jobject y, jobject u, jobject v, jint y_stride, jint chroma_stride, jint chroma_step,
        jdouble seconds, jfloatArray status) {
    (void)clazz;
    session *target = session_of(stream);
    if (target == NULL || worker == 0) return FASTSCAN_INVALID_ARGUMENT;
    if (y_stride <= 0 || chroma_stride <= 0 || chroma_step <= 0) return FASTSCAN_INVALID_FRAME;

    /* The bytes from the first sample of a plane to its last sample. The library
     * reads no byte after them. */
    const uint64_t chroma_width = ((uint64_t)target->width + 1) / 2;
    const uint64_t chroma_height = ((uint64_t)target->height + 1) / 2;
    const uint64_t luma_bytes = (uint64_t)y_stride * (target->height - 1) + target->width;
    const uint64_t chroma_bytes = (uint64_t)chroma_stride * (chroma_height - 1) +
            (uint64_t)chroma_step * (chroma_width - 1) + 1;

    fastscan_frame frame = {
            .y = plane_of(env, y, luma_bytes),
            .u = plane_of(env, u, chroma_bytes),
            .v = plane_of(env, v, chroma_bytes),
            .y_stride = (uint32_t)y_stride,
            .chroma_stride = (uint32_t)chroma_stride,
            .chroma_step = (uint32_t)chroma_step,
            .seconds = seconds,
    };
    if (frame.y == NULL || frame.u == NULL || frame.v == NULL) return FASTSCAN_INVALID_FRAME;

    fastscan_status result_status;
    const int result =
            fastscan_stream_push(target->stream, worker_of(worker), &frame, &result_status);
    if (result != FASTSCAN_OK || status == NULL) return result;
    if ((*env)->GetArrayLength(env, status) < STATUS_LENGTH) return FASTSCAN_INVALID_ARGUMENT;

    jfloat values[STATUS_LENGTH];
    values[STATUS_DETECTED] = (jfloat)result_status.detected;
    values[STATUS_PAGE_COUNT] = (jfloat)result_status.page_count;
    for (int page = 0; page < FASTSCAN_MAX_PAGES; page++) {
        for (int value = 0; value < CORNER_VALUES; value++) {
            values[STATUS_CORNERS + page * CORNER_VALUES + value] =
                    result_status.corners[page][value];
        }
    }
    values[STATUS_STEADY] = (jfloat)result_status.steady;
    values[STATUS_CAPTURED] = (jfloat)result_status.captured;
    values[STATUS_SPREADS] = (jfloat)result_status.spreads;
    values[STATUS_PAGES] = (jfloat)result_status.pages;
    values[STATUS_JOBS_READY] = (jfloat)result_status.jobs_ready;
    values[STATUS_HELD_FRAMES] = (jfloat)result_status.held_frames;
    (*env)->SetFloatArrayRegion(env, status, 0, STATUS_LENGTH, values);
    return result;
}

JNIEXPORT jint JNICALL NATIVE(streamFinish)(JNIEnv *env, jclass clazz, jlong stream, jlong worker) {
    (void)env;
    (void)clazz;
    session *target = session_of(stream);
    if (target == NULL || worker == 0) return FASTSCAN_INVALID_ARGUMENT;
    return fastscan_stream_finish(target->stream, worker_of(worker));
}

JNIEXPORT jlong JNICALL NATIVE(streamTakeJob)(JNIEnv *env, jclass clazz, jlong stream) {
    (void)env;
    (void)clazz;
    session *target = session_of(stream);
    if (target == NULL) return 0;
    return (jlong)(intptr_t)fastscan_stream_take_job(target->stream);
}

JNIEXPORT jint JNICALL NATIVE(jobRun)(JNIEnv *env, jclass clazz, jlong job, jlong worker) {
    (void)env;
    (void)clazz;
    if (job == 0 || worker == 0) return FASTSCAN_INVALID_ARGUMENT;
    return fastscan_job_run(job_of(job), worker_of(worker));
}

JNIEXPORT void JNICALL NATIVE(streamCompleteJob)(
        JNIEnv *env, jclass clazz, jlong stream, jlong job, jint run_result) {
    (void)env;
    (void)clazz;
    session *target = session_of(stream);
    if (target == NULL || job == 0) return;
    fastscan_stream_complete_job(target->stream, job_of(job), run_result);
}

JNIEXPORT jboolean JNICALL NATIVE(streamBusy)(JNIEnv *env, jclass clazz, jlong stream) {
    (void)env;
    (void)clazz;
    session *target = session_of(stream);
    if (target == NULL) return JNI_FALSE;
    return fastscan_stream_busy(target->stream) ? JNI_TRUE : JNI_FALSE;
}

/* endregion: stream */

/* region: pages */

JNIEXPORT jint JNICALL NATIVE(streamPageCount)(JNIEnv *env, jclass clazz, jlong stream) {
    (void)env;
    (void)clazz;
    session *target = session_of(stream);
    if (target == NULL) return 0;
    return (jint)fastscan_stream_page_count(target->stream);
}

JNIEXPORT jbyteArray JNICALL NATIVE(streamPageJpeg)(
        JNIEnv *env, jclass clazz, jlong stream, jint index) {
    (void)clazz;
    session *target = session_of(stream);
    fastscan_page page;
    if (target == NULL || index < 0) return NULL;
    if (fastscan_stream_page(target->stream, (uint32_t)index, &page) != FASTSCAN_OK) return NULL;
    if (page.jpeg_size > INT32_MAX) return NULL;
    jbyteArray bytes = (*env)->NewByteArray(env, (jsize)page.jpeg_size);
    if (bytes == NULL) return NULL;
    (*env)->SetByteArrayRegion(env, bytes, 0, (jsize)page.jpeg_size, (const jbyte *)page.jpeg);
    return bytes;
}

JNIEXPORT jint JNICALL NATIVE(streamPageInfo)(
        JNIEnv *env, jclass clazz, jlong stream, jint index, jintArray info) {
    (void)clazz;
    session *target = session_of(stream);
    if (target == NULL || index < 0 || info == NULL) return FASTSCAN_INVALID_ARGUMENT;
    if ((*env)->GetArrayLength(env, info) < PAGE_INFO_LENGTH) return FASTSCAN_INVALID_ARGUMENT;
    fastscan_page page;
    const int result = fastscan_stream_page(target->stream, (uint32_t)index, &page);
    if (result != FASTSCAN_OK) return result;
    const jint values[PAGE_INFO_LENGTH] = {
            (jint)page.width,
            (jint)page.height,
            (jint)page.gray,
            (jint)page.spread,
            (jint)page.index,
    };
    (*env)->SetIntArrayRegion(env, info, 0, PAGE_INFO_LENGTH, values);
    return FASTSCAN_OK;
}

/* Where the bytes of the PDF go: the method write(byte[], int, int) of a Java stream. */
typedef struct {
    JNIEnv *env;
    jobject output;
    jmethodID write;
    jbyteArray chunk;
} java_sink;

static int write_to_java(void *context, const uint8_t *bytes, size_t size) {
    java_sink *sink = context;
    JNIEnv *env = sink->env;
    while (size > 0) {
        const jsize part = size > WRITE_CHUNK_BYTES ? WRITE_CHUNK_BYTES : (jsize)size;
        (*env)->SetByteArrayRegion(env, sink->chunk, 0, part, (const jbyte *)bytes);
        (*env)->CallVoidMethod(env, sink->output, sink->write, sink->chunk, 0, part);
        /* The exception of the Java stream stays: the caller of the native function gets it. */
        if ((*env)->ExceptionCheck(env)) return 1;
        bytes += part;
        size -= (size_t)part;
    }
    return 0;
}

JNIEXPORT jint JNICALL NATIVE(streamWritePdf)(
        JNIEnv *env, jclass clazz, jlong stream, jobject output) {
    (void)clazz;
    session *target = session_of(stream);
    if (target == NULL || output == NULL) return FASTSCAN_INVALID_ARGUMENT;
    jclass output_class = (*env)->GetObjectClass(env, output);
    java_sink sink = {
            .env = env,
            .output = output,
            .write = (*env)->GetMethodID(env, output_class, "write", "([BII)V"),
            .chunk = (*env)->NewByteArray(env, WRITE_CHUNK_BYTES),
    };
    if (sink.write == NULL || sink.chunk == NULL) return FASTSCAN_OUT_OF_MEMORY;
    return fastscan_stream_write_pdf(target->stream, write_to_java, &sink);
}

/* endregion: pages */

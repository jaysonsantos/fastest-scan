/* fastscan: turn frames of a filmed book or document into a PDF.
 *
 * The C interface of the library in src/lib/. It is the base for a JNI layer or a
 * binding in another language.
 */
#ifndef FASTSCAN_H
#define FASTSCAN_H

#ifdef __cplusplus
extern "C" {
#endif

/* The version of the library. The string lives as long as the program. */
const char *fastscan_version(void);

#ifdef __cplusplus
}
#endif

#endif /* FASTSCAN_H */

package br.com.jayson.fastestscan.core

import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale

/**
 * The file name of the PDF of a scan: `<prefix> <name>.pdf`. A scan that starts at
 * 2026-10-15 21:30 gives `2026-10-15 21-30 Scan.pdf`.
 *
 * - The prefix is the local date and time of the start of the scan. It has ASCII
 *   digits in each locale. A setting of the user turns it off.
 * - The name comes from the user. The rule removes `/ \ : * ? " < > |`, the control
 *   characters, and the spaces at the two ends. An empty name becomes the default
 *   name.
 * - The part before `.pdf` has at most [MAX_CHARACTERS] characters, and at most
 *   [MAX_BYTES] bytes in UTF-8: the file system takes a name of 255 bytes at most.
 *
 * The rule uses no class of Android: a unit test on the Java machine checks it.
 */
object PdfName {
    /** The characters that a file name cannot have: `/` on each system, and the others on Windows. */
    private const val FORBIDDEN_CHARACTERS = "/\\:*?\"<>|"

    /** The local date and time of the prefix. `:` is not allowed in a file name. */
    private const val PREFIX_PATTERN = "yyyy-MM-dd HH-mm"
    private const val PREFIX_SEPARATOR = " "
    private const val EXTENSION = ".pdf"

    /** The largest number of characters (Unicode code points) before [EXTENSION]. */
    const val MAX_CHARACTERS = 100

    /** The largest file name of ext4 and F2FS, the file systems of Android. */
    private const val MAX_FILE_NAME_BYTES = 255

    /** The largest number of bytes before [EXTENSION], in UTF-8. */
    const val MAX_BYTES = MAX_FILE_NAME_BYTES - EXTENSION.length

    // Locale.ROOT and the standard decimal style of `ofPattern`: ASCII digits, also
    // when the default locale has other digits, for example Arabic.
    private val prefixFormat: DateTimeFormatter = DateTimeFormatter.ofPattern(PREFIX_PATTERN, Locale.ROOT)

    /**
     * The file name for a scan that started at [start], in the time zone of [start].
     * [name] is the text of the user, and [defaultName] replaces a name that is empty
     * after the clean-up.
     */
    fun fileName(start: ZonedDateTime, name: String, withPrefix: Boolean, defaultName: String): String {
        val cleanName = clean(name).ifEmpty { defaultName }
        val base = if (withPrefix) prefixFormat.format(start) + PREFIX_SEPARATOR + cleanName else cleanName
        // A cut can end after a space.
        return shorten(base).trimEnd() + EXTENSION
    }

    private fun clean(name: String): String =
        name.filterNot { character -> character in FORBIDDEN_CHARACTERS || character.isISOControl() }.trim()

    /** The start of [text] with at most [MAX_CHARACTERS] code points and [MAX_BYTES] bytes. A cut never splits a code point. */
    private fun shorten(text: String): String {
        var end = 0
        var characters = 0
        var bytes = 0
        while (end < text.length && characters < MAX_CHARACTERS) {
            val next = text.offsetByCodePoints(end, 1)
            val size = text.substring(end, next).toByteArray(Charsets.UTF_8).size
            if (bytes + size > MAX_BYTES) break
            bytes += size
            characters++
            end = next
        }
        return text.substring(0, end)
    }
}

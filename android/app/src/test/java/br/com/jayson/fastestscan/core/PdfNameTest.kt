package br.com.jayson.fastestscan.core

import java.time.LocalDateTime
import java.time.ZoneId
import java.time.ZonedDateTime
import java.util.Locale
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** The rule for the file name of the PDF. These tests run on the Java machine of the computer: `gradle testDebugUnitTest`. */
class PdfNameTest {
    @Test
    fun theStartTimeIsThePrefix() {
        assertEquals("2026-10-15 21-30 Scan.pdf", fileName(START, DEFAULT_NAME))
    }

    @Test
    fun thePrefixHasTheTimeOfTheZoneOfTheStart() {
        val instant = START.toInstant()
        assertEquals("2026-10-15 16-30 Scan.pdf", fileName(instant.atZone(ZoneId.of("America/Sao_Paulo")), DEFAULT_NAME))
        // The same moment is on the next day in Tokyo.
        assertEquals("2026-10-16 04-30 Scan.pdf", fileName(instant.atZone(ZoneId.of("Asia/Tokyo")), DEFAULT_NAME))
    }

    @Test
    fun theRuleRemovesTheInvalidCharacters() {
        assertEquals("2026-10-15 21-30 abcdefghij.pdf", fileName(START, "a/b\\c:d*e?f\"g<h>i|j"))
        assertEquals("2026-10-15 21-30 ab.pdf", fileName(START, "a\u0000\t\n\r\u001f\u007f\u0085b"))
        // The spaces at the two ends go, and the spaces in the name stay.
        assertEquals("2026-10-15 21-30 My book.pdf", fileName(START, "  My book \t "))
    }

    @Test
    fun anEmptyNameBecomesTheDefaultName() {
        assertEquals("2026-10-15 21-30 Scan.pdf", fileName(START, ""))
        assertEquals("2026-10-15 21-30 Scan.pdf", fileName(START, "   "))
        assertEquals("2026-10-15 21-30 Scan.pdf", fileName(START, " /:*?<>| "))
        assertEquals("Scan.pdf", fileName(START, "", withPrefix = false))
    }

    @Test
    fun aLongNameKeepsOneHundredCharacters() {
        val longName = "x".repeat(LONG_NAME_LENGTH)
        val withPrefix = fileName(START, longName)
        assertEquals(PdfName.MAX_CHARACTERS, withPrefix.removeSuffix(EXTENSION).length)
        assertTrue(withPrefix.startsWith("2026-10-15 21-30 xxx"))
        assertTrue(withPrefix.endsWith("x$EXTENSION"))

        val noPrefix = fileName(START, longName, withPrefix = false)
        assertEquals("x".repeat(PdfName.MAX_CHARACTERS) + EXTENSION, noPrefix)
    }

    @Test
    fun aCutDoesNotEndWithASpace() {
        // The prefix and its space take 17 characters: the cut comes after the space.
        val name = "a".repeat(PdfName.MAX_CHARACTERS - PREFIX_LENGTH - 1) + " b"
        val result = fileName(START, name).removeSuffix(EXTENSION)
        assertEquals(PdfName.MAX_CHARACTERS - 1, result.length)
        assertTrue(result.endsWith("a"))
    }

    @Test
    fun aLongNameOfWideCharactersKeepsTheByteLimit() {
        // Each of these characters takes 3 bytes in UTF-8: 100 of them are 300 bytes.
        val base = fileName(START, "書".repeat(LONG_NAME_LENGTH), withPrefix = false).removeSuffix(EXTENSION)
        assertTrue(base.toByteArray(Charsets.UTF_8).size <= PdfName.MAX_BYTES)
        assertEquals(PdfName.MAX_BYTES / WIDE_CHARACTER_BYTES, base.length)
    }

    @Test
    fun aCutDoesNotSplitACharacter() {
        // Each emoji is two UTF-16 units: a cut between the two gives a broken name.
        val base = fileName(START, "📖".repeat(LONG_NAME_LENGTH), withPrefix = false).removeSuffix(EXTENSION)
        assertFalse(base.last().isHighSurrogate())
        assertEquals(base.length / EMOJI_UTF16_UNITS, base.codePointCount(0, base.length))
    }

    @Test
    fun withNoPrefixTheNameIsAlone() {
        assertEquals("Scan.pdf", fileName(START, DEFAULT_NAME, withPrefix = false))
        assertEquals("My book.pdf", fileName(START, "My book", withPrefix = false))
    }

    @Test
    fun theDigitsAreAsciiInAnArabicLocale() {
        val before = Locale.getDefault()
        try {
            // The default digits of Arabic are not ASCII: String.format gives "٢٠٢٦" for 2026.
            Locale.setDefault(Locale.forLanguageTag("ar"))
            assertEquals("2026-10-15 21-30 Scan.pdf", fileName(START, DEFAULT_NAME))
        } finally {
            Locale.setDefault(before)
        }
    }

    private fun fileName(start: ZonedDateTime, name: String, withPrefix: Boolean = true): String =
        PdfName.fileName(start, name, withPrefix, DEFAULT_NAME)

    private companion object {
        const val DEFAULT_NAME = "Scan"
        const val EXTENSION = ".pdf"
        const val LONG_NAME_LENGTH = 300

        /** `2026-10-15 21-30 `. */
        const val PREFIX_LENGTH = 17
        const val WIDE_CHARACTER_BYTES = 3
        const val EMOJI_UTF16_UNITS = 2

        /** 2026-10-15 21:30 in Berlin: 19:30 in UTC. */
        val START: ZonedDateTime = LocalDateTime.of(2026, 10, 15, 21, 30).atZone(ZoneId.of("Europe/Berlin"))
    }
}

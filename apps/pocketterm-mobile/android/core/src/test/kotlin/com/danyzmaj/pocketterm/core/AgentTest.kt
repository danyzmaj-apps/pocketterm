package com.danyzmaj.pocketterm.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class AgentTest {
    @Test
    fun `an omp command line's profile, whichever way it's written, none for a name omp wouldn't take`() {
        assertEquals("personal", ompProfileOfArgs("omp --profile=personal"))
        assertEquals("work", ompProfileOfArgs("/opt/homebrew/bin/omp --profile work -c"))
        assertEquals("", ompProfileOfArgs("omp --profile=Work"))
        assertEquals("", ompProfileOfArgs("omp --profile"))
        assertEquals("", ompProfileOfArgs("omp --resume /x.jsonl"))
        assertEquals("", ompProfileOfArgs("omp"))
        assertEquals("personal", ompProfileOfArgs("omp --profile=work --profile personal"), "the last one, as omp")
        assertEquals("work", ompProfileOfArgs("omp --profile=work -- --profile x"), "nothing after --")
        assertEquals("", ompProfileOfArgs("omp --profile=default"))
    }

    @Test
    fun `profile names as omp takes them`() {
        assertTrue(isOmpProfile("personal"))
        assertTrue(isOmpProfile("a.b_c-1"))
        assertFalse(isOmpProfile("a."))
        assertFalse(isOmpProfile(".a"))
        assertFalse(isOmpProfile(""))
        assertFalse(isOmpProfile("a; rm -rf ~"))
        assertFalse(isOmpProfile("a".repeat(65)))
    }

    @Test
    fun `only omp runs in a profile, and the default one reads as before`() {
        assertEquals("omp --profile=personal", Agent.omp.commandIn("personal"))
        assertEquals("omp", Agent.omp.commandIn(""))
        assertEquals("claude", Agent.claude.commandIn("personal"))
        assertEquals("omp · personal", Agent.omp.labelIn("personal"))
        assertEquals("omp", Agent.omp.labelIn(""))
        assertEquals("Claude", Agent.claude.labelIn("personal"))
        // As typed once the no-break characters are gone.
        fun typed(s: String) = s.replace("\u00A0", " ").replace("\u2060", "")
        assertEquals("omp --profile=personal -c", typed(Agent.omp.resumeIn("personal")))
        assertEquals(Agent.omp.resume, Agent.omp.resumeIn(""))
        assertEquals("/reload-plugins", Agent.claude.pickUpIn("personal"))
    }
}

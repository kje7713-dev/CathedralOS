package com.cathedral.epubcheck;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

/**
 * Unit tests for EpubcheckService.parseOutput — the function that turns
 * raw EPUBCheck stdout/stderr/exitCode into a ValidationResult.
 *
 * Tests cover the 7 cases required by the PR-4100-G scope:
 *   - exit 0 + no diagnostics                -> valid true
 *   - exit 1 + warning                      -> valid true
 *   - exit 2 + error                        -> valid false
 *   - exit 3 + fatal                        -> valid false
 *   - exit >=2 + unparseable output         -> valid false + diagnostic/log evidence preserved
 *   - diagnostics containing error/fatal    -> force false (even when exitCode == 0)
 *   - warning-only diagnostics              -> do not force false
 *
 * ProcessResult and parseOutput are package-private to allow direct testing
 * without spinning up EPUBCheck. Production code path still invokes EPUBCheck
 * via runEpubcheck(); these tests only validate the parse step in isolation.
 */
class EpubcheckServiceTest {

    private final EpubcheckService service = new EpubcheckService();

    /** Helper to build a ProcessResult without touching EPUBCheck. */
    private EpubcheckService.ProcessResult proc(int exitCode, String stdout, String stderr) {
        EpubcheckService.ProcessResult p = new EpubcheckService.ProcessResult();
        p.exitCode = exitCode;
        p.stdout = stdout;
        p.stderr = stderr;
        return p;
    }

    @Test
    void exit0_noDiagnostics_validTrue() {
        ValidationResult r = service.parseOutput(proc(0, "No errors or warnings detected.", ""));
        assertTrue(r.valid, "exit 0 with no diagnostics must be valid");
        assertEquals(0, r.error_count);
        assertEquals(0, r.warning_count);
        assertTrue(r.diagnostics.isEmpty(), "no synthetic diagnostic should be emitted for clean exit");
    }

    @Test
    void exit1_warningOnly_validTrue() {
        String out = "WARNING(RSC-005): Some minor warning (OEBPS/content.opf:10:5)\n";
        ValidationResult r = service.parseOutput(proc(1, out, ""));
        assertTrue(r.valid, "exit 1 with warnings-only must be valid");
        assertEquals(0, r.error_count);
        assertEquals(1, r.warning_count);
        assertEquals(1, r.diagnostics.size());
        assertEquals("warning", r.diagnostics.get(0).severity);
    }

    @Test
    void exit2_error_validFalse() {
        String out = "ERROR(OPF-001): Invalid spine item (OEBPS/content.opf:42:13)\n";
        ValidationResult r = service.parseOutput(proc(2, out, ""));
        assertFalse(r.valid, "exit 2 must be invalid");
        assertEquals(1, r.error_count);
        assertEquals(1, r.diagnostics.size());
        assertEquals("error", r.diagnostics.get(0).severity);
        assertEquals("OPF-001", r.diagnostics.get(0).code);
    }

    @Test
    void exit3_fatal_validFalse() {
        String out = "FATAL(OPF-001): Catastrophic OPF failure (OEBPS/content.opf:1:1)\n";
        ValidationResult r = service.parseOutput(proc(3, out, ""));
        assertFalse(r.valid, "exit 3 must be invalid");
        assertEquals(1, r.error_count);
        assertEquals(1, r.diagnostics.size());
        assertEquals("fatal", r.diagnostics.get(0).severity);
    }

    @Test
    void exit2_unparseableOutput_validFalseAndEvidencePreserved() {
        // EPUBCheck exit 2 but stdout/stderr don't match the text regex at all.
        // Valid must still be false, AND a synthetic diagnostic must be emitted
        // so the failure is diagnosable instead of valid=false with [] forever
        // (this is the 2026-08-26 06:01 EDT smoke symptom).
        ValidationResult r = service.parseOutput(
            proc(2, "", "Some completely unparseable stderr message"));
        assertFalse(r.valid, "exit 2 must be invalid even without parsed diagnostics");
        assertFalse(r.diagnostics.isEmpty(),
            "must emit a synthetic diagnostic when parser found nothing but EPUBCheck said invalid");
        assertEquals(1, r.diagnostics.size());
        assertEquals("PARSE-000", r.diagnostics.get(0).code);
        assertEquals("error", r.diagnostics.get(0).severity);
        assertEquals(1, r.error_count, "synthetic diagnostic must count toward error_count");
        assertTrue(r.diagnostics.get(0).message.contains("exit 2"),
            "synthetic diagnostic must include the EPUBCheck exit code");
    }

    @Test
    void exit0_withErrorDiagnostic_validFalse() {
        // EPUBCheck exited 0 but stderr had a late-arriving ERROR line
        // (e.g. during cleanup). Valid must be forced false by the
        // diagnostic, not the exit code.
        String err = "ERROR(RSC-005): detected during cleanup (file.xhtml:5:1)\n";
        ValidationResult r = service.parseOutput(proc(0, "", err));
        assertFalse(r.valid, "error diagnostic must force valid=false even when exitCode==0");
        assertEquals(1, r.error_count);
        assertEquals(1, r.diagnostics.size());
    }

    @Test
    void exit0_withFatalDiagnostic_validFalse() {
        String err = "FATAL(OPF-001): catastrophic (file.xhtml:1:1)\n";
        ValidationResult r = service.parseOutput(proc(0, "", err));
        assertFalse(r.valid, "fatal diagnostic must force valid=false even when exitCode==0");
        assertEquals(1, r.error_count);
    }

    @Test
    void exit1_warningOnly_doesNotForceFalse() {
        // Exit 1 with ONLY warnings — valid stays true (warnings do not
        // block per the EPUBCheck exit-code contract: 1 = warnings only).
        String out = "WARNING(ACC-001): accessibility note (file.xhtml:1:1)\n";
        ValidationResult r = service.parseOutput(proc(1, out, ""));
        assertTrue(r.valid, "warning-only diagnostics must not force valid=false");
        assertEquals(0, r.error_count);
        assertEquals(1, r.warning_count);
    }
}

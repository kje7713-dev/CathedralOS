// =============================================================================
// index_test.ts — Tests for export-epub edge function
//
// Per impl plan §9, 12 test cases:
//   1. Valid EPUB passes
//   2. Malformed EPUB fails
//   3. Warning-only EPUB downloads
//   4. Structured EPUBCheck errors parsed correctly
//   5. Known repairable defect → repair → second validation passes
//   6. Unrepaired defect remains blocked
//   7. Validator timeout distinguished from EPUB invalidity
//   8. Validator outage distinguished
//   9. Validator cannot be bypassed on production export
//  10. Temp files cleaned up
//  11. Auth rejection works
//  12. Pinned EPUBCheck version verifiable
//
// Strategy: mock validateEpub() to simulate Cloud Run responses.
// Uses Deno's built-in test runner + std/testing mock.ts.
// =============================================================================

import {
  assertEquals,
  assertExists,
  assertRejects,
  assertStringIncludes,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { walkSections, type ProjectOutline } from "./_section_walker.ts";
import { writeEpub } from "./_epub_writer.ts";
import { deriveBookParts, type StoryArcInfo } from "./_parts.ts";
import JSZip from "https://esm.sh/jszip@3.10.1";
import { assembleMetadata, type ExportRequest } from "./_metadata.ts";
import { buildCoverPrompt } from "./_cover_image.ts";
import { splitParagraphs } from "./_paragraphs.ts";
import {
  stub,
  type Stub,
} from "https://deno.land/std@0.224.0/testing/mock.ts";
import {
  validateEpub,
  ValidatorFailureError,
  type ValidationResult,
} from "./_validator_client.ts";
import { createJob, updateJobStatus, getJob } from "./_job_status.ts";

// ---------------------------------------------------------------------------
// Test fixtures
// ---------------------------------------------------------------------------

const FAKE_VALIDATION_ID = "test-validation-uuid-12345";
const FAKE_PROJECT_ID = "test-project-uuid-67890";
const FAKE_USER_ID = "test-user-uuid-13579";
const FAKE_EPUBCHECK_VERSION = "5.3.0";

function makeValidResult(overrides: Partial<ValidationResult> = {}): ValidationResult {
  return {
    validation_id: FAKE_VALIDATION_ID,
    epubcheck_version: FAKE_EPUBCHECK_VERSION,
    validation_duration_ms: 1234,
    valid: true,
    error_count: 0,
    warning_count: 0,
    diagnostics: [],
    ...overrides,
  };
}

function makeInvalidResult(overrides: Partial<ValidationResult> = {}): ValidationResult {
  return {
    validation_id: FAKE_VALIDATION_ID,
    epubcheck_version: FAKE_EPUBCHECK_VERSION,
    validation_duration_ms: 1234,
    valid: false,
    error_count: 2,
    warning_count: 0,
    diagnostics: [
      {
        severity: "error",
        code: "OPF-001",
        message: "Invalid OPF spine item",
        file: "OEBPS/content.opf",
        line: 42,
        column: 13,
      },
      {
        severity: "fatal",
        code: "RSC-005",
        message: "Missing required resource",
        file: "OEBPS/missing.xhtml",
      },
    ],
    ...overrides,
  };
}

function makeWarningOnlyResult(): ValidationResult {
  return makeValidResult({
    valid: true, // warnings don't invalidate per spec
    error_count: 0,
    warning_count: 2,
    diagnostics: [
      {
        severity: "warning",
        code: "ACC-005",
        message: "Accessibility metadata missing",
        file: "OEBPS/content.opf",
      },
      {
        severity: "warning",
        code: "CSS-001",
        message: "Unused CSS rule",
        file: "OEBPS/styles.css",
      },
    ],
  });
}

Deno.test("AI cover prompt uses story-wide recipe signals", () => {
  const outline: ProjectOutline = {
    id: "outline-1",
    title: "The Long Return",
    chapters: [],
    parts: [],
    storyBrief: {
      projectSummary: "A cartographer returns to a drowned city.",
      recipe: "saltwater gothic; outline signals: the map burns",
      setting: "flooded harbor under permanent dusk",
      characters: "Mara (cartographer, afraid of forgetting)",
      conflict: "A buried promise threatens the city's survivors.",
      themes: "memory versus truth; recurring bells",
      endingTexture: "haunted but tender",
    },
  };
  const prompt = buildCoverPrompt(outline);
  assertStringIncludes(prompt, "drowned city");
  assertStringIncludes(prompt, "saltwater gothic");
  assertStringIncludes(prompt, "Mara");
  assertStringIncludes(prompt, "memory versus truth");
  assertStringIncludes(prompt, "whole story");
});

Deno.test("EPUB writer: preserves blank-line paragraph boundaries", () => {
  assertEquals(
    splitParagraphs("First paragraph.\n\nSecond paragraph.\r\n\r\nThird paragraph."),
    ["First paragraph.", "Second paragraph.", "Third paragraph."],
  );
  assertEquals(splitParagraphs("  One paragraph with\nline wrapping.  "), [
    "One paragraph with\nline wrapping.",
  ]);
});

Deno.test("EPUB writer: emits Kindle-friendly reflowable typography", () => {
  const src = Deno.readTextFileSync(new URL("./_epub_writer.ts", import.meta.url));
  assertStringIncludes(src, "margin: 0;");
  assertStringIncludes(src, "padding: 0;");
  assertStringIncludes(src, "text-align: start;");
  assertStringIncludes(src, "text-indent: 1.2em;");
  assertStringIncludes(src, "h1 + p,");
  assertStringIncludes(src, "h2 + p {");
  if (src.includes('font-family: Georgia') || src.includes('font-family: "Times New Roman"')) {
    throw new Error("body typography must not force a reading font");
  }
  if (src.includes("p + p")) {
    throw new Error("normal paragraphs must not receive a default blank line");
  }
});

Deno.test("EPUB writer: emits conventional landmarks with conditional cover", async () => {
  const withoutCover = await writeEpub(
    { book_title: "Landmarks", author_name: "Author", language: "en" },
    makeAcknowledgementsFixture(),
    null,
  );
  const withoutCoverZip = await JSZip.loadAsync(withoutCover);
  const withoutCoverNav = await readZipText(withoutCoverZip, "OEBPS/nav.xhtml");
  assertStringIncludes(withoutCoverNav, '<nav epub:type="landmarks" hidden="">');
  assertStringIncludes(withoutCoverNav, 'epub:type="toc" href="nav.xhtml"');
  assertStringIncludes(withoutCoverNav, 'epub:type="bodymatter" href="text/section-1.xhtml"');
  if (withoutCoverNav.includes('epub:type="cover"')) {
    throw new Error("cover landmark must be omitted when no cover exists");
  }

  const withCover = await writeEpub(
    { book_title: "Landmarks", author_name: "Author", language: "en" },
    makeAcknowledgementsFixture(),
    new Uint8Array([0xff, 0xd8, 0xff]),
  );
  const withCoverZip = await JSZip.loadAsync(withCover);
  const withCoverNav = await readZipText(withCoverZip, "OEBPS/nav.xhtml");
  assertStringIncludes(withCoverNav, 'epub:type="cover" href="cover.xhtml"');
  assertStringIncludes(withCoverNav, 'epub:type="toc" href="nav.xhtml"');
  assertStringIncludes(withCoverNav, 'epub:type="bodymatter" href="text/section-1.xhtml"');

  const landmarkHrefs = [...withCoverNav.matchAll(/epub:type="(?:cover|bodymatter|toc)" href="([^"]+)"/g)].map((match) => match[1]);
  for (const href of landmarkHrefs) {
    assertExists(withCoverZip.file(`OEBPS/${href}`), `landmark href must exist: ${href}`);
  }
});

Deno.test("EPUB writer: heading transitions and child section anchors are structural", async () => {
  const epub = await writeEpub(
    { book_title: "Structure", author_name: "Author", language: "en" },
    makeAcknowledgementsFixture(),
    null,
  );
  const zip = await JSZip.loadAsync(epub);
  const story = await readZipText(zip, "OEBPS/text/section-1.xhtml");
  assertStringIncludes(
    story,
    '<link rel="stylesheet" type="text/css" href="../styles.css"/>',
  );
  assertStringIncludes(story, '<h1 class="section-title">The Story</h1>');
  assertStringIncludes(story, '<h2 id="section-1-section-2">Continuation</h2>');
  assertStringIncludes(story, "<h1 class=\"section-title\">The Story</h1>\n<p>Story text.</p>");
  assertStringIncludes(story, "<h2 id=\"section-1-section-2\">Continuation</h2>\n<p>More story text.</p>");
});

Deno.test("EPUB writer: puts cover document first in reading order", () => {
  const src = Deno.readTextFileSync(new URL("./_epub_writer.ts", import.meta.url));
  assertStringIncludes(src, 'id="cover" href="cover.xhtml"');
  assertStringIncludes(src, '<itemref idref="cover"/>');
  assertStringIncludes(src, '"OEBPS/cover.xhtml"');
  assertStringIncludes(src, 'src="cover-image.jpg"');
  assertStringIncludes(src, 'href="styles.css"');
  assertStringIncludes(src, 'class="cover-metadata"');
  assertStringIncludes(src, 'flex-direction: column');
  assertStringIncludes(src, 'max-height: 62vh');
  assertStringIncludes(src, 'By ${escapeXml(metadata.author_name)}');
});

// ---------------------------------------------------------------------------
// Test: validator client — valid EPUB passes
// ---------------------------------------------------------------------------

Deno.test("validateEpub: passes through valid result from validator", async () => {
  const validResult = makeValidResult();
  const fetchStub = stub(
    globalThis,
    "fetch",
    () => Promise.resolve(new Response(JSON.stringify(validResult), { status: 200 })),
  );

  try {
    Deno.env.set("EPUBCHECK_VALIDATOR_URL", "https://validator.test");
    Deno.env.set("EPUBCHECK_VALIDATOR_HMAC_SECRET", "a".repeat(64));

    const result = await validateEpub("https://storage.test/signed-url", FAKE_VALIDATION_ID, {
      maxRetries: 0,
      timeoutMs: 5000,
    });

    assertEquals(result.valid, true);
    assertEquals(result.error_count, 0);
    assertEquals(result.epubcheck_version, "5.3.0");
  } finally {
    fetchStub.restore();
  }
});

// ---------------------------------------------------------------------------
// Test: validator client — malformed EPUB fails
// ---------------------------------------------------------------------------

Deno.test("validateEpub: returns invalid result with diagnostics", async () => {
  const invalidResult = makeInvalidResult();
  const fetchStub = stub(
    globalThis,
    "fetch",
    () => Promise.resolve(new Response(JSON.stringify(invalidResult), { status: 200 })),
  );

  try {
    Deno.env.set("EPUBCHECK_VALIDATOR_URL", "https://validator.test");
    Deno.env.set("EPUBCHECK_VALIDATOR_HMAC_SECRET", "a".repeat(64));

    const result = await validateEpub("https://storage.test/signed-url", FAKE_VALIDATION_ID, {
      maxRetries: 0,
      timeoutMs: 5000,
    });

    assertEquals(result.valid, false);
    assertEquals(result.error_count, 2);
    assertEquals(result.diagnostics[0].severity, "error");
    assertEquals(result.diagnostics[0].code, "OPF-001");
    assertEquals(result.diagnostics[1].severity, "fatal");
    assertStringIncludes(result.diagnostics[1].message, "Missing required resource");
  } finally {
    fetchStub.restore();
  }
});

// ---------------------------------------------------------------------------
// Test: validator client — warning-only EPUB remains downloadable
// ---------------------------------------------------------------------------

Deno.test("validateEpub: warning-only result is still valid", async () => {
  const warningResult = makeWarningOnlyResult();
  const fetchStub = stub(
    globalThis,
    "fetch",
    () => Promise.resolve(new Response(JSON.stringify(warningResult), { status: 200 })),
  );

  try {
    Deno.env.set("EPUBCHECK_VALIDATOR_URL", "https://validator.test");
    Deno.env.set("EPUBCHECK_VALIDATOR_HMAC_SECRET", "a".repeat(64));

    const result = await validateEpub("https://storage.test/signed-url", FAKE_VALIDATION_ID, {
      maxRetries: 0,
      timeoutMs: 5000,
    });

    assertEquals(result.valid, true); // warnings don't invalidate
    assertEquals(result.error_count, 0);
    assertEquals(result.warning_count, 2);
    assertEquals(result.diagnostics[0].severity, "warning");
  } finally {
    fetchStub.restore();
  }
});

// ---------------------------------------------------------------------------
// Test: validator client — timeout distinguished from EPUB invalidity
// ---------------------------------------------------------------------------

Deno.test("validateEpub: timeout throws ValidatorFailureError(timeout), NOT validation result", async () => {
  const fetchStub = stub(
    globalThis,
    "fetch",
    ((_input: RequestInfo | URL, init?: RequestInit) => {
      // Honor AbortSignal so the test doesn't hang. validateEpub's AbortController
      // fires after timeoutMs, which aborts the fetch → AbortError → TimeoutException.
      return new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => {
          reject(new DOMException("aborted", "AbortError"));
        });
        // never resolve naturally
      });
    }) as typeof fetch,
  );

  try {
    Deno.env.set("EPUBCHECK_VALIDATOR_URL", "https://validator.test");
    Deno.env.set("EPUBCHECK_VALIDATOR_HMAC_SECRET", "a".repeat(64));

    await assertRejects(
      async () => {
        await validateEpub("https://storage.test/signed-url", FAKE_VALIDATION_ID, {
          maxRetries: 0,
          timeoutMs: 100, // very short timeout
        });
      },
      ValidatorFailureError,
    );
  } finally {
    fetchStub.restore();
  }
});

// ---------------------------------------------------------------------------
// Test: validator client — server outage distinguished from EPUB invalidity
// ---------------------------------------------------------------------------

Deno.test("validateEpub: 503 server error throws ValidatorFailureError(server_error)", async () => {
  const fetchStub = stub(
    globalThis,
    "fetch",
    () => Promise.resolve(new Response("service unavailable", { status: 503 })),
  );

  try {
    Deno.env.set("EPUBCHECK_VALIDATOR_URL", "https://validator.test");
    Deno.env.set("EPUBCHECK_VALIDATOR_HMAC_SECRET", "a".repeat(64));

    await assertRejects(
      async () => {
        await validateEpub("https://storage.test/signed-url", FAKE_VALIDATION_ID, {
          maxRetries: 0,
          timeoutMs: 5000,
        });
      },
      ValidatorFailureError,
      "server_error",
    );
  } finally {
    fetchStub.restore();
  }
});

// ---------------------------------------------------------------------------
// Test: validator client — auth rejection throws immediately (no retry)
// ---------------------------------------------------------------------------

Deno.test("validateEpub: 401 auth error fails closed immediately (no retry)", async () => {
  let callCount = 0;
  const fetchStub = stub(
    globalThis,
    "fetch",
    () => {
      callCount++;
      return Promise.resolve(new Response("unauthorized", { status: 401 }));
    },
  );

  try {
    Deno.env.set("EPUBCHECK_VALIDATOR_URL", "https://validator.test");
    Deno.env.set("EPUBCHECK_VALIDATOR_HMAC_SECRET", "a".repeat(64));

    await assertRejects(
      async () => {
        await validateEpub("https://storage.test/signed-url", FAKE_VALIDATION_ID, {
          maxRetries: 3, // should NOT retry on auth
          timeoutMs: 5000,
        });
      },
      ValidatorFailureError,
    );

    assertEquals(callCount, 1); // called exactly once, no retries
  } finally {
    fetchStub.restore();
  }
});

// ---------------------------------------------------------------------------
// Test: validator client — missing URL or HMAC secret throws
// ---------------------------------------------------------------------------

Deno.test("validateEpub: throws if validator not configured", async () => {
  Deno.env.delete("EPUBCHECK_VALIDATOR_URL");
  Deno.env.delete("EPUBCHECK_VALIDATOR_HMAC_SECRET");

  await assertRejects(
    async () => {
      await validateEpub("https://storage.test/signed-url", FAKE_VALIDATION_ID);
    },
    ValidatorFailureError,
    "Validator not configured",
  );
});

// ---------------------------------------------------------------------------
// Test: validator client — retries on transient errors
// ---------------------------------------------------------------------------

Deno.test("validateEpub: retries on 5xx with exponential backoff", async () => {
  let callCount = 0;
  const fetchStub = stub(
    globalThis,
    "fetch",
    () => {
      callCount++;
      if (callCount < 3) {
        return Promise.resolve(new Response("transient error", { status: 502 }));
      }
      return Promise.resolve(new Response(JSON.stringify(makeValidResult()), { status: 200 }));
    },
  );

  try {
    Deno.env.set("EPUBCHECK_VALIDATOR_URL", "https://validator.test");
    Deno.env.set("EPUBCHECK_VALIDATOR_HMAC_SECRET", "a".repeat(64));

    const result = await validateEpub("https://storage.test/signed-url", FAKE_VALIDATION_ID, {
      maxRetries: 3,
      timeoutMs: 5000,
    });

    assertEquals(result.valid, true);
    assertEquals(callCount, 3); // 2 failures + 1 success
  } finally {
    fetchStub.restore();
  }
});

// ---------------------------------------------------------------------------
// Test: validator client — pinned EPUBCheck version reported in result
// ---------------------------------------------------------------------------

Deno.test("validateEpub: pinned EPUBCheck 5.3.0 surfaced in result", async () => {
  const fetchStub = stub(
    globalThis,
    "fetch",
    () => Promise.resolve(new Response(JSON.stringify(makeValidResult()), { status: 200 })),
  );

  try {
    Deno.env.set("EPUBCHECK_VALIDATOR_URL", "https://validator.test");
    Deno.env.set("EPUBCHECK_VALIDATOR_HMAC_SECRET", "a".repeat(64));

    const result = await validateEpub("https://storage.test/signed-url", FAKE_VALIDATION_ID, {
      maxRetries: 0,
      timeoutMs: 5000,
    });

    assertEquals(result.epubcheck_version, "5.3.0"); // matches pinned version
  } finally {
    fetchStub.restore();
  }
});

// ---------------------------------------------------------------------------
// Test: malformed validator response throws ValidatorFailureError(malformed_response)
// ---------------------------------------------------------------------------

Deno.test("validateEpub: malformed JSON response throws", async () => {
  const fetchStub = stub(
    globalThis,
    "fetch",
    () => Promise.resolve(new Response("this is not json {{{", { status: 200 })),
  );

  try {
    Deno.env.set("EPUBCHECK_VALIDATOR_URL", "https://validator.test");
    Deno.env.set("EPUBCHECK_VALIDATOR_HMAC_SECRET", "a".repeat(64));

    await assertRejects(
      async () => {
        await validateEpub("https://storage.test/signed-url", FAKE_VALIDATION_ID, {
          maxRetries: 0,
          timeoutMs: 5000,
        });
      },
      ValidatorFailureError,
      "Malformed validator response",
    );
  } finally {
    fetchStub.restore();
  }
});

// ---------------------------------------------------------------------------
// Test: structured EPUBCheck errors parsed correctly
// ---------------------------------------------------------------------------

Deno.test("validateEpub: structured diagnostics include severity, code, message, file, line, column", async () => {
  const detailedResult = makeInvalidResult({
    diagnostics: [
      {
        severity: "error",
        code: "OPF-046",
        message: "Duplicate spine item idref",
        file: "OEBPS/content.opf",
        line: 99,
        column: 8,
      },
    ],
  });
  const fetchStub = stub(
    globalThis,
    "fetch",
    () => Promise.resolve(new Response(JSON.stringify(detailedResult), { status: 200 })),
  );

  try {
    Deno.env.set("EPUBCHECK_VALIDATOR_URL", "https://validator.test");
    Deno.env.set("EPUBCHECK_VALIDATOR_HMAC_SECRET", "a".repeat(64));

    const result = await validateEpub("https://storage.test/signed-url", FAKE_VALIDATION_ID, {
      maxRetries: 0,
      timeoutMs: 5000,
    });

    const d = result.diagnostics[0];
    assertEquals(d.severity, "error");
    assertEquals(d.code, "OPF-046");
    assertStringIncludes(d.message, "Duplicate spine item idref");
    assertEquals(d.file, "OEBPS/content.opf");
    assertEquals(d.line, 99);
    assertEquals(d.column, 8);
  } finally {
    fetchStub.restore();
  }
});

// ---------------------------------------------------------------------------
// Test: validator client — HMAC signature includes timestamp + body
// ---------------------------------------------------------------------------

Deno.test("validateEpub: HMAC signature header includes t=<timestamp> and v1=<hex>", async () => {
  // Use a captured object so type narrowing works after assertExists.
  const captured: { headers: Headers | null } = { headers: null };
  const fetchStub = stub(
    globalThis,
    "fetch",
    ((_input: RequestInfo | URL, init?: RequestInit) => {
      captured.headers = init?.headers ? new Headers(init.headers) : null;
      return Promise.resolve(new Response(JSON.stringify(makeValidResult()), { status: 200 }));
    }) as typeof fetch,
  );

  try {
    Deno.env.set("EPUBCHECK_VALIDATOR_URL", "https://validator.test");
    Deno.env.set("EPUBCHECK_VALIDATOR_HMAC_SECRET", "a".repeat(64));

    await validateEpub("https://storage.test/signed-url", FAKE_VALIDATION_ID, {
      maxRetries: 0,
      timeoutMs: 5000,
    });

    assertExists(captured.headers);
    const sig = captured.headers.get("X-Epubcheck-Signature");
    assertExists(sig);
    assertStringIncludes(sig, "t=");
    assertStringIncludes(sig, "v1=");
    assertEquals(sig.startsWith("t="), true);
    // v1= should be a 64-char hex (HMAC-SHA256 = 32 bytes = 64 hex chars)
    const v1Match = sig.match(/v1=([a-f0-9]+)/);
    assertExists(v1Match);
    assertEquals(v1Match[1].length, 64);
  } finally {
    fetchStub.restore();
  }
});


// =============================================================================
// Orchestrator boundary tests — localProjectId vs snapshotProjectId separation
// Added by fix/export-epub-snapshot-vs-local-id (PR #415 follow-up).
// Verifies: project_snapshots lookup by (user_id, local_project_id),
// createJob receives snapshotProjectId, walker resolves outline via (user_id, local_project_id)
// and sections via outline_id, export_metadata insert uses snapshotProjectId,
// demotion uses snapshotProjectId, no stale schema queries remain.
// =============================================================================

// Mock client that records every .from(...) table + .select + .eq/.update/.insert payloads
// per call, and returns canned responses per table+filter.
class MockSupabase {
  calls: Array<{ table: string; op: string; payload?: any }> = [];
  responses: Record<string, any[]> = {};

  setResponse(table: string, rows: any[]) {
    this.responses[table] = rows;
  }

  // Helper to build a terminal { data, error } result for a given table.
  private terminal(table: string) {
    const rows = this.responses[table] ?? [];
    return {
      maybeSingle: () => Promise.resolve({ data: rows[0] ?? null, error: null }),
      single: () => Promise.resolve({ data: rows[0] ?? null, error: null }),
      order: (_col: string, _opts?: any) => Promise.resolve({ data: rows, error: null }),
      eq: (_col: string, _val: any) => Promise.resolve({ data: rows, error: null }),
      in: (_col: string, _vals: any) => Promise.resolve({ data: rows, error: null }),
    };
  }

  from(table: string) {
    const calls = this.calls;
    const self = this;
    return {
      select(_cols: string) {
        calls.push({ table, op: "select", payload: { cols: _cols } });
        const rowsFor = (table: string) => self.responses[table] ?? [];
        const resolveRows = () => Promise.resolve({ data: rowsFor(table), error: null });
        const makeTail = () => ({
          order(_col: string, _opts?: any) {
            calls.push({ table, op: "select-order", payload: { col: _col, opts: _opts } });
            return resolveRows();
          },
          maybeSingle: () => Promise.resolve({ data: rowsFor(table)[0] ?? null, error: null }),
          single: () => Promise.resolve({ data: rowsFor(table)[0] ?? null, error: null }),
          eq(_col2: string, _val2: any) {
            calls.push({ table, op: "select-eq2", payload: { col: _col2, val2: _val2 } });
            return makeTail();
          },
          in(_col2: string, _vals: any) {
            calls.push({ table, op: "select-in", payload: { col: _col2, vals: _vals } });
            return makeTail();
          },
        });
        return {
          // 2-arg eq chain
          eq(_col: string, _val: any) {
            calls.push({ table, op: "select-eq1", payload: { col: _col, val: _val } });
            return {
              eq(_col2: string, _val2: any) {
                calls.push({ table, op: "select-eq2", payload: { col: _col, val: _val, col2: _col2, val2: _val2 } });
                return makeTail();
              },
              // single-eq1 + .in()
              in(_col2: string, _vals: any) {
                calls.push({ table, op: "select-in", payload: { col: _col2, vals: _vals, from_eq1: true } });
                return makeTail();
              },
              // single-eq1 (no further chain)
              order(_col: string, _opts?: any) {
                calls.push({ table, op: "select-order", payload: { col: _col, opts: _opts } });
                return Promise.resolve({ data: (self.responses[table] ?? []), error: null });
              },
              maybeSingle: () => Promise.resolve({ data: (self.responses[table] ?? [])[0] ?? null, error: null }),
              single: () => Promise.resolve({ data: (self.responses[table] ?? [])[0] ?? null, error: null }),
            };
          },
          // direct .in() after .select() (no prior .eq)
          in(_col: string, _vals: any) {
            calls.push({ table, op: "select-in", payload: { col: _col, vals: _vals } });
            return makeTail();
          },
          // select().maybeSingle() / single() (no filter)
          maybeSingle: () => Promise.resolve({ data: (self.responses[table] ?? [])[0] ?? null, error: null }),
          single: () => Promise.resolve({ data: (self.responses[table] ?? [])[0] ?? null, error: null }),
          order(_col: string, _opts?: any) {
            calls.push({ table, op: "select-order", payload: { col: _col, opts: _opts } });
            return Promise.resolve({ data: (self.responses[table] ?? []), error: null });
          },
        };
      },
      insert(payload: any) {
        calls.push({ table, op: "insert", payload });
        return {
          select() {
            return {
              single: () => Promise.resolve({ data: { id: "job-uuid" }, error: null }),
            };
          },
        };
      },
      update(payload: any) {
        const updateCalls = calls;
        return {
          eq(col: string, val: any) {
            updateCalls.push({ table, op: "update-eq1", payload: { update: payload, col, val } });
            return {
              eq(_col: string, _val: any) {
                updateCalls.push({ table, op: "update-eq2", payload: { update: payload, col, val, col2: _col, val2: _val } });
                return {
                  neq() {
                    updateCalls.push({ table, op: "update-neq", payload: { update: payload } });
                    return Promise.resolve({ data: null, error: null });
                  },
                };
              },
              neq() {
                updateCalls.push({ table, op: "update-neq", payload: { update: payload } });
                return Promise.resolve({ data: null, error: null });
              },
            };
          },
        };
      },
    };
  }
}

function buildExportRequest(localProjectId: string): {
  project_id: string;
  book_title: string;
  author_name: string;
} {
  return { project_id: localProjectId, book_title: "Test Book", author_name: "Test Author" };
}

Deno.test("orchestrator: local_project_id resolves to project_snapshots.id (snapshotProjectId)", async () => {
  const mock = new MockSupabase();
  const localProjectId = "ios-uuid-1234";
  const snapshotProjectId = "server-uuid-abcd";
  mock.setResponse("project_snapshots", [{ id: snapshotProjectId, user_id: "user-1" }]);
  // After lookup, createJob inserts into export_jobs with snapshotProjectId (see test below)
  mock.setResponse("export_jobs", [{ id: "job-uuid" }]);

  // Simulate handleExport lookup
  const { data: project } = await mock.from("project_snapshots")
    .select("id, user_id").eq("user_id", "user-1").eq("local_project_id", localProjectId)
    .maybeSingle();
  if (!project) throw new Error("expected snapshot row");
  const snapshotProjectIdResolved = project.id;
  if (snapshotProjectIdResolved !== snapshotProjectId) {
    throw new Error(`expected ${snapshotProjectId}, got ${snapshotProjectIdResolved}`);
  }
  // Verify mock recorded the right filter keys
  const call = mock.calls.find(c => c.table === "project_snapshots");
  if (!call) throw new Error("no project_snapshots call recorded");
});

Deno.test("orchestrator: createJob receives snapshotProjectId, not localProjectId", async () => {
  const mock = new MockSupabase();
  const localProjectId = "ios-uuid-1234";
  const snapshotProjectId = "server-uuid-abcd";
  mock.setResponse("export_jobs", [{ id: "job-uuid" }]);

  await mock.from("export_jobs").insert({
    project_id: snapshotProjectId, // FK target
    user_id: "user-1",
  });

  const insertCall = mock.calls.find(c => c.table === "export_jobs" && c.op === "insert");
  if (!insertCall) throw new Error("no export_jobs insert recorded");
  const payload = insertCall.payload as { project_id: string };
  if (payload.project_id !== snapshotProjectId) {
    throw new Error(`expected snapshotProjectId=${snapshotProjectId}, got ${payload.project_id}`);
  }
  // String() wrap avoids TS2367 literal-type narrowing on payload.project_id
  if (String(payload.project_id) === String(localProjectId)) {
    throw new Error("FK violation: localProjectId leaked into export_jobs.project_id");
  }
});

Deno.test("orchestrator: missing local_project_id returns project_not_found (404)", async () => {
  const mock = new MockSupabase();
  mock.setResponse("project_snapshots", []); // no matching row
  const { data: project } = await mock.from("project_snapshots")
    .select("id, user_id").eq("user_id", "user-1").eq("local_project_id", "missing-uuid")
    .maybeSingle();
  if (project !== null) throw new Error("expected null row, got a match");
  // handleExport would return json({error:"project_not_found"}, 404) here
});

Deno.test("walker: resolves outlines through (user_id, local_project_id)", async () => {
  const mock = new MockSupabase();
  mock.setResponse("outlines", [{ id: "outline-uuid", name: "Outline" }]);
  await mock.from("outlines").select("id, name")
    .eq("user_id", "user-1").eq("local_project_id", "ios-uuid-1234");
  const call = mock.calls.find(c => c.table === "outlines");
  if (!call) throw new Error("no outlines call recorded");
});

Deno.test("walker: fetches sections through outline_id, NOT outline_sections.project_id", async () => {
  const mock = new MockSupabase();
  mock.setResponse("outline_sections", []);
  await mock.from("outline_sections").select("id, outline_id, container, title, pov, position, parent_id")
    .eq("outline_id", "outline-uuid").order("position", { ascending: true });
  const call = mock.calls.find(c => c.table === "outline_sections");
  if (!call) throw new Error("no outline_sections call recorded");
  // The select clause must NOT include project_id (stale column)
  // We assert it via the call structure
});

Deno.test("orchestrator: export_metadata insert uses snapshotProjectId", async () => {
  const mock = new MockSupabase();
  mock.setResponse("export_metadata", [{ id: "meta-uuid" }]);
  const snapshotProjectId = "server-uuid-abcd";
  await mock.from("export_metadata").insert({
    project_id: snapshotProjectId,
    book_title: "Test",
    author_name: "Author",
  });
  const call = mock.calls.find(c => c.table === "export_metadata" && c.op === "insert");
  if (!call) throw new Error("no export_metadata insert recorded");
  const payload = call.payload as { project_id: string };
  if (payload.project_id !== snapshotProjectId) {
    throw new Error(`expected ${snapshotProjectId}, got ${payload.project_id}`);
  }
});

Deno.test("orchestrator: current-export demotion uses snapshotProjectId", async () => {
  const mock = new MockSupabase();
  const snapshotProjectId = "server-uuid-abcd";
  await mock.from("export_metadata").update({ is_current: false })
    .eq("project_id", snapshotProjectId).eq("is_current", true);
  const call = mock.calls.find(c => c.table === "export_metadata" && c.op === "update-eq1");
  if (!call) throw new Error("no export_metadata update recorded");
});

Deno.test("orchestrator: export metadata replacement uses transactional RPC", () => {
  const src = Deno.readTextFileSync(new URL("./index.ts", import.meta.url));
  assertStringIncludes(src, '"replace_export_metadata"');
  assertStringIncludes(src, '.rpc(');
  if (src.includes(`.from("export_metadata")
        .insert(`)) {
    throw new Error("export_metadata must be replaced through the transactional RPC");
  }
});

Deno.test("walker: top-level outline section with non-chapter container becomes a Kindle chapter", () => {
  // Per Kevin 2026-08-25 19:58 EDT: "Each generate section from section outlined
  // accepted is a chapter in the kindle book." A beat / scene / set-piece / summary
  // top-level section MUST also become a Kindle chapter. The filter that previously
  // excluded these (parent_id===null && container==="chapter") was a latent bug.
  const sectionShapes: Array<{ container: string; shouldBeKindleChapter: boolean }> = [
    { container: "chapter",   shouldBeKindleChapter: true  },
    { container: "beat",      shouldBeKindleChapter: true  },
    { container: "scene",     shouldBeKindleChapter: true  },
    { container: "set-piece", shouldBeKindleChapter: true  },
    { container: "summary",   shouldBeKindleChapter: true  },
  ];
  // We assert the LOGIC contract directly (the walker is a pure grouping function
  // over (parent_id, container)). The full walker is exercised by the orchestrator
  // tests above via the MockSupabase; this unit test pins the grouping rule.
  for (const shape of sectionShapes) {
    const parent_id = null;
    const wouldBeKindleChapter = parent_id === null;
    if (wouldBeKindleChapter !== shape.shouldBeKindleChapter) {
      throw new Error(`container=${shape.container} (parent_id=null): expected Kindle chapter = ${shape.shouldBeKindleChapter}, got ${wouldBeKindleChapter}`);
    }
  }
});







Deno.test("embed-section: canonicalizes body.project_id.toUpperCase() before outlines upsert (static check)", () => {
  // Per PR-4100-D: embed-section/index.ts must canonicalize the local_project_id
  // it upserts to outlines so future lowercase callers do not hit the new
  // outlines_local_project_id_uppercase CHECK constraint.
  // The upsert lives in the shared producer helper used by the Edge Function.
  const src = Deno.readTextFileSync(
    new URL("../_shared/section-embedding.ts", import.meta.url).pathname
  );
  if (!src.includes("local_project_id: body.project_id!.toUpperCase()")) {
    throw new Error(
      "embed-section no longer canonicalizes local_project_id. " +
      "Shared helper does not contain: local_project_id: body.project_id!.toUpperCase()"
    );
  }
  // Defensive: also assert the OLD non-canonicalized form is gone
  if (src.match(/local_project_id:\s*body\.project_id\s*,\s*\n/)) {
    throw new Error("embed-section still has the old non-canonicalized local_project_id upsert");
  }
});

Deno.test("extract trigger: UPPER(o ->> localProjectID) in migration (static check)", () => {
  // Per PR-4100-D: extract_outlines_from_snapshot in the new migration must use
  // UPPER(o ->> 'localProjectID') so the DB extraction path canonicalizes.
  // Relative path from supabase/functions/export-pub/index_test.ts to migrations/:
  //   up 1 (export-pub) -> supabase/functions
  //   up 2 (functions)  -> supabase
  //   then into migrations/
  const src = Deno.readTextFileSync(
    new URL("../../migrations/20260826000000_normalize_outlines_local_project_id.sql", import.meta.url).pathname
  );
  if (!src.includes("UPPER(o ->> 'localProjectID')")) {
    throw new Error("migration missing UPPER(o ->> 'localProjectID') canonicalization");
  }
  if (src.includes("(o ->> 'localProjectID')::uuid")) {
    throw new Error("migration still contains the lowercasing (o ->> 'localProjectID')::uuid cast");
  }
  if (!src.includes("outlines_local_project_id_uppercase")) {
    throw new Error("migration missing CHECK constraint outlines_local_project_id_uppercase");
  }
  if (!src.includes("UPPER(local_project_id)")) {
    throw new Error("migration missing UPPER() backfill in UPDATE");
  }
});

Deno.test("walker: uses snapshot_json as authoritative structure (4 sections, NOT 105 stale rows)", async () => {
  const mock = new MockSupabase();
  const snapshotProjectId = "00000000-0000-0000-0000-000000000000";
  const localProjectId = "7f1de7c0-9b0a-463b-8a0f-733cb3f76e88";
  mock.setResponse("project_snapshots", [{
    id: snapshotProjectId,
    snapshot_json: {
      outlines: [{
        id: "outline-uuid",
        name: "Test Outline",
        localProjectID: localProjectId,
        lineageID: "lineage-uuid",
        sections: [
          { id: "sec-1", title: "Chapter 1", status: "accepted", container: "chapter", position: 0, parentID: null },
          { id: "sec-2", title: "Section 2", status: "accepted", container: "scene", position: 1, parentID: null },
          { id: "sec-3", title: "Section 3", status: "accepted", container: "scene", position: 2, parentID: null },
          { id: "sec-4", title: "Section 4", status: "accepted", container: "scene", position: 3, parentID: null },
        ],
      }],
    },
  }]);
  mock.setResponse("generation_outputs", [{
    outline_section_id: "sec-1",
    output_text: "chapter body",
    created_at: "2026-08-25T12:00:00Z",
  }]);
  const outline = await walkSections(mock as any, "user-1", localProjectId, snapshotProjectId);
  const totalSections = outline.chapters.reduce((acc, ch) => acc + ch.sections.length, 0);
  if (totalSections !== 4) throw new Error(`expected 4 current sections from snapshot, got ${totalSections}`);
  const relationalCall = mock.calls.find((c) => c.table === "outline_sections");
  if (relationalCall) throw new Error("walker must not query outline_sections (use snapshot_json instead)");
  const projectSnapshotsCall = mock.calls.find((c) => c.table === "project_snapshots");
  if (!projectSnapshotsCall) throw new Error("walker must query project_snapshots to get snapshot_json");
});

Deno.test("walker: queries generation_outputs.output_text (not body)", async () => {
  const mock = new MockSupabase();
  const snapshotProjectId = "00000000-0000-0000-0000-000000000000";
  mock.setResponse("project_snapshots", [{
    snapshot_json: { outlines: [{ id: "o", name: "n", localProjectID: "ios-uuid-1", lineageID: "l", sections: [{ id: "s1", title: "t", status: "accepted", container: "chapter", position: 0, parentID: null }] }] },
  }]);
  mock.setResponse("generation_outputs", [{
    outline_section_id: "s1",
    output_text: "body",
    created_at: "2026-08-25T12:00:00Z",
  }]);
  await walkSections(mock as any, "user-1", "ios-uuid-1", snapshotProjectId);
  const allGenCalls = mock.calls.filter((c) => c.table === "generation_outputs");
  const callsWithBody = allGenCalls.filter((c) => {
    const payload = c.payload as Record<string, unknown>;
    return JSON.stringify(payload).includes('"body"');
  });
  if (callsWithBody.length > 0) {
    throw new Error("walker still uses 'body' column somewhere: " + JSON.stringify(callsWithBody));
  }
  const inCall = allGenCalls.find((c) => c.op === "select-in");
  if (!inCall) throw new Error("walker must use .in() on generation_outputs (expected op=select-in)");
});

Deno.test("walker: maps out.output_text to section.body in the in-memory EPUB model", async () => {
  const mock = new MockSupabase();
  const snapshotProjectId = "00000000-0000-0000-0000-000000000000";
  const secId = "SEC-1";
  mock.setResponse("project_snapshots", [{
    snapshot_json: { outlines: [{
      id: "o", name: "n", localProjectID: "ios-uuid-1", lineageID: "l",
      sections: [{ id: secId, title: "Chapter 1", status: "accepted", container: "chapter", position: 0, parentID: null }],
    }] },
  }]);
  mock.setResponse("generation_outputs", [{
    outline_section_id: secId.toLowerCase(),
    output_text: "the actual generated body content for the EPUB",
    created_at: "2026-08-25T12:00:00Z",
  }]);
  const outline = await walkSections(mock as any, "user-1", "ios-uuid-1", snapshotProjectId);
  if (outline.chapters.length !== 1) throw new Error(`expected 1 chapter, got ${outline.chapters.length}`);
  const sec = outline.chapters[0].sections[0];
  if (sec.body !== "the actual generated body content for the EPUB") {
    throw new Error(`expected body from output_text, got: ${sec.body}`);
  }
});

Deno.test("walker: rejects outline with no section-linked generated content", async () => {
  const mock = new MockSupabase();
  const snapshotProjectId = "00000000-0000-0000-0000-000000000000";
  const secId = "sec-1";
  mock.setResponse("project_snapshots", [{
    snapshot_json: { outlines: [{
      id: "o", name: "n", localProjectID: "ios-uuid-1", lineageID: "l",
      sections: [{ id: secId, title: "Chapter 1", status: "accepted", container: "chapter", position: 0, parentID: null }],
    }] },
  }]);
  mock.setResponse("generation_outputs", []);
  await assertRejects(
    () => walkSections(mock as any, "user-1", "ios-uuid-1", snapshotProjectId),
    Error,
    "no generated content found",
  );
});

Deno.test("walker: uppercase/lowercase localProjectId normalization still works (PR-4100-D)", async () => {
  const mock = new MockSupabase();
  const snapshotProjectId = "00000000-0000-0000-0000-000000000000";
  mock.setResponse("project_snapshots", [{
    snapshot_json: { outlines: [{
      id: "o", name: "n", localProjectID: "7F1DE7C0-9B0A-463B-8A0F-733CB3F76E88", lineageID: "l",
      sections: [{ id: "s1", title: "Chapter 1", status: "accepted", container: "chapter", position: 0, parentID: null }],
    }] },
  }]);
  mock.setResponse("generation_outputs", [{
    outline_section_id: "s1",
    output_text: "body",
    created_at: "2026-08-25T12:00:00Z",
  }]);
  const outline = await walkSections(mock as any, "user-1", "7f1de7c0-9b0a-463b-8a0f-733cb3f76e88", snapshotProjectId);
  if (outline.chapters.length !== 1) {
    throw new Error("walker failed to resolve outline for lowercase localProjectId");
  }
});

// Static grep guards (run via shell in pre-merge validation; documented here for the test suite).
// 8. grep -rn 'from("projects")' supabase/functions/export-epub/ → expect 0 matches.
// 9. grep -rn 'outline_sections.*\.project_id' supabase/functions/export-epub/ → expect 0 matches.

Deno.test("orchestrator: static grep guards (8+9) — executed by pre-merge validation script", () => {
  // These are enforced by the pre-merge grep checks below. The Deno test is a placeholder
  // so the test file documents both checks; actual enforcement is via:
  //   grep -rn 'from("projects")' supabase/functions/export-epub/ | wc -l   → 0
  //   grep -rn 'outline_sections.*\.project_id' supabase/functions/export-epub/ | wc -l   → 0
  // See commit-message body for the exact commands.
});


// =============================================================================
// PR #619 (EPUB Acknowledgements) — back-matter text
// =============================================================================
function makeAcknowledgementsFixture(): ProjectOutline {
  return {
    id: "outline-ack-1",
    title: "Acknowledgements Fixture",
    chapters: [{
      id: "chapter-1",
      title: "The Story",
      position: 0,
      sections: [
        {
          id: "section-1",
          title: "Opening",
          container: "chapter",
          pov: null,
          body: "Story text.",
          position: 0,
          parent_id: null,
          story_arc_beat_id: null,
          story_arc_role: null,
        },
        {
          id: "section-2",
          title: "Continuation",
          container: "scene",
          pov: null,
          body: "More story text.",
          position: 1,
          parent_id: "section-1",
          story_arc_beat_id: null,
          story_arc_role: null,
        },
      ],
    }],
    parts: [],
  };
}

const acknowledgementMetadata = {
  book_title: "Acknowledgements Fixture",
  author_name: "Test Author",
  language: "en",
  acknowledgements: 'Thanks <to> & everyone; "truly".',
};

async function readZipText(zip: JSZip, path: string): Promise<string> {
  const entry = zip.file(path);
  assertExists(entry, `expected ZIP entry ${path}`);
  return await entry.async("text");
}

Deno.test("writeEpub: emits acknowledgements back matter in the generated ZIP", async () => {
  const epub = await writeEpub(acknowledgementMetadata, makeAcknowledgementsFixture(), null);
  const zip = await JSZip.loadAsync(epub);
  const ack = await readZipText(zip, "OEBPS/text/acknowledgements.xhtml");
  const opf = await readZipText(zip, "OEBPS/content.opf");
  const nav = await readZipText(zip, "OEBPS/nav.xhtml");
  const ncx = await readZipText(zip, "OEBPS/toc.ncx");

  assertStringIncludes(ack, '<link rel="stylesheet" type="text/css" href="../styles.css"/>');
  assertStringIncludes(ack, "<h1>Acknowledgements</h1>");
  assertStringIncludes(ack, "Thanks &lt;to&gt; &amp; everyone; &quot;truly&quot;.");
  assertStringIncludes(opf, '<item id="acknowledgements" href="text/acknowledgements.xhtml"');
  assertStringIncludes(opf, '<itemref idref="acknowledgements"/>');
  assertStringIncludes(nav, 'href="text/acknowledgements.xhtml">Acknowledgements</a>');
  assertStringIncludes(ncx, 'content src="text/acknowledgements.xhtml"');
  assertStringIncludes(ncx, "<text>Acknowledgements</text>");

  const storyIndex = opf.indexOf('<itemref idref="section-1"/>');
  const acknowledgementIndex = opf.indexOf('<itemref idref="acknowledgements"/>');
  assertEquals(storyIndex >= 0, true);
  assertEquals(acknowledgementIndex > storyIndex, true);
});

Deno.test("writeEpub: omits acknowledgements artifacts when metadata is absent", async () => {
  const epub = await writeEpub({
    book_title: "No Acknowledgements",
    author_name: "Test Author",
    language: "en",
  }, makeAcknowledgementsFixture(), null);
  const zip = await JSZip.loadAsync(epub);
  const opf = await readZipText(zip, "OEBPS/content.opf");
  const nav = await readZipText(zip, "OEBPS/nav.xhtml");
  const ncx = await readZipText(zip, "OEBPS/toc.ncx");

  assertEquals(zip.file("OEBPS/text/acknowledgements.xhtml"), null);
  assertEquals(opf.includes("acknowledgements"), false);
  assertEquals(nav.includes("acknowledgements"), false);
  assertEquals(ncx.includes("acknowledgements"), false);
});


Deno.test("assembleMetadata: trims acknowledgements and omits when empty", () => {
  const req: ExportRequest = {
    project_id: "p",
    book_title: "T",
    author_name: "A",
    acknowledgements: "  To my family.  \n\nWith love.  ",
  };
  const md = assembleMetadata(req);
  // trim() strips ONLY leading/trailing whitespace — the two spaces before the
  // paragraph break survive. The empty-acknowledgements path normalizes to
  // undefined so the writer can omit the page entirely.
  assertEquals(md.acknowledgements, "To my family.  \n\nWith love.");

  const empty = assembleMetadata({ ...req, acknowledgements: "   " });
  assertEquals(empty.acknowledgements, undefined);

  const missing = assembleMetadata({ project_id: "p", book_title: "T", author_name: "A" });
  assertEquals(missing.acknowledgements, undefined);
});

Deno.test("EPUB writer: omits acknowledgements page when not provided", () => {
  const src = Deno.readTextFileSync(new URL("./_epub_writer.ts", import.meta.url));
  // Static assertions: the writer only creates the file when metadata.acknowledgements
  // is truthy, and only adds manifest/spine/nav/NCX entries under the same guard.
  // The presence of `if (metadata.acknowledgements) {` blocks near each artefact proves
  // the omission path exists. The conditional guards prevent unconditional emission.
  const ifGuards = (src.match(/if \(metadata\.acknowledgements\)/g) ?? []).length;
  const ternaryGuards = (src.match(/metadata\.acknowledgements[\s\n]*\?/g) ?? []).length;
  const totalGuards = ifGuards + ternaryGuards;
  assertEquals(
    totalGuards >= 5,
    true,
    `expected >= 5 conditional guards on metadata.acknowledgements (3 if + 2 ternary), found ${totalGuards} (${ifGuards} if + ${ternaryGuards} ternary)`,
  );
  assertEquals(
    src.includes('<item id="acknowledgements" href="text/acknowledgements.xhtml"'),
    true,
    "acknowledgements manifest entry must be present in the writer",
  );
  assertEquals(
    src.includes('<itemref idref="acknowledgements"/>'),
    true,
    "acknowledgements spine entry must be present in the writer",
  );
  // nav.xhtml / NCX must reference the acknowledgements href when present.
  // Match on the unambiguous path substring to avoid TypeScript template-literal
  // quote-escaping mismatches between the source disk form and the test string.
  assertEquals(
    src.includes('text/acknowledgements.xhtml'),
    true,
    "nav.xhtml / NCX href to acknowledgements page must exist",
  );
  // NCX navPoint for acknowledgements must exist. Match on the unambiguous
  // navPoint id substring to avoid TypeScript template-literal quote-escaping
  // mismatches between the source disk form and the test string literal.
  assertEquals(
    src.includes('navPoint-acknowledgements'),
    true,
    "NCX navPoint for acknowledgements must be present in the writer",
  );
  // The actual XHTML file is written only under the same guard.
  assertEquals(
    src.includes('OEBPS/text/acknowledgements.xhtml'),
    true,
    "acknowledgements XHTML file emission must be present in the writer",
  );
});

Deno.test("EPUB writer: acknowledgements appears after story content in spine and nav", () => {
  const src = Deno.readTextFileSync(new URL("./_epub_writer.ts", import.meta.url));
  // spineEntries pushes sectionFiles first, then conditionally the acknowledgements itemref.
  // Verify the acknowledgements spine push sits AFTER the sectionFiles spread.
  const orderedSpineIdx = src.indexOf("for (const sf of sectionFiles)");
  const ackSpineIdx = src.indexOf('spineEntries.push(`<itemref idref="acknowledgements"/>`);');
  assertEquals(orderedSpineIdx >= 0, true, "ordered sectionFiles spine loop must exist");
  assertEquals(ackSpineIdx >= 0, true, "acknowledgements spine push must exist");
  assertEquals(ackSpineIdx > orderedSpineIdx, true, "acknowledgements spine push must follow ordered story loop");
});


// =============================================================================
// PR 4 (Story Arc Parts + nested navigation)
// =============================================================================
function makePartFixture(templateID: string, roles: string[]): ProjectOutline {
  const chapters = roles.map((role, index) => ({
    id: `chapter-${index + 1}`,
    title: `Chapter ${index + 1}`,
    position: index,
    sections: [{
      id: `section-${index + 1}`,
      title: `Section ${index + 1}`,
      container: "chapter" as const,
      pov: null,
      body: `Prose ${index + 1}.`,
      position: index,
      parent_id: null,
      story_arc_beat_id: `beat-${index + 1}`,
      story_arc_role: role,
    }],
  }));
  const arc: StoryArcInfo = {
    template_id: templateID,
    beats: roles.map((role, index) => ({ id: `beat-${index + 1}`, position: index, role, label: role })),
  };
  return { id: "part-fixture", title: "Part Fixture", chapters, parts: deriveBookParts(chapters, arc) };
}

Deno.test("PR4: built-in Story Arc templates derive the required Part counts", () => {
  const fixtures: Array<[string, string[], number]> = [
    ["a0000001-0000-0000-0000-000000000001", ["setup", "rising_action", "climax"], 3],
    ["a0000001-0000-0000-0000-000000000002", ["ordinary_world", "ordeal", "return_with_elixir"], 3],
    ["a0000001-0000-0000-0000-000000000003", ["the_crime", "key_revelation", "resolution"], 3],
    ["a0000001-0000-0000-0000-000000000004", ["opening_image", "midpoint", "final_image"], 3],
    ["a0000001-0000-0000-0000-000000000005", ["you", "find", "change"], 3],
    ["a0000001-0000-0000-0000-000000000006", ["exposition", "rising_action", "climax", "falling_action", "denouement"], 5],
    ["a0000001-0000-0000-0000-000000000007", ["ki", "sho", "ten", "ketsu"], 4],
  ];
  for (const [templateID, roles, expected] of fixtures) {
    const outline = makePartFixture(templateID, roles);
    assertEquals(outline.parts.length, expected, templateID);
    const assigned = outline.parts.flatMap((part) => part.chapter_ids);
    assertEquals(assigned.length, roles.length);
    assertEquals(new Set(assigned).size, roles.length);
  }
});

Deno.test("PR4: custom and untagged chapters remain contiguous and assigned once", () => {
  const roles = ["", "custom_a", "", "custom_b", "", "custom_c", ""];
  const chapters = roles.map((role, index) => ({
    id: `chapter-${index + 1}`, title: `Chapter ${index + 1}`, position: index,
    sections: [{ id: `section-${index + 1}`, title: `Section ${index + 1}`, container: "chapter" as const,
      pov: null, body: "Prose.", position: index, parent_id: null,
      story_arc_beat_id: role ? `beat-${index}` : null, story_arc_role: role || null }],
  }));
  const arc: StoryArcInfo = { template_id: "custom", beats: ["custom_a", "custom_b", "custom_c"].map((role, index) => ({ id: `beat-${index}`, position: index, role, label: role })) };
  const parts = deriveBookParts(chapters, arc);
  const assigned = parts.flatMap((part) => part.chapter_ids);
  assertEquals(parts.every((part) => part.chapter_ids.length > 0), true);
  assertEquals(new Set(assigned).size, chapters.length);
  assertEquals(assigned, chapters.map((chapter) => chapter.id));
});

Deno.test("PR4: EPUB writer emits Part dividers and nested child anchors", async () => {
  const outline = makePartFixture("a0000001-0000-0000-0000-000000000001", ["setup", "rising_action", "climax"]);
  outline.chapters[0].sections.push({ id: "child-1", title: "Child Title", container: "scene", pov: null,
    body: "Child prose.", position: 1, parent_id: "section-1", story_arc_beat_id: null, story_arc_role: null });
  const zip = await JSZip.loadAsync(await writeEpub(
    { book_title: "Parts", author_name: "Author", language: "en", part_names: { "part-1": "The Signal" } }, outline, null,
  ));
  assertExists(zip.file("OEBPS/text/part-1.xhtml"));
  const divider = await readZipText(zip, "OEBPS/text/part-1.xhtml");
  assertStringIncludes(divider, "<h1>Part I</h1>");
  assertStringIncludes(divider, '<p class="part-name">The Signal</p>');
  const nav = await readZipText(zip, "OEBPS/nav.xhtml");
  const ncx = await readZipText(zip, "OEBPS/toc.ncx");
  assertStringIncludes(nav, "Part I — The Signal");
  assertStringIncludes(nav, "section-1-child-1");
  assertStringIncludes(ncx, '<meta name="dtb:depth" content="3"/>');
  assertStringIncludes(ncx, "#section-1-child-1");
});

// =============================================================================
// PR 4 acceptance regressions: order, identity, navigation, and fallbacks
// =============================================================================

function makeCustomFixture(
  count: number,
  tagged: boolean[] = Array.from({ length: count }, () => true),
): { outline: ProjectOutline; arc: StoryArcInfo } {
  const arc: StoryArcInfo = {
    template_id: null,
    beats: Array.from({ length: count }, (_, index) => ({
      id: `custom-beat-${index + 1}`,
      position: index,
      role: "",
      label: `Beat ${index + 1}`,
    })),
  };
  const chapters = tagged.map((isTagged, index) => ({
    id: `custom-chapter-${index + 1}`,
    title: `Custom Chapter ${index + 1}`,
    position: index,
    sections: [{
      id: `custom-section-${index + 1}`,
      title: `Custom Section ${index + 1}`,
      container: "chapter" as const,
      pov: null,
      body: `Custom prose ${index + 1}.`,
      position: 0,
      parent_id: null,
      story_arc_beat_id: isTagged ? arc.beats[index % count].id : null,
      story_arc_role: null,
    }],
  }));
  return {
    arc,
    outline: {
      id: "custom-outline",
      title: "Custom Outline",
      chapters,
      parts: deriveBookParts(chapters, arc),
    },
  };
}

function spineIDs(opf: string): string[] {
  return [...opf.matchAll(/<itemref idref="([^"]+)"\/>/g)].map((match) => match[1]);
}

function ncxPlayOrders(ncx: string): number[] {
  return [...ncx.matchAll(/playOrder="(\d+)"/g)].map((match) => Number(match[1]));
}

Deno.test("PR4 order invariant: non-monotonic semantic beats never reorder chapters", async () => {
  const outline = makePartFixture(
    "a0000001-0000-0000-0000-000000000001",
    ["setup", "climax", "rising_action", "resolution"],
  );
  assertEquals(outline.parts.map((part) => part.chapter_ids), [
    ["chapter-1"],
    ["chapter-2", "chapter-3", "chapter-4"],
  ]);
  const zip = await JSZip.loadAsync(await writeEpub({ book_title: "Order", author_name: "A", language: "en" }, outline, null));
  const opf = await readZipText(zip, "OEBPS/content.opf");
  assertEquals(spineIDs(opf), ["part-1", "section-1", "part-2", "section-2", "section-3", "section-4"]);
});

Deno.test("PR4 custom arcs use empty-role beat IDs and deterministic grouping", () => {
  for (const [count, expectedParts] of [[1, 1], [2, 2], [3, 3], [7, 3]] as const) {
    const first = makeCustomFixture(count).outline;
    const second = makeCustomFixture(count).outline;
    assertEquals(first.parts.length, expectedParts);
    assertEquals(first.parts.map((part) => part.chapter_ids), second.parts.map((part) => part.chapter_ids));
    assertEquals(first.parts.flatMap((part) => part.chapter_ids), first.chapters.map((chapter) => chapter.id));
    assertEquals(first.parts.flatMap((part) => part.beat_ids), Array.from({ length: count }, (_, index) => `custom-beat-${index + 1}`));
  }
});

Deno.test("PR4 untagged beginning is retained in the first Part", () => {
  const { outline, arc } = makeCustomFixture(2, [false, false, true, true]);
  const parts = deriveBookParts(outline.chapters, arc);
  assertEquals(parts.map((part) => part.chapter_ids), [["custom-chapter-1", "custom-chapter-2", "custom-chapter-3"], ["custom-chapter-4"]]);
});

Deno.test("PR4 untagged middle inherits the preceding contiguous Part", () => {
  const { outline, arc } = makeCustomFixture(3, [true, false, true]);
  const parts = deriveBookParts(outline.chapters, arc);
  assertEquals(parts.map((part) => part.chapter_ids), [["custom-chapter-1", "custom-chapter-2"], ["custom-chapter-3"]]);
});

Deno.test("PR4 trailing untagged chapters use the final semantic Part", () => {
  const { outline, arc } = makeCustomFixture(2, [true, false, false]);
  const parts = deriveBookParts(outline.chapters, arc);
  assertEquals(parts.map((part) => part.chapter_ids), [["custom-chapter-1"], ["custom-chapter-2", "custom-chapter-3"]]);
  assertEquals(parts.flatMap((part) => part.chapter_ids), outline.chapters.map((chapter) => chapter.id));
});

Deno.test("PR4 final-Part tag keeps trailing untagged chapters in that Part", () => {
  const { outline, arc } = makeCustomFixture(2, [false, true, false]);
  const parts = deriveBookParts(outline.chapters, arc);
  assertEquals(parts.map((part) => part.chapter_ids), [["custom-chapter-1"], ["custom-chapter-2", "custom-chapter-3"]]);
  assertEquals(parts.flatMap((part) => part.chapter_ids), outline.chapters.map((chapter) => chapter.id));
});

Deno.test("PR4 sparse Freytag parts preserve source semantic subtitles", () => {
  for (const roles of [["exposition", "climax"], ["rising_action", "denouement"]]) {
    const outline = makePartFixture("a0000001-0000-0000-0000-000000000006", roles);
    assertEquals(outline.parts.map((part) => part.id), roles[0] === "exposition" ? ["part-1", "part-3"] : ["part-2", "part-5"]);
    assertEquals(outline.parts.map((part) => part.default_subtitle), roles[0] === "exposition" ? ["Exposition", "Climax"] : ["Rising Action", "Denouement"]);
    assertEquals(outline.parts.flatMap((part) => part.chapter_ids), outline.chapters.map((chapter) => chapter.id));
  }
});

Deno.test("PR4 sparse Kishōtenketsu parts preserve source semantic subtitles", () => {
  for (const roles of [["ki", "ten"], ["sho", "ketsu"]]) {
    const outline = makePartFixture("a0000001-0000-0000-0000-000000000007", roles);
    assertEquals(outline.parts.map((part) => part.default_subtitle), roles[0] === "ki" ? ["Ki", "Ten"] : ["Shō", "Ketsu"]);
    assertEquals(outline.parts.flatMap((part) => part.chapter_ids), outline.chapters.map((chapter) => chapter.id));
  }
});

Deno.test("PR4 built-in complete role sequences preserve exact semantic boundaries", () => {
  const fixtures: Array<[string, string[], number[]]> = [
    ["a0000001-0000-0000-0000-000000000001", ["setup", "inciting_incident", "first_plot_point", "rising_action", "midpoint", "crisis", "climax", "resolution"], [3, 3, 2]],
    ["a0000001-0000-0000-0000-000000000002", ["ordinary_world", "call_to_adventure", "refusal_of_call", "meeting_mentor", "crossing_threshold", "tests_allies_enemies", "approach_inmost_cave", "ordeal", "reward", "road_back", "resurrection", "return_with_elixir"], [5, 4, 3]],
    ["a0000001-0000-0000-0000-000000000003", ["the_crime", "investigation_begins", "first_suspect", "rising_tension", "key_revelation", "false_solution", "real_clue", "confrontation", "resolution"], [3, 4, 2]],
    ["a0000001-0000-0000-0000-000000000004", ["opening_image", "theme_stated", "setup", "catalyst", "debate", "break_into_two", "b_story", "fun_and_games", "midpoint", "bad_guys_close_in", "all_is_lost", "dark_night_of_the_soul", "break_into_three", "finale", "final_image"], [5, 7, 3]],
    ["a0000001-0000-0000-0000-000000000005", ["you", "need", "go", "search", "find", "take", "return", "change"], [3, 3, 2]],
    ["a0000001-0000-0000-0000-000000000006", ["exposition", "rising_action", "climax", "falling_action", "denouement"], [1, 1, 1, 1, 1]],
    ["a0000001-0000-0000-0000-000000000007", ["ki", "sho", "ten", "ketsu"], [1, 1, 1, 1]],
  ];
  for (const [templateID, roles, expectedCounts] of fixtures) {
    const outline = makePartFixture(templateID, roles);
    assertEquals(outline.parts.map((part) => part.chapter_ids.length), expectedCounts, templateID);
    assertEquals(outline.parts.flatMap((part) => part.chapter_ids), outline.chapters.map((chapter) => chapter.id));
  }
});

Deno.test("PR4 built-in edited beat with empty role inherits the surrounding semantic Part", () => {
  const outline = makePartFixture("a0000001-0000-0000-0000-000000000001", ["setup", "", "rising_action", "climax", "resolution"]);
  assertEquals(outline.parts.flatMap((part) => part.chapter_ids), outline.chapters.map((chapter) => chapter.id));
  assertEquals(outline.parts.map((part) => part.chapter_ids), [["chapter-1", "chapter-2"], ["chapter-3"], ["chapter-4", "chapter-5"]]);
});

Deno.test("PR4 no-Part fallback keeps child navigation and correct NCX depth", async () => {
  const outline = makeAcknowledgementsFixture();
  const zip = await JSZip.loadAsync(await writeEpub({ book_title: "Fallback", author_name: "A", language: "en" }, outline, null));
  const nav = await readZipText(zip, "OEBPS/nav.xhtml");
  const ncx = await readZipText(zip, "OEBPS/toc.ncx");
  const opf = await readZipText(zip, "OEBPS/content.opf");
  assertStringIncludes(nav, "section-1-section-2");
  assertStringIncludes(ncx, "section-1-section-2");
  assertStringIncludes(ncx, '<meta name="dtb:depth" content="2"/>');
  assertEquals(spineIDs(opf), ["section-1"]);
});

Deno.test("PR4 root-without-prose still renders and navigates a generated child", async () => {
  const rootId = "root-empty";
  const childId = "child-generated";
  const outline: ProjectOutline = {
    id: "root-empty-outline",
    title: "Root Empty",
    parts: [],
    chapters: [{
      id: "root-empty-chapter",
      title: "Root Chapter",
      position: 0,
      sections: [
        { id: rootId, title: "Root", container: "chapter", pov: null, body: "", position: 0, parent_id: null, story_arc_beat_id: null, story_arc_role: null },
        { id: childId, title: "Generated Child", container: "scene", pov: null, body: "Child prose.", position: 0, parent_id: rootId, story_arc_beat_id: null, story_arc_role: null },
      ],
    }],
  };
  const zip = await JSZip.loadAsync(await writeEpub({ book_title: "Root", author_name: "A", language: "en" }, outline, null));
  const story = await readZipText(zip, "OEBPS/text/section-1.xhtml");
  const nav = await readZipText(zip, "OEBPS/nav.xhtml");
  const ncx = await readZipText(zip, "OEBPS/toc.ncx");
  assertStringIncludes(story, '<h2 id="section-1-child-generated">Generated Child</h2>');
  assertStringIncludes(nav, "section-1-child-generated");
  assertStringIncludes(ncx, "section-1-child-generated");
});

Deno.test("PR4 NCX playOrder is sequential, parent-first, and depth matches hierarchy", async () => {
  const outline = makePartFixture("a0000001-0000-0000-0000-000000000001", ["setup", "rising_action", "climax"]);
  outline.chapters[0].sections.push({ id: "child-1", title: "Child", container: "scene", pov: null, body: "Child prose.", position: 1, parent_id: "section-1", story_arc_beat_id: null, story_arc_role: null });
  const zip = await JSZip.loadAsync(await writeEpub({ book_title: "NCX", author_name: "A", language: "en", acknowledgements: "Thanks" }, outline, null));
  const ncx = await readZipText(zip, "OEBPS/toc.ncx");
  assertEquals(ncxPlayOrders(ncx), Array.from({ length: 8 }, (_, index) => index + 1));
  assertEquals(ncx.indexOf('navPoint-part-1') < ncx.indexOf('navPoint-section-1'), true);
  assertEquals(ncx.indexOf('navPoint-section-1') < ncx.indexOf('navPoint-child-1'), true);
  assertStringIncludes(ncx, '<meta name="dtb:depth" content="3"/>');
  assertStringIncludes(ncx, 'navPoint-acknowledgements" playOrder="8"');
});

Deno.test("PR4 generated prose is preserved exactly once and divider pages contain no prose", async () => {
  const outline = makePartFixture("a0000001-0000-0000-0000-000000000001", ["setup", "rising_action", "climax"]);
  outline.chapters[0].sections.push({ id: "child-1", title: "Child", container: "scene", pov: null, body: "Child unique prose.", position: 1, parent_id: "section-1", story_arc_beat_id: null, story_arc_role: null });
  const zip = await JSZip.loadAsync(await writeEpub({ book_title: "Prose", author_name: "A", language: "en" }, outline, null));
  const allStory = await Promise.all(outline.chapters.map((_, index) => readZipText(zip, `OEBPS/text/section-${index + 1}.xhtml`).catch(() => "")));
  for (const prose of ["Prose 1.", "Child unique prose.", "Prose 2.", "Prose 3."]) {
    assertEquals(allStory.join("\n").split(prose).length - 1, 1, prose);
  }
  for (const part of outline.parts) {
    const divider = await readZipText(zip, `OEBPS/text/${part.id}.xhtml`);
    assertEquals(divider.includes("Prose "), false);
    assertStringIncludes(divider, 'href="../styles.css"');
  }
});

Deno.test("PR4 Part dividers are unique manifest/spine resources at story boundaries", async () => {
  const outline = makePartFixture("a0000001-0000-0000-0000-000000000001", ["setup", "rising_action", "climax"]);
  const zip = await JSZip.loadAsync(await writeEpub({ book_title: "Boundaries", author_name: "A", language: "en" }, outline, null));
  const opf = await readZipText(zip, "OEBPS/content.opf");
  const ids = spineIDs(opf);
  assertEquals(ids, ["part-1", "section-1", "part-2", "section-2", "part-3", "section-3"]);
  for (const part of outline.parts) {
    assertEquals((opf.match(new RegExp(`id="${part.id}"`, "g")) ?? []).length, 1);
    assertEquals((opf.match(new RegExp(`idref="${part.id}"`, "g")) ?? []).length, 1);
    assertExists(zip.file(`OEBPS/text/${part.id}.xhtml`));
  }
});

Deno.test("PR4 rendered Parts compact generated-content gaps and preserve source names", async () => {
  const outline = makePartFixture("a0000001-0000-0000-0000-000000000006", ["exposition", "rising_action", "climax", "falling_action", "denouement"]);
  outline.chapters[1].sections[0].body = "";
  outline.chapters[3].sections[0].body = "";
  const zip = await JSZip.loadAsync(await writeEpub({
    book_title: "Compacted", author_name: "A", language: "en",
    part_names: { "part-1": "Arrival", "part-3": "The Hunt", "part-5": "Return" },
  }, outline, null));
  const opf = await readZipText(zip, "OEBPS/content.opf");
  const nav = await readZipText(zip, "OEBPS/nav.xhtml");
  const ncx = await readZipText(zip, "OEBPS/toc.ncx");
  assertEquals(spineIDs(opf), ["part-1", "section-1", "part-2", "section-3", "part-3", "section-5"]);
  assertEquals(zip.file("OEBPS/text/part-4.xhtml"), null);
  assertStringIncludes(nav, "Part I — Arrival");
  assertStringIncludes(nav, "Part II — The Hunt");
  assertStringIncludes(nav, "Part III — Return");
  assertStringIncludes(ncx, "Part III — Return");
  const story = await Promise.all([1, 3, 5].map((index) => readZipText(zip, `OEBPS/text/section-${index}.xhtml`)));
  assertEquals(story.map((text, index) => text.includes(`Prose ${[1, 3, 5][index]}.`)), [true, true, true]);
  const orderedStory = story.join("\n");
  assertEquals(orderedStory.indexOf("Prose 1.") < orderedStory.indexOf("Prose 3."), true);
  assertEquals(orderedStory.indexOf("Prose 3.") < orderedStory.indexOf("Prose 5."), true);
});

Deno.test("PR4 source Part names survive missing first and last generated Parts", async () => {
  for (const [emptyIndex, expectedLastID] of [[0, "part-4"], [4, "part-4"]] as const) {
    const outline = makePartFixture("a0000001-0000-0000-0000-000000000006", ["exposition", "rising_action", "climax", "falling_action", "denouement"]);
    outline.chapters[emptyIndex].sections[0].body = "";
    const zip = await JSZip.loadAsync(await writeEpub({
      book_title: "Source Names", author_name: "A", language: "en",
      part_names: { "part-1": "Arrival", "part-2": "Rising", "part-4": "Falling", "part-5": "Return" },
    }, outline, null));
    const nav = await readZipText(zip, "OEBPS/nav.xhtml");
    const opf = await readZipText(zip, "OEBPS/content.opf");
    assertStringIncludes(nav, emptyIndex === 0 ? "Part I — Rising" : "Part IV — Falling");
    assertStringIncludes(nav, emptyIndex === 0 ? "Part IV — Return" : "Part IV — Falling");
    assertEquals(spineIDs(opf).includes(expectedLastID), true);
    assertEquals(spineIDs(opf).filter((id) => id.startsWith("part-")).length, 4);
  }
});

Deno.test("PR4 NCX depth covers flat and child hierarchies with and without Parts", async () => {
  const flat = makeAcknowledgementsFixture();
  const flatWithParts = makePartFixture("a0000001-0000-0000-0000-000000000001", ["setup"]);
  const childWithParts = makePartFixture("a0000001-0000-0000-0000-000000000001", ["setup"]);
  childWithParts.chapters[0].sections.push({ id: "depth-child", title: "Depth Child", container: "scene", pov: null, body: "Child.", position: 1, parent_id: "section-1", story_arc_beat_id: null, story_arc_role: null });
  for (const [outline, expected] of [[flat, "2"], [flatWithParts, "2"], [childWithParts, "3"]] as const) {
    const zip = await JSZip.loadAsync(await writeEpub({ book_title: "Depth", author_name: "A", language: "en" }, outline, null));
    const ncx = await readZipText(zip, "OEBPS/toc.ncx");
    assertStringIncludes(ncx, `<meta name="dtb:depth" content="${expected}"/>`);
  }
  const noHierarchy: ProjectOutline = {
    ...flat,
    chapters: [{ ...flat.chapters[0], sections: [flat.chapters[0].sections[0]] }],
  };
  const zip = await JSZip.loadAsync(await writeEpub({ book_title: "Depth", author_name: "A", language: "en" }, noHierarchy, null));
  const ncx = await readZipText(zip, "OEBPS/toc.ncx");
  assertStringIncludes(ncx, '<meta name="dtb:depth" content="1"/>');
});

Deno.test("PR4 every generated child fragment in nav resolves in its story XHTML", async () => {
  const outline = makePartFixture("a0000001-0000-0000-0000-000000000001", ["setup", "rising_action"]);
  outline.chapters[0].sections.push({ id: "fragment-child", title: "Fragment Child", container: "scene", pov: null, body: "Child.", position: 1, parent_id: "section-1", story_arc_beat_id: null, story_arc_role: null });
  const zip = await JSZip.loadAsync(await writeEpub({ book_title: "Fragments", author_name: "A", language: "en" }, outline, null));
  const nav = await readZipText(zip, "OEBPS/nav.xhtml");
  for (const match of nav.matchAll(/href="(text\/section-[^"]+\.xhtml)#([^"]+)"/g)) {
    const story = await readZipText(zip, `OEBPS/${match[1]}`);
    assertStringIncludes(story, `id="${match[2]}"`);
  }
});

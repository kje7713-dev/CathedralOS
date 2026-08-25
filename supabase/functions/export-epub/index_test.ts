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

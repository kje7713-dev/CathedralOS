// =============================================================================
// _shared/_operator_alert_test.ts
//
// Unit tests for the operator email alert module. No real Resend calls —
// fetch is injected. No real DB calls — rpcClient is injected.
// =============================================================================

import {
  assertEquals,
  assertStringIncludes,
} from "https://deno.land/std@0.208.0/assert/mod.ts";
import {
  notifyProviderBillingUnavailable,
  type OperatorAlertDeps,
  type ProviderBillingUnavailableContext,
} from "./_operator_alert.ts";

interface CapturedRequest {
  url: string;
  init: RequestInit;
  body: Record<string, unknown>;
}

function makeFetchStub(): {
  fetchImpl: typeof fetch;
  getCaptured: () => CapturedRequest[];
  setResponder: (
    responder: (url: string, init: RequestInit) => Response,
  ) => void;
} {
  const captured: CapturedRequest[] = [];
  let responder: (url: string, init: RequestInit) => Response = () =>
    new Response("{}", { status: 200 });
  const fetchImpl: typeof fetch = (input, init) => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.toString()
      : input.url;
    const bodyText = init?.body ? String(init.body) : "{}";
    let parsed: Record<string, unknown> = {};
    try {
      parsed = JSON.parse(bodyText) as Record<string, unknown>;
    } catch {
      parsed = { _raw: bodyText };
    }
    captured.push({ url, init: init ?? {}, body: parsed });
    return Promise.resolve(responder(url, init ?? {}));
  };
  return {
    fetchImpl,
    getCaptured: () => captured,
    setResponder: (r) => {
      responder = r;
    },
  };
}

interface RpcCall {
  name: string;
  params: Record<string, unknown>;
}

function makeRpcStub(
  dedupeReturn: boolean,
  outcomeError?: string,
): { rpcClient: unknown; calls: RpcCall[] } {
  const calls: RpcCall[] = [];
  const rpcClient = {
    rpc: (name: string, params: Record<string, unknown>) => {
      calls.push({ name, params });
      if (name === "should_send_provider_billing_alert") {
        return Promise.resolve({
          data: dedupeReturn ? "claim-token-1" : null,
          error: null,
        });
      }
      if (name === "record_provider_billing_alert_outcome") {
        return Promise.resolve({
          data: null,
          error: outcomeError ? { message: outcomeError } : null,
        });
      }
      return Promise.resolve({ data: null, error: { message: "unknown_rpc" } });
    },
  };
  return { rpcClient, calls };
}

function baseContext(): ProviderBillingUnavailableContext {
  return {
    stableCode: "provider_billing_unavailable",
    upstreamProviderCode: "credit_balance_exhausted",
    upstreamMessage: "You have no credits remaining on this account.",
    upstreamStatus: 429,
    providerModel: "gpt-5.6-luna",
    selectedModel: "gpt-5.6-luna",
    requestID: "req-abc-123",
    chapterRunID: "576e8dcc-1111-2222-3333-444455556666",
    outlineID: "outline-xyz",
    projectID: "project-foo",
    environment: "production",
  };
}

const baseEnv = {
  RESEND_API_KEY: "re_test_key_abcdef",
  OPERATOR_ALERT_EMAIL: "ops@cathedralos.example",
  OPERATOR_ALERT_FROM_EMAIL: "alerts@cathedralos.example",
};

Deno.test("notifyProviderBillingUnavailable: missing env vars skips send + records skipped outcome", async () => {
  const stub = makeFetchStub();
  const { rpcClient, calls } = makeRpcStub(true);
  const deps: OperatorAlertDeps = {
    fetchImpl: stub.fetchImpl,
    getEnv: () => undefined,
    rpcClient,
    now: () => new Date("2026-09-21T09:23:00Z"),
  };
  const outcome = await notifyProviderBillingUnavailable(baseContext(), deps);
  assertEquals(outcome.attempted, false);
  assertEquals(outcome.sent, false);
  assertEquals(outcome.status, "skipped");
  assertEquals(
    stub.getCaptured().length,
    0,
    "must not call Resend when env missing",
  );
  const outcomeCall = calls.find((c) =>
    c.name === "record_provider_billing_alert_outcome"
  );
  assertEquals(outcomeCall, undefined);
});

Deno.test("notifyProviderBillingUnavailable: dedupe RPC returns false → no Resend call", async () => {
  const stub = makeFetchStub();
  const { rpcClient } = makeRpcStub(false);
  const deps: OperatorAlertDeps = {
    fetchImpl: stub.fetchImpl,
    getEnv: (k) => baseEnv[k as keyof typeof baseEnv],
    rpcClient,
    now: () => new Date("2026-09-21T09:23:00Z"),
  };
  const outcome = await notifyProviderBillingUnavailable(baseContext(), deps);
  assertEquals(outcome.attempted, false);
  assertEquals(outcome.deduped, true);
  assertEquals(outcome.sent, false);
  assertEquals(stub.getCaptured().length, 0);
});

Deno.test("notifyProviderBillingUnavailable: dedupe RPC returns true → Resend called with sanitized body", async () => {
  const stub = makeFetchStub();
  stub.setResponder(() => new Response('{"id":"email_123"}', { status: 200 }));
  const { rpcClient } = makeRpcStub(true);
  const deps: OperatorAlertDeps = {
    fetchImpl: stub.fetchImpl,
    getEnv: (k) => baseEnv[k as keyof typeof baseEnv],
    rpcClient,
    now: () => new Date("2026-09-21T09:23:00Z"),
  };
  const context: ProviderBillingUnavailableContext = {
    ...baseContext(),
    upstreamProviderCode: "organization_spend_limit_exceeded",
    upstreamMessage: "The organization spend limit has been reached.",
  };
  const outcome = await notifyProviderBillingUnavailable(context, deps);
  assertEquals(outcome.attempted, true);
  assertEquals(outcome.deduped, false);
  assertEquals(outcome.sent, true);
  assertEquals(outcome.status, "sent");
  const calls = stub.getCaptured();
  assertEquals(calls.length, 1);
  assertStringIncludes(calls[0].url, "https://api.resend.com/emails");
  const headers = calls[0].init.headers as Record<string, string>;
  assertEquals(headers.Authorization, "Bearer re_test_key_abcdef");
  const body = calls[0].body;
  assertEquals(body.subject, "CathedralOS alert: OpenAI billing unavailable");
  assertEquals(body.from, "alerts@cathedralos.example");
  assertEquals(
    JSON.stringify(body.to),
    JSON.stringify(["ops@cathedralos.example"]),
  );
  const text = String(body.text);
  assertStringIncludes(
    text,
    "CathedralOS could not complete a request because the OpenAI organization spending limit was reached.",
  );
  assertStringIncludes(text, "What happened");
  assertStringIncludes(
    text,
    "A CathedralOS AI request was blocked by OpenAI at 2026-09-21T09:23:00.000Z because the organization spending limit was reached.",
  );
  assertStringIncludes(text, "What you need to do");
  assertStringIncludes(
    text,
    "https://platform.openai.com/settings/organization/limits",
  );
  assertStringIncludes(text, "The user saw: “Temporarily unavailable — try again later.”");
  assertStringIncludes(text, "No customer credits were charged for the failed provider call.");
  assertEquals(text.includes("Suggest Sections"), false);
  assertStringIncludes(text, "Technical details");
  assertStringIncludes(text, "Provider: OpenAI");
  assertStringIncludes(text, "Model: gpt-5.6-luna");
  assertStringIncludes(text, "HTTP status: 429");
  assertStringIncludes(text, "Provider code: organization_spend_limit_exceeded");
  assertStringIncludes(text, "Environment: production");
  assertStringIncludes(text, "Upstream message: The organization spend limit has been reached.");
  assertStringIncludes(text, "Chapter run ID: 576e8dcc-1111-2222-3333-444455556666");
  assertStringIncludes(text, "Automatic retry was suppressed");
  assertEquals(text.includes("RESEND_API_KEY"), false);
  assertEquals(text.includes("re_test_key"), false);
});

Deno.test("notifyProviderBillingUnavailable: Resend 4xx → sent=false, status=failed, never throws", async () => {
  const stub = makeFetchStub();
  stub.setResponder(() => new Response("forbidden", { status: 403 }));
  const { rpcClient, calls } = makeRpcStub(true);
  const deps: OperatorAlertDeps = {
    fetchImpl: stub.fetchImpl,
    getEnv: (k) => baseEnv[k as keyof typeof baseEnv],
    rpcClient,
    now: () => new Date("2026-09-21T09:23:00Z"),
  };
  const outcome = await notifyProviderBillingUnavailable(baseContext(), deps);
  assertEquals(outcome.attempted, true);
  assertEquals(outcome.sent, false);
  assertEquals(outcome.status, "failed");
  assertEquals(outcome.error, "HTTP 403");
  assertEquals(stub.getCaptured().length, 1);
  const outcomeCall = calls.find((c) =>
    c.name === "record_provider_billing_alert_outcome"
  );
  assertEquals(outcomeCall?.params.p_status, "failed");
  assertEquals(outcomeCall?.params.p_claim_token, "claim-token-1");
  assertEquals(outcomeCall?.params.p_error, "HTTP 403");
});

Deno.test("notifyProviderBillingUnavailable: Resend fetch throws → never propagates to caller", async () => {
  const fetchImpl: typeof fetch = () => {
    throw new Error("network unreachable");
  };
  // deno-lint-ignore no-explicit-any
  void (fetchImpl as any);
  const { rpcClient } = makeRpcStub(true);
  const deps: OperatorAlertDeps = {
    fetchImpl,
    getEnv: (k) => baseEnv[k as keyof typeof baseEnv],
    rpcClient,
    now: () => new Date("2026-09-21T09:23:00Z"),
  };
  const outcome = await notifyProviderBillingUnavailable(baseContext(), deps);
  assertEquals(outcome.attempted, true);
  assertEquals(outcome.sent, false);
  assertEquals(outcome.status, "failed");
  assertEquals(outcome.error, "network unreachable");
});

Deno.test("notifyProviderBillingUnavailable: dedupe RPC throws → fail closed, no Resend call (v2 #3)", async () => {
  const stub = makeFetchStub();
  // Resend would return 200 if called — proves the test is asserting
  // that the alert path never reaches Resend when dedupe infrastructure
  // is degraded (otherwise this stub's response would be captured).
  stub.setResponder(() => new Response('{"id":"email_xyz"}', { status: 200 }));
  const rpcClient = {
    rpc: (_name: string, _params: Record<string, unknown>) =>
      Promise.reject(new Error("connection reset")),
  };
  const deps: OperatorAlertDeps = {
    fetchImpl: stub.fetchImpl,
    getEnv: (k) => baseEnv[k as keyof typeof baseEnv],
    rpcClient,
    now: () => new Date("2026-09-21T09:23:00Z"),
  };
  const outcome = await notifyProviderBillingUnavailable(baseContext(), deps);
  // Fail-closed contract: dedupe RPC throws → no Resend call, status=skipped.
  assertEquals(outcome.attempted, false);
  assertEquals(outcome.sent, false);
  assertEquals(outcome.status, "skipped");
  assertEquals(
    stub.getCaptured().length,
    0,
    "Resend must NOT be called when dedupe RPC throws",
  );
});

Deno.test("notifyProviderBillingUnavailable: missing rpcClient → fail closed, no Resend call (v2 #3)", async () => {
  const stub = makeFetchStub();
  stub.setResponder(() => new Response('{"id":"email_xyz"}', { status: 200 }));
  const deps: OperatorAlertDeps = {
    fetchImpl: stub.fetchImpl,
    getEnv: (k) => baseEnv[k as keyof typeof baseEnv],
    // Note: no rpcClient — must NOT result in any Resend call.
    now: () => new Date("2026-09-21T09:23:00Z"),
  };
  const outcome = await notifyProviderBillingUnavailable(baseContext(), deps);
  // Fail-closed contract: missing rpcClient → no Resend call, status=skipped.
  assertEquals(outcome.attempted, false);
  assertEquals(outcome.sent, false);
  assertEquals(outcome.status, "skipped");
  assertEquals(
    stub.getCaptured().length,
    0,
    "Resend must NOT be called when rpcClient is missing",
  );
});

Deno.test("notifyProviderBillingUnavailable: subject + body do not leak upstream message verbatim", async () => {
  const ctx: ProviderBillingUnavailableContext = {
    ...baseContext(),
    upstreamMessage: "line1\nline2\r\nline3 " + "x".repeat(800),
  };
  const stub = makeFetchStub();
  stub.setResponder(() => new Response('{"id":"email_xyz"}', { status: 200 }));
  const { rpcClient } = makeRpcStub(true);
  const deps: OperatorAlertDeps = {
    fetchImpl: stub.fetchImpl,
    getEnv: (k) => baseEnv[k as keyof typeof baseEnv],
    rpcClient,
    now: () => new Date("2026-09-21T09:23:00Z"),
  };
  await notifyProviderBillingUnavailable(ctx, deps);
  const body = stub.getCaptured()[0].body;
  const text = String(body.text);
  assertEquals(text.includes("\nline2"), false);
  assertEquals(text.length <= 8000, true);
  assertEquals(String(body.subject).includes("\n"), false);
  assertEquals(String(body.subject).includes("\r"), false);
});

Deno.test("notifyProviderBillingUnavailable: subject + body keep operator-facing details", async () => {
  // The spec forbids the public customer-facing message from leaking provider
  // / billing / quota / organization / API-key wording. The operator email
  // is internal — it SHOULD surface those details so the on-call knows what
  // to investigate. The forbidden wording applies to providerErrorResponse in
  // generate-story (user-facing surface), not to this alert body.
  const stub = makeFetchStub();
  stub.setResponder(() => new Response('{"id":"email_xyz"}', { status: 200 }));
  const { rpcClient } = makeRpcStub(true);
  const deps: OperatorAlertDeps = {
    fetchImpl: stub.fetchImpl,
    getEnv: (k) => baseEnv[k as keyof typeof baseEnv],
    rpcClient,
    now: () => new Date("2026-09-21T09:23:00Z"),
  };
  await notifyProviderBillingUnavailable(baseContext(), deps);
  const call = stub.getCaptured()[0];
  const subject = String(call.body.subject);
  const text = String(call.body.text);
  assertEquals(subject, "CathedralOS alert: OpenAI billing unavailable");
  assertEquals(text.includes("organization spending limit was reached"), false);
  assertStringIncludes(text, "account/API credit balance is exhausted");
  assertEquals(text.includes("Suggest Sections"), false);
  // Technical details remain available to the operator below the human-readable
  // incident summary.
  assertStringIncludes(text, "Provider code: credit_balance_exhausted");
  assertStringIncludes(text, "HTTP status: 429");
  assertStringIncludes(text, "Model: gpt-5.6-luna");
  assertStringIncludes(text, "Environment: production");
  assertStringIncludes(text, "No customer credits were charged for the failed provider call.");
  // Body MUST NOT contain the secret API key in any form.
  assertEquals(text.includes("RE_test_key"), false);
  assertEquals(text.includes("re_test_key"), false);
});

Deno.test("notifyProviderBillingUnavailable: unknown provider code uses generic billing guidance", async () => {
  const stub = makeFetchStub();
  stub.setResponder(() => new Response('{"id":"email_unknown"}', { status: 200 }));
  const { rpcClient } = makeRpcStub(true);
  const deps: OperatorAlertDeps = {
    fetchImpl: stub.fetchImpl,
    getEnv: (k) => baseEnv[k as keyof typeof baseEnv],
    rpcClient,
    now: () => new Date("2026-09-21T09:23:00Z"),
  };
  await notifyProviderBillingUnavailable({
    ...baseContext(),
    upstreamProviderCode: "some_future_billing_code",
    upstreamMessage: "Provider billing is unavailable.",
  }, deps);
  const body = stub.getCaptured()[0].body;
  const text = String(body.text);
  assertEquals(body.subject, "CathedralOS alert: OpenAI billing unavailable");
  assertStringIncludes(
    text,
    "OpenAI rejected the request because provider billing is unavailable.",
  );
  assertStringIncludes(
    text,
    "Review the OpenAI account billing configuration and available credits.",
  );
  assertEquals(text.includes("organization spending limit was reached"), false);
  assertEquals(text.includes("Suggest Sections"), false);
});

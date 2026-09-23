import {
  assertEquals,
  assertExists,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  type ExportMetadataRow,
  handleDeleteRequest,
  type TransactionalDeleteResult,
} from "./index.ts";

const USER = "11111111-1111-1111-1111-111111111111";
const OTHER = "22222222-2222-2222-2222-222222222222";
const ID = "33333333-3333-3333-3333-333333333333";
const PROJECT = "44444444-4444-4444-4444-444444444444";

function row(overrides: Partial<ExportMetadataRow> = {}): ExportMetadataRow {
  return {
    id: ID,
    project_id: PROJECT,
    book_title: "A",
    author_name: "Author",
    epub_storage_path: "exports/a.epub",
    is_current: true,
    is_active: true,
    exported_by_user_id: USER,
    ...overrides,
  };
}

function clients(options: {
  userId?: string | null;
  authError?: string;
  row?: ExportMetadataRow | null;
  lookupError?: string;
  rpcData?: TransactionalDeleteResult | null;
  rpcError?: { code?: string; message: string } | null;
  storageError?: string;
} = {}) {
  const userClient = {
    auth: {
      getUser: async () => ({
        data: {
          user: options.userId === null ? null : { id: options.userId ?? USER },
        },
        error: options.authError ? { message: options.authError } : null,
      }),
    },
  };
  const chain: Record<string, unknown> = {};
  chain.select = () => chain;
  chain.eq = () => chain;
  chain.maybeSingle = async () => ({
    data: options.row === undefined ? row() : options.row,
    error: options.lookupError ? { message: options.lookupError } : null,
  });
  const adminClient = {
    from: () => chain,
    rpc: async () => ({
      data: options.rpcData === undefined
        ? {
          deleted_export_metadata_id: ID,
          project_id: PROJECT,
          was_current: true,
          promoted_to: null,
          epub_storage_path: "exports/a.epub",
        }
        : options.rpcData,
      error: options.rpcError ?? null,
    }),
    storage: {
      from: () => ({
        remove: async () => ({
          data: options.storageError ? null : [{ name: "exports/a.epub" }],
          error: options.storageError
            ? { message: options.storageError }
            : null,
        }),
      }),
    },
  };
  return { userClient, adminClient } as const;
}

function request(body: unknown, auth = "Bearer jwt"): Request {
  return new Request("https://example.test/functions/v1/export-epub-delete", {
    method: "POST",
    headers: { Authorization: auth, "Content-Type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });
}

async function result(response: Response): Promise<Record<string, unknown>> {
  return await response.json() as Record<string, unknown>;
}

Deno.test("endpoint: missing Authorization -> 401", async () => {
  const c = clients();
  assertEquals(
    (await handleDeleteRequest(
      request({}, ""),
      c.userClient as never,
      c.adminClient as never,
    )).status,
    401,
  );
});

Deno.test("endpoint: invalid JWT -> 401", async () => {
  const c = clients({ userId: null });
  assertEquals(
    (await handleDeleteRequest(
      request({ export_metadata_id: ID }),
      c.userClient as never,
      c.adminClient as never,
    )).status,
    401,
  );
});

Deno.test("endpoint: malformed JSON -> 400", async () => {
  const c = clients();
  assertEquals(
    (await handleDeleteRequest(
      request("{"),
      c.userClient as never,
      c.adminClient as never,
    )).status,
    400,
  );
});

Deno.test("endpoint: missing export id -> 400", async () => {
  const c = clients();
  assertEquals(
    (await handleDeleteRequest(
      request({}),
      c.userClient as never,
      c.adminClient as never,
    )).status,
    400,
  );
});

Deno.test("endpoint: missing row -> 404", async () => {
  const c = clients({ row: null });
  assertEquals(
    (await handleDeleteRequest(
      request({ export_metadata_id: ID }),
      c.userClient as never,
      c.adminClient as never,
    )).status,
    404,
  );
});

Deno.test("endpoint: ownership mismatch -> 403 without RPC", async () => {
  const c = clients({ row: row({ exported_by_user_id: OTHER }) });
  const response = await handleDeleteRequest(
    request({ export_metadata_id: ID }),
    c.userClient as never,
    c.adminClient as never,
  );
  assertEquals(response.status, 403);
});

Deno.test("endpoint: owner historical delete keeps current and returns 200", async () => {
  const c = clients({
    row: row({ is_current: false, book_title: "A" }),
    rpcData: {
      deleted_export_metadata_id: ID,
      project_id: PROJECT,
      was_current: false,
      promoted_to: null,
      epub_storage_path: "exports/a.epub",
    },
  });
  const response = await handleDeleteRequest(
    request({ export_metadata_id: ID }),
    c.userClient as never,
    c.adminClient as never,
  );
  const body = await result(response);
  assertEquals(response.status, 200);
  assertEquals(body.deleted, true);
  assertEquals(body.promoted_to, null);
  assertEquals(body.storage_object_deleted, true);
});

Deno.test("endpoint: owner current delete returns promoted id", async () => {
  const promoted = "55555555-5555-5555-5555-555555555555";
  const c = clients({
    rpcData: {
      deleted_export_metadata_id: ID,
      project_id: PROJECT,
      was_current: true,
      promoted_to: promoted,
      epub_storage_path: "exports/a.epub",
    },
  });
  const response = await handleDeleteRequest(
    request({ export_metadata_id: ID }),
    c.userClient as never,
    c.adminClient as never,
  );
  const body = await result(response);
  assertEquals(response.status, 200);
  assertEquals(body.promoted_to, promoted);
});

Deno.test("endpoint: owner final delete returns 200 with null promotion", async () => {
  const c = clients({
    rpcData: {
      deleted_export_metadata_id: ID,
      project_id: PROJECT,
      was_current: true,
      promoted_to: null,
      epub_storage_path: "exports/a.epub",
    },
  });
  const response = await handleDeleteRequest(
    request({ export_metadata_id: ID }),
    c.userClient as never,
    c.adminClient as never,
  );
  assertEquals(response.status, 200);
  assertEquals((await result(response)).promoted_to, null);
});

Deno.test("endpoint: transactional DB failure -> 500 and no Storage cleanup", async () => {
  const c = clients({
    rpcData: null,
    rpcError: { code: "XX000", message: "transaction failed" },
  });
  const response = await handleDeleteRequest(
    request({ export_metadata_id: ID }),
    c.userClient as never,
    c.adminClient as never,
  );
  assertEquals(response.status, 500);
});

Deno.test("endpoint: successful DB delete + failed Storage cleanup -> 200 false", async () => {
  const c = clients({ storageError: "storage unavailable" });
  const response = await handleDeleteRequest(
    request({ export_metadata_id: ID }),
    c.userClient as never,
    c.adminClient as never,
  );
  const body = await result(response);
  assertEquals(response.status, 200);
  assertEquals(body.deleted, true);
  assertEquals(body.storage_object_deleted, false);
});

Deno.test("endpoint: CORS preflight -> 204", async () => {
  const c = clients();
  const response = await handleDeleteRequest(
    new Request("https://x", { method: "OPTIONS" }),
    c.userClient as never,
    c.adminClient as never,
  );
  assertEquals(response.status, 204);
  assertExists(response.headers.get("Access-Control-Allow-Origin"));
});

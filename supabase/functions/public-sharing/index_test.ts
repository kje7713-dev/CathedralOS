import {
  assert,
  assertEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { epubPublicationOwnerMatches, handler } from "./index.ts";

const OWNER = "11111111-1111-4111-8111-111111111111";
const OTHER = "22222222-2222-2222-2222-222222222222";
const EXPORT_ID = "33333333-3333-4333-8333-333333333333";
const SHARED_ID = "44444444-4444-4444-8444-444444444444";

function request(method: string, path: string, body?: unknown): Request {
  return new Request(`https://example.test/public-sharing${path}`, {
    method,
    headers: { "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
}

function mockClient(options: {
  owner?: string;
  exportOwner?: string;
  active?: boolean;
  contentType?: string;
  visibility?: string;
  unpublishedAt?: string | null;
  existing?: boolean;
  signed?: boolean;
} = {}) {
  const state = {
    owner: options.owner ?? OWNER,
    exportOwner: options.exportOwner ?? OWNER,
    active: options.active ?? true,
    contentType: options.contentType ?? "epub",
    visibility: options.visibility ?? "shared",
    unpublishedAt: options.unpublishedAt ?? null,
    existing: options.existing ?? false,
    signed: options.signed ?? true,
    createdSignedURLCalls: 0,
    writes: [] as Record<string, unknown>[],
  };
  const exportRow = () => ({
    id: EXPORT_ID,
    project_id: "55555555-5555-4555-8555-555555555555",
    book_title: "Canonical Server Title",
    author_name: "Canonical Server Author",
    book_description: "Canonical description",
    epub_storage_path: "exports/book.epub",
    epub_sha256: "sha256",
    is_active: state.active,
    exported_by_user_id: state.exportOwner,
  });
  const sharedRow = () => ({
    id: SHARED_ID,
    owner_user_id: state.owner,
    content_type: state.contentType,
    visibility: state.visibility,
    unpublished_at: state.unpublishedAt,
    export_metadata_id: EXPORT_ID,
  });
  const query = (
    table: string,
    operation = "select",
    value?: Record<string, unknown>,
  ) => {
    const chain: Record<string, unknown> = {};
    chain.select = () => chain;
    chain.eq = () => chain;
    chain.in = () => chain;
    chain.is = () => chain;
    chain.order = () => chain;
    chain.limit = () => chain;
    chain.insert = (row: Record<string, unknown>) => {
      state.writes.push(row);
      state.existing = true;
      return query(table, "insert", row);
    };
    chain.update = (row: Record<string, unknown>) => {
      state.writes.push(row);
      return query(table, "update", row);
    };
    chain.maybeSingle = async () => {
      if (table === "export_metadata") {
        return { data: exportRow(), error: null };
      }
      if (table === "project_snapshots") {
        return {
          data: { snapshot_json: { project: { summary: "Fallback summary" } } },
          error: null,
        };
      }
      if (table === "shared_outputs") {
        return { data: state.existing ? sharedRow() : null, error: null };
      }
      return { data: null, error: null };
    };
    chain.single = async () => {
      if (table === "shared_outputs") {
        return {
          data: {
            id: SHARED_ID,
            visibility: "shared",
            published_at: "2026-09-23T00:00:00Z",
          },
          error: null,
        };
      }
      return { data: null, error: null };
    };
    return chain;
  };
  const storage = {
    from: (bucket: string) => ({
      download: async () => ({ data: new Blob(["not-an-epub"]), error: null }),
      upload: async () => ({ error: null }),
      createSignedUrl: async () => {
        state.createdSignedURLCalls += 1;
        return state.signed
          ? {
            data: { signedUrl: "https://signed.test/book.epub" },
            error: null,
          }
          : { data: null, error: { message: "sign failed" } };
      },
    }),
  };
  return {
    state,
    from: (table: string) => query(table),
    storage,
  } as any;
}

Deno.test("EPUB download provenance accepts matching shared and export owners", () => {
  assertEquals(epubPublicationOwnerMatches(OWNER, OWNER), true);
});

Deno.test("EPUB download provenance rejects cross-owner linkage", () => {
  assertEquals(epubPublicationOwnerMatches(OWNER, OTHER), false);
  assertEquals(epubPublicationOwnerMatches(OWNER, null), false);
  assertEquals(epubPublicationOwnerMatches("", OWNER), false);
});

Deno.test("EPUB publish rejects non-owner and inactive exports", async () => {
  const nonOwner = await handler(
    request("POST", "/shared-outputs/epub", { exportMetadataID: EXPORT_ID }),
    {
      adminClient: mockClient({ exportOwner: OTHER }),
      authenticatedUserId: OWNER,
      supabaseURL: "https://example.test",
    },
  );
  assertEquals(nonOwner.status, 403);

  const inactive = await handler(
    request("POST", "/shared-outputs/epub", { exportMetadataID: EXPORT_ID }),
    {
      adminClient: mockClient({ active: false }),
      authenticatedUserId: OWNER,
      supabaseURL: "https://example.test",
    },
  );
  assertEquals(inactive.status, 410);
});

Deno.test("EPUB publish uses canonical metadata and reuses the same shared row", async () => {
  const client = mockClient();
  const overrides = {
    adminClient: client,
    authenticatedUserId: OWNER,
    supabaseURL: "https://example.test",
    publicShareBaseURL: "https://share.example.test",
  };
  const first = await handler(
    request("POST", "/shared-outputs/epub", { exportMetadataID: EXPORT_ID }),
    overrides,
  );
  const second = await handler(
    request("POST", "/shared-outputs/epub", { exportMetadataID: EXPORT_ID }),
    overrides,
  );
  assertEquals(first.status, 200);
  assertEquals(second.status, 200);
  assertEquals(client.state.existing, true);
  assertEquals(client.state.writes.length >= 2, true);
  assertEquals(client.state.writes[0].share_title, "Canonical Server Title");
  assertEquals(
    client.state.writes[0].book_author_name,
    "Canonical Server Author",
  );
  assertEquals((await first.json()).sharedOutputID, SHARED_ID);
  assertEquals((await second.json()).sharedOutputID, SHARED_ID);
});

Deno.test("valid public EPUB returns a five-minute signed URL", async () => {
  const client = mockClient({ existing: true });
  const response = await handler(
    request("GET", `/shared-outputs/${SHARED_ID}/epub`),
    { adminClient: client, supabaseURL: "https://example.test" },
  );
  assertEquals(response.status, 200);
  assertEquals(
    (await response.json()).signedURL,
    "https://signed.test/book.epub",
  );
  assertEquals(client.state.createdSignedURLCalls, 1);
});

Deno.test("unavailable EPUB states never sign a URL", async () => {
  for (
    const options of [
      { visibility: "private" },
      { contentType: "text" },
      { active: false },
      { owner: OWNER, exportOwner: OTHER },
    ]
  ) {
    const client = mockClient({ ...options, existing: true });
    const response = await handler(
      request("GET", `/shared-outputs/${SHARED_ID}/epub`),
      { adminClient: client, supabaseURL: "https://example.test" },
    );
    assertEquals(response.status, 404);
    assertEquals(client.state.createdSignedURLCalls, 0);
  }
});

Deno.test("unpublished EPUB is unavailable", async () => {
  const client = mockClient({
    unpublishedAt: "2026-09-23T00:00:00Z",
    existing: true,
  });
  const response = await handler(
    request("GET", `/shared-outputs/${SHARED_ID}/epub`),
    { adminClient: client, supabaseURL: "https://example.test" },
  );
  assertEquals(response.status, 404);
  assert(client.state.createdSignedURLCalls === 0);
});

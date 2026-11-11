import { assertEquals } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { type ExportHistoryItem, handleListRequest } from "./index.ts";

const USER = "11111111-1111-1111-1111-111111111111";
const rows: ExportHistoryItem[] = [
  {
    id: "b",
    book_title: "B",
    author_name: "Author",
    is_current: true,
    is_active: true,
    created_at: "2026-09-23T12:00:00Z",
    source_kind: "project",
    source_generation_output_id: null,
  },
  {
    id: "a",
    book_title: "A",
    author_name: "Author",
    is_current: false,
    is_active: true,
    created_at: "2026-09-23T11:00:00Z",
    source_kind: "project",
    source_generation_output_id: null,
  },
];

function client() {
  let publicationFilter: string[] = [];
  const snapshotChain: Record<string, unknown> = {};
  snapshotChain.select = () => snapshotChain;
  snapshotChain.eq = () => snapshotChain;
  snapshotChain.maybeSingle = async () => ({
    data: { id: "snapshot" },
    error: null,
  });
  const exportChain: Record<string, unknown> = {};
  exportChain.select = () => exportChain;
  exportChain.eq = () => exportChain;
  exportChain.order = async () => ({ data: rows, error: null });
  const publicationChain: Record<string, unknown> = {};
  publicationChain.select = () => publicationChain;
  publicationChain.eq = () => publicationChain;
  publicationChain.in = async (_column: string, values: string[]) => {
    publicationFilter = values;
    return { data: [], error: null };
  };
  return {
    auth: {
      getUser: async () => ({ data: { user: { id: USER } }, error: null }),
    },
    from: (table: string) =>
      table === "project_snapshots"
        ? snapshotChain
        : table === "shared_outputs"
        ? publicationChain
        : exportChain,
    publicationFilter: () => publicationFilter,
  } as never;
}

Deno.test("list returns both active historical exports after regeneration", async () => {
  const testClient = client();
  const response = await handleListRequest(
    new Request("https://x", {
      method: "POST",
      headers: {
        Authorization: "Bearer jwt",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ project_id: "local-project" }),
    }),
    testClient,
  );
  assertEquals(response.status, 200);
  assertEquals(
    (testClient as { publicationFilter: () => string[] }).publicationFilter(),
    ["b", "a"],
  );
  assertEquals(await response.json(), {
    exports: rows.map((row) => ({
      ...row,
      shared_output_id: null,
      is_publicly_shared: false,
    })),
  });
});
Deno.test("list rejects missing auth", async () => {
  assertEquals(
    (await handleListRequest(
      new Request("https://x", { method: "POST" }),
      client(),
    )).status,
    401,
  );
});

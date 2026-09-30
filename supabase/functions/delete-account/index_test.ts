import { assertEquals, assertRejects } from "https://deno.land/std@0.224.0/assert/mod.ts";
import { deleteOwnedAccount } from "./index.ts";

function fakeAdmin(overrides: Record<string, unknown> = {}, projectRows: unknown[] = [], listedObjects: Record<string, unknown[]> = {}) {
  const calls: string[] = [];
  const client = {
    calls,
    from(table: string) {
      return {
        select() { return this; },
        eq() { return this; },
        delete() { calls.push(`delete:${table}`); return this; },
        async then(resolve: (value: unknown) => unknown) {
          if (table === "export_metadata") return resolve({ data: [], error: null });
          if (table === "shared_outputs") return resolve({ data: [], error: null });
          if (table === "project_snapshots") return resolve({ data: projectRows, error: null });
          return resolve({ data: null, error: null });
        },
        ...overrides,
      };
    },
    storage: { from(bucket: string) { return {
      async list(path: string) {
        calls.push(`storage:list:${bucket}:${path}`);
        return { data: listedObjects[`${bucket}:${path}`] ?? [], error: null };
      },
      async remove(paths: string[]) { calls.push(`storage:remove:${bucket}:${paths.join(",")}`); return { error: null }; },
    }; } },
    auth: { admin: { async deleteUser(id: string) { calls.push(`auth:${id}`); return { error: null }; } } },
  } as any;
  return client;
}

Deno.test("deleteOwnedAccount deletes explicit non-cascade rows before auth user", async () => {
  const client = fakeAdmin();
  await deleteOwnedAccount(client, "user-1");
  assertEquals(client.calls, ["delete:export_jobs", "delete:export_metadata", "auth:user-1"]);
});

Deno.test("deleteOwnedAccount fails closed when artifact lookup fails", async () => {
  const client = fakeAdmin({
    async then(resolve: (value: unknown) => unknown) {
      return resolve({ data: null, error: { message: "db down" } });
    },
  });
  await assertRejects(() => deleteOwnedAccount(client, "user-1"), Error, "export_metadata_lookup_failed");
  assertEquals(client.calls, []);
});


Deno.test("deleteOwnedAccount removes project-scoped orphan exports and covers", async () => {
  const client = fakeAdmin({}, [{ local_project_id: "local-project-1" }], {
    "exports:exports/local-project-1": [{ name: "orphan.epub" }],
    "covers:exports/local-project-1": [{ name: "cover-old.jpg" }],
  });
  await deleteOwnedAccount(client, "user-1");
  assertEquals(client.calls, [
    "storage:list:exports:exports/local-project-1",
    "storage:list:covers:exports/local-project-1",
    "storage:remove:exports:exports/local-project-1/orphan.epub",
    "storage:remove:covers:exports/local-project-1/cover-old.jpg",
    "delete:export_jobs",
    "delete:export_metadata",
    "auth:user-1",
  ]);
});

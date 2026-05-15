import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const CORS_HEADERS: Record<string, string> = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
};

const UUID_REGEX =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const ALLOWED_ACTIONS = new Set(["generate", "regenerate", "continue", "remix"]);
const ALLOWED_LENGTH_MODES = new Set(["short", "medium", "long", "chapter"]);
const ALLOWED_REPORT_REASONS = new Set([
  "inappropriate_content",
  "copyright_concern",
  "harassment_or_hate",
  "spam",
  "other",
]);

interface PublishRequestBody {
  sharedOutputID?: string;
  cloudGenerationOutputID?: string;
  shareTitle?: string;
  shareExcerpt?: string;
  allowRemix?: boolean;
  outputText?: string;
  sourcePayloadJSON?: unknown;
  sourcePromptPackName?: string;
  modelName?: string;
  generationAction?: string;
  generationLengthMode?: string;
  coverImagePath?: string;
  coverImageURL?: string;
  coverImageWidth?: number;
  coverImageHeight?: number;
  coverImageContentType?: string;
}

interface RemixRequestBody {
  sharedOutputID?: string;
  createdProjectLocalID?: string;
  sourcePayloadJSON?: unknown;
  createdAt?: string;
}

function jsonResponse(payload: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...CORS_HEADERS,
      ...headers,
    },
  });
}

function routePathFromURL(urlString: string): string {
  const pathname = new URL(urlString).pathname;
  const marker = "/public-sharing";
  const markerIndex = pathname.indexOf(marker);
  if (markerIndex < 0) {
    return pathname.replace(/\/+$/, "") || "/";
  }
  const suffix = pathname.slice(markerIndex + marker.length);
  return (suffix.replace(/\/+$/, "") || "/");
}

function isUUID(value: string | undefined | null): value is string {
  return Boolean(value && UUID_REGEX.test(value));
}

function parsePayloadJSON(input: unknown, fallback: unknown = {}): unknown {
  if (typeof input === "string") {
    try {
      return JSON.parse(input);
    } catch {
      return fallback;
    }
  }
  if (input && typeof input === "object") {
    return input;
  }
  return fallback;
}

function deriveAudienceFields(sourcePayloadJSON: unknown): {
  readingLevel: string | null;
  contentRating: string | null;
  audienceNotes: string | null;
} {
  const payload = sourcePayloadJSON as Record<string, unknown> | null;
  const project = payload?.project as Record<string, unknown> | undefined;
  const readingLevel = typeof project?.readingLevel === "string" ? project.readingLevel : null;
  const contentRating = typeof project?.contentRating === "string" ? project.contentRating : null;
  const audienceNotes = typeof project?.audienceNotes === "string" ? project.audienceNotes : null;
  return { readingLevel, contentRating, audienceNotes };
}

async function getAuthenticatedUserId(
  req: Request,
  supabaseURL: string,
  supabaseAnonKey: string,
): Promise<string | null> {
  const authHeader = req.headers.get("Authorization");
  if (!authHeader) return null;

  const userClient = createClient(supabaseURL, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const {
    data: { user },
    error,
  } = await userClient.auth.getUser();
  if (error || !user) return null;
  return user.id;
}

function buildShareURL(baseURL: string | null, sharedOutputID: string): string | null {
  if (!baseURL) return null;
  const trimmed = baseURL.trim().replace(/\/+$/, "");
  if (!trimmed) return null;
  return `${trimmed}/shared/${sharedOutputID}`;
}

function asISOString(value: unknown): string {
  return typeof value === "string" && value ? value : new Date().toISOString();
}

function normalizeOptionalString(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

export async function handler(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (!["GET", "POST", "DELETE"].includes(req.method)) {
    return jsonResponse({ status: "failed", error: "Method not allowed" }, 405);
  }

  const supabaseURL = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseURL || !supabaseAnonKey || !serviceRoleKey) {
    return jsonResponse(
      { status: "failed", errorCode: "backend_config_missing", error: "Server configuration error" },
      500,
    );
  }

  const adminClient = createClient(supabaseURL, serviceRoleKey);
  const authenticatedUserId = await getAuthenticatedUserId(req, supabaseURL, supabaseAnonKey);
  const routePath = routePathFromURL(req.url);
  const segments = routePath.split("/").filter(Boolean);
  const publicShareBaseURL = Deno.env.get("PUBLIC_SHARE_WEB_BASE_URL") ?? null;

  const requireUser = (): string | Response =>
    authenticatedUserId ?? jsonResponse(
      { status: "failed", errorCode: "unauthenticated", error: "Unauthorized" },
      401,
    );

  if (req.method === "GET" && routePath === "/shared-outputs") {
    const { data, error } = await adminClient
      .from("shared_outputs")
      .select(
        "id, owner_user_id, share_title, share_excerpt, allow_remix, source_payload_json, generation_length_mode, published_at, created_at, cover_image_path, cover_image_url, cover_image_width, cover_image_height, cover_image_content_type",
      )
      .in("visibility", ["shared", "unlisted"])
      .is("unpublished_at", null)
      .order("published_at", { ascending: false })
      .limit(100);

    if (error) {
      console.error("[public-sharing] list shared outputs error:", error);
      return jsonResponse({ status: "failed", error: "Could not load shared outputs" }, 500);
    }

    const rows = (data ?? []) as Array<Record<string, unknown>>;
    const ownerIds = [...new Set(rows.map((row) => row.owner_user_id).filter((id): id is string => typeof id === "string"))];
    let displayNameByUserId = new Map<string, string>();

    if (ownerIds.length > 0) {
      const { data: profileRows } = await adminClient
        .from("profiles")
        .select("id, display_name")
        .in("id", ownerIds);
      displayNameByUserId = new Map(
        ((profileRows ?? []) as Array<Record<string, unknown>>)
          .filter((row) => typeof row.id === "string" && typeof row.display_name === "string")
          .map((row) => [row.id as string, row.display_name as string]),
      );
    }

    const items = rows.map((row) => {
      const sourcePayload = row.source_payload_json as unknown;
      const audience = deriveAudienceFields(sourcePayload);
      const ownerUserID = typeof row.owner_user_id === "string" ? row.owner_user_id : "";
      return {
        sharedOutputID: String(row.id ?? ""),
        shareTitle: typeof row.share_title === "string" ? row.share_title : "",
        shareExcerpt: typeof row.share_excerpt === "string" ? row.share_excerpt : "",
        authorDisplayName: displayNameByUserId.get(ownerUserID) ?? null,
        createdAt: typeof row.published_at === "string" ? row.published_at : asISOString(row.created_at),
        allowRemix: Boolean(row.allow_remix),
        generationLengthMode: typeof row.generation_length_mode === "string" ? row.generation_length_mode : null,
        contentRating: audience.contentRating,
        readingLevel: audience.readingLevel,
        coverImagePath: typeof row.cover_image_path === "string" ? row.cover_image_path : null,
        coverImageURL: typeof row.cover_image_url === "string" ? row.cover_image_url : null,
        coverImageWidth: typeof row.cover_image_width === "number" ? row.cover_image_width : null,
        coverImageHeight: typeof row.cover_image_height === "number" ? row.cover_image_height : null,
        coverImageContentType: typeof row.cover_image_content_type === "string" ? row.cover_image_content_type : null,
      };
    });

    return jsonResponse({ items }, 200);
  }

  if (req.method === "GET" && segments[0] === "shared-outputs" && segments.length === 2) {
    const sharedOutputID = segments[1];
    if (!isUUID(sharedOutputID)) {
      return jsonResponse({ status: "failed", error: "Invalid shared output ID" }, 400);
    }

    const { data, error } = await adminClient
      .from("shared_outputs")
      .select("*")
      .eq("id", sharedOutputID)
      .maybeSingle();

    if (error) {
      console.error("[public-sharing] detail error:", error);
      return jsonResponse({ status: "failed", error: "Could not load shared output" }, 500);
    }
    if (!data) {
      return jsonResponse({ status: "failed", error: "Shared output not found" }, 404);
    }

    const ownerUserID = String((data as Record<string, unknown>).owner_user_id ?? "");
    const visibility = String((data as Record<string, unknown>).visibility ?? "private");
    const unpublishedAt = (data as Record<string, unknown>).unpublished_at;
    const isPublicVisible = (visibility === "shared" || visibility === "unlisted") && !unpublishedAt;
    const isOwner = authenticatedUserId === ownerUserID;
    if (!isPublicVisible && !isOwner) {
      return jsonResponse({ status: "failed", error: "Shared output not found" }, 404);
    }

    const { data: profileData } = ownerUserID
      ? await adminClient.from("profiles").select("display_name").eq("id", ownerUserID).maybeSingle()
      : { data: null };

    const sourcePayload = (data as Record<string, unknown>).source_payload_json;
    const audience = deriveAudienceFields(sourcePayload);
    const allowRemix = Boolean((data as Record<string, unknown>).allow_remix);

    return jsonResponse(
      {
        sharedOutputID: String((data as Record<string, unknown>).id ?? ""),
        shareTitle: typeof (data as Record<string, unknown>).share_title === "string"
          ? (data as Record<string, unknown>).share_title
          : "",
        shareExcerpt: typeof (data as Record<string, unknown>).share_excerpt === "string"
          ? (data as Record<string, unknown>).share_excerpt
          : "",
        outputText: typeof (data as Record<string, unknown>).output_text === "string"
          ? (data as Record<string, unknown>).output_text
          : "",
        authorDisplayName: typeof (profileData as Record<string, unknown> | null)?.display_name === "string"
          ? (profileData as Record<string, unknown>).display_name
          : null,
        ownerUserID,
        sourcePromptPackName: typeof (data as Record<string, unknown>).source_prompt_pack_name === "string"
          ? (data as Record<string, unknown>).source_prompt_pack_name
          : null,
        modelName: typeof (data as Record<string, unknown>).model_name === "string"
          ? (data as Record<string, unknown>).model_name
          : null,
        generationAction: typeof (data as Record<string, unknown>).generation_action === "string"
          ? (data as Record<string, unknown>).generation_action
          : null,
        generationLengthMode: typeof (data as Record<string, unknown>).generation_length_mode === "string"
          ? (data as Record<string, unknown>).generation_length_mode
          : null,
        allowRemix,
        createdAt: asISOString(
          (data as Record<string, unknown>).published_at ?? (data as Record<string, unknown>).created_at,
        ),
        shareURL: buildShareURL(publicShareBaseURL, sharedOutputID),
        readingLevel: audience.readingLevel,
        contentRating: audience.contentRating,
        audienceNotes: audience.audienceNotes,
        sourcePayloadJSON: allowRemix ? JSON.stringify(sourcePayload ?? {}) : null,
        coverImagePath: typeof (data as Record<string, unknown>).cover_image_path === "string"
          ? (data as Record<string, unknown>).cover_image_path
          : null,
        coverImageURL: typeof (data as Record<string, unknown>).cover_image_url === "string"
          ? (data as Record<string, unknown>).cover_image_url
          : null,
        coverImageWidth: typeof (data as Record<string, unknown>).cover_image_width === "number"
          ? (data as Record<string, unknown>).cover_image_width
          : null,
        coverImageHeight: typeof (data as Record<string, unknown>).cover_image_height === "number"
          ? (data as Record<string, unknown>).cover_image_height
          : null,
        coverImageContentType: typeof (data as Record<string, unknown>).cover_image_content_type === "string"
          ? (data as Record<string, unknown>).cover_image_content_type
          : null,
      },
      200,
    );
  }

  if (req.method === "POST" && routePath === "/shared-outputs") {
    const userIDOrError = requireUser();
    if (userIDOrError instanceof Response) return userIDOrError;
    const userID = userIDOrError;

    let body: PublishRequestBody;
    try {
      body = await req.json() as PublishRequestBody;
    } catch {
      return jsonResponse({ status: "failed", error: "Invalid JSON body" }, 400);
    }

    const outputText = typeof body.outputText === "string" ? body.outputText.trim() : "";
    if (!outputText) {
      return jsonResponse({ status: "failed", error: "outputText must not be empty" }, 422);
    }

    const requestedSharedOutputID = normalizeOptionalString(body.sharedOutputID);
    if (body.sharedOutputID !== undefined && !requestedSharedOutputID) {
      return jsonResponse({ status: "failed", error: "sharedOutputID must be a non-empty UUID" }, 422);
    }
    if (requestedSharedOutputID && !isUUID(requestedSharedOutputID)) {
      return jsonResponse({ status: "failed", error: "sharedOutputID must be a UUID" }, 422);
    }

    const cloudGenerationOutputID = normalizeOptionalString(body.cloudGenerationOutputID);
    if (!cloudGenerationOutputID || !isUUID(cloudGenerationOutputID)) {
      return jsonResponse({ status: "failed", error: "cloudGenerationOutputID must be a UUID" }, 422);
    }
    const generationOutputID = cloudGenerationOutputID;

    const { data: generationOutput, error: generationLookupError } = await adminClient
      .from("generation_outputs")
      .select("id, user_id")
      .eq("id", generationOutputID)
      .maybeSingle();
    if (generationLookupError) {
      console.error("[public-sharing] generation ownership lookup error:", generationLookupError);
      return jsonResponse({ status: "failed", error: "Could not validate generation output ownership" }, 500);
    }
    if (!generationOutput) {
      return jsonResponse({ status: "failed", error: "Generation output not found" }, 404);
    }
    if (String((generationOutput as Record<string, unknown>).user_id ?? "") !== userID) {
      return jsonResponse({ status: "failed", error: "You do not own this generation output" }, 403);
    }

    const coverImagePath = normalizeOptionalString(body.coverImagePath);
    const coverImageURL = normalizeOptionalString(body.coverImageURL);
    const rawCoverImageWidth = body.coverImageWidth;
    const rawCoverImageHeight = body.coverImageHeight;
    const coverImageWidth = typeof rawCoverImageWidth === "number" && Number.isInteger(rawCoverImageWidth) &&
        rawCoverImageWidth > 0
      ? rawCoverImageWidth
      : null;
    const coverImageHeight = typeof rawCoverImageHeight === "number" && Number.isInteger(rawCoverImageHeight) &&
        rawCoverImageHeight > 0
      ? rawCoverImageHeight
      : null;
    const coverImageContentType = normalizeOptionalString(body.coverImageContentType);
    const hasAnyCoverField = Boolean(
      coverImagePath || coverImageURL || rawCoverImageWidth !== undefined || rawCoverImageHeight !== undefined ||
        coverImageContentType,
    );
    if (hasAnyCoverField && !coverImagePath) {
      return jsonResponse({ status: "failed", error: "coverImagePath is required when cover image metadata is provided" }, 422);
    }
    if (rawCoverImageWidth !== undefined && coverImageWidth === null) {
      return jsonResponse({ status: "failed", error: "coverImageWidth must be a positive integer" }, 422);
    }
    if (rawCoverImageHeight !== undefined && coverImageHeight === null) {
      return jsonResponse({ status: "failed", error: "coverImageHeight must be a positive integer" }, 422);
    }
    if (coverImageContentType && !coverImageContentType.startsWith("image/")) {
      return jsonResponse({ status: "failed", error: "coverImageContentType must be an image MIME type" }, 422);
    }

    const sourcePayloadJSON = parsePayloadJSON(body.sourcePayloadJSON, {});

    const generationAction = ALLOWED_ACTIONS.has(String(body.generationAction))
      ? String(body.generationAction)
      : "generate";
    const generationLengthMode = ALLOWED_LENGTH_MODES.has(String(body.generationLengthMode))
      ? String(body.generationLengthMode)
      : "medium";

    const { data, error } = await adminClient
      .from("shared_outputs")
      .insert({
        ...(requestedSharedOutputID ? { id: requestedSharedOutputID } : {}),
        owner_user_id: userID,
        generation_output_id: generationOutputID,
        share_title: typeof body.shareTitle === "string" ? body.shareTitle.trim() : "",
        share_excerpt: typeof body.shareExcerpt === "string" ? body.shareExcerpt.trim() : "",
        allow_remix: Boolean(body.allowRemix),
        output_text: outputText,
        source_payload_json: sourcePayloadJSON,
        source_prompt_pack_name: typeof body.sourcePromptPackName === "string" ? body.sourcePromptPackName : "",
        model_name: typeof body.modelName === "string" ? body.modelName : "",
        generation_action: generationAction,
        generation_length_mode: generationLengthMode,
        visibility: "shared",
        unpublished_at: null,
        cover_image_path: coverImagePath,
        cover_image_url: coverImageURL,
        cover_image_width: coverImageWidth,
        cover_image_height: coverImageHeight,
        cover_image_content_type: coverImageContentType,
      })
      .select("id, visibility, published_at")
      .single();

    if (error || !data) {
      console.error("[public-sharing] publish error:", error);
      return jsonResponse({ status: "failed", error: "Could not publish shared output" }, 500);
    }

    const sharedOutputID = String((data as Record<string, unknown>).id);
    return jsonResponse(
      {
        sharedOutputID,
        shareURL: buildShareURL(publicShareBaseURL, sharedOutputID),
        visibility: String((data as Record<string, unknown>).visibility ?? "shared"),
        publishedAt: (data as Record<string, unknown>).published_at ?? new Date().toISOString(),
      },
      200,
    );
  }

  if (req.method === "DELETE" && segments[0] === "shared-outputs" && segments.length === 2) {
    const userIDOrError = requireUser();
    if (userIDOrError instanceof Response) return userIDOrError;
    const userID = userIDOrError;
    const sharedOutputID = segments[1];
    if (!isUUID(sharedOutputID)) {
      return jsonResponse({ status: "failed", error: "Invalid shared output ID" }, 400);
    }

    const { data, error } = await adminClient
      .from("shared_outputs")
      .update({
        visibility: "private",
        unpublished_at: new Date().toISOString(),
      })
      .eq("id", sharedOutputID)
      .eq("owner_user_id", userID)
      .is("unpublished_at", null)
      .select("id")
      .maybeSingle();

    if (error) {
      console.error("[public-sharing] unpublish error:", error);
      return jsonResponse({ status: "failed", error: "Could not unpublish shared output" }, 500);
    }
    if (!data) {
      return jsonResponse({ status: "failed", error: "Shared output not found" }, 404);
    }

    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (
    req.method === "POST" && segments[0] === "shared-outputs" && segments.length === 3 &&
    segments[2] === "reports"
  ) {
    const userIDOrError = requireUser();
    if (userIDOrError instanceof Response) return userIDOrError;
    const userID = userIDOrError;
    const sharedOutputID = segments[1];
    if (!isUUID(sharedOutputID)) {
      return jsonResponse({ status: "failed", error: "Invalid shared output ID" }, 400);
    }

    let body: Record<string, unknown>;
    try {
      body = await req.json() as Record<string, unknown>;
    } catch {
      return jsonResponse({ status: "failed", error: "Invalid JSON body" }, 400);
    }

    const reason = typeof body.reason === "string" ? body.reason : "";
    if (!ALLOWED_REPORT_REASONS.has(reason)) {
      return jsonResponse({ status: "failed", error: "Invalid report reason" }, 422);
    }

    const { data: target, error: lookupError } = await adminClient
      .from("shared_outputs")
      .select("id")
      .eq("id", sharedOutputID)
      .in("visibility", ["shared", "unlisted"])
      .is("unpublished_at", null)
      .maybeSingle();
    if (lookupError) {
      return jsonResponse({ status: "failed", error: "Could not validate shared output" }, 500);
    }
    if (!target) {
      return jsonResponse({ status: "failed", error: "Shared output not found" }, 404);
    }

    const { error } = await adminClient.from("shared_output_reports").insert({
      shared_output_id: sharedOutputID,
      reporter_user_id: userID,
      reason,
      details: typeof body.details === "string" ? body.details : "",
    });

    if (error) {
      console.error("[public-sharing] report insert error:", error);
      return jsonResponse({ status: "failed", error: "Could not submit report" }, 500);
    }
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  if (req.method === "POST" && routePath === "/remix-events") {
    const userIDOrError = requireUser();
    if (userIDOrError instanceof Response) return userIDOrError;
    const userID = userIDOrError;

    let body: RemixRequestBody;
    try {
      body = await req.json() as RemixRequestBody;
    } catch {
      return jsonResponse({ status: "failed", error: "Invalid JSON body" }, 400);
    }

    if (!isUUID(body.sharedOutputID)) {
      return jsonResponse({ status: "failed", error: "Invalid sharedOutputID" }, 422);
    }

    const createdProjectLocalID = typeof body.createdProjectLocalID === "string"
      ? body.createdProjectLocalID
      : "";

    const createdAt = body.createdAt ? new Date(body.createdAt) : new Date();
    if (Number.isNaN(createdAt.getTime())) {
      return jsonResponse({ status: "failed", error: "Invalid createdAt timestamp" }, 422);
    }

    const { error } = await adminClient.from("remix_events").insert({
      user_id: userID,
      shared_output_id: body.sharedOutputID,
      created_project_local_id: createdProjectLocalID || null,
      source_payload_json: parsePayloadJSON(body.sourcePayloadJSON, null),
      created_at: createdAt.toISOString(),
    });

    if (error) {
      console.error("[public-sharing] remix event insert error:", error);
      return jsonResponse({ status: "failed", error: "Could not record remix event" }, 500);
    }
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }

  return jsonResponse({ status: "failed", error: "Not found" }, 404);
}

Deno.serve((req: Request) => handler(req));

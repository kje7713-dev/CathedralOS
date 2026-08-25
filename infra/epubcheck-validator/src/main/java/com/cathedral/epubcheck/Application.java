package com.cathedral.epubcheck;

import io.javalin.Javalin;
import io.javalin.http.HttpStatus;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.util.Map;

/**
 * Thin HTTP wrapper around EpubcheckService. HMAC-SHA256 auth + signed-URL
 * transport. NEVER exposes arbitrary Java execution — fixed CLI, size limits,
 * timeouts, randomized temp dirs, no persistent storage.
 */
public class Application {
    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final String HMAC_SECRET = System.getenv("HMAC_SECRET");
    private static final long MAX_EPUB_SIZE_MB =
        Long.parseLong(System.getenv().getOrDefault("MAX_EPUB_SIZE_MB", "100"));

    public static void main(String[] args) {
        if (HMAC_SECRET == null || HMAC_SECRET.length() < 32) {
            System.err.println("HMAC_SECRET must be set (32+ bytes)");
            System.exit(1);
        }

        EpubcheckService service = new EpubcheckService();
        TempFileManager tempManager = new TempFileManager();

        Javalin app = Javalin.create(config -> {
            config.showJavalinBanner = false;
            // Body size limit: EPUB max + headroom for envelope (signed URL etc.)
            config.http.maxRequestSize = (MAX_EPUB_SIZE_MB + 1) * 1024 * 1024L;
        });

        app.post("/v1/validate", ctx -> {
            // 1. HMAC verification
            String sigHeader = ctx.header("X-Epubcheck-Signature");
            if (sigHeader == null) {
                ctx.status(HttpStatus.UNAUTHORIZED).json(Map.of("error", "missing_signature"));
                return;
            }

            String t = null, v1 = null;
            for (String part : sigHeader.split(",")) {
                String[] kv = part.split("=", 2);
                if (kv.length == 2) {
                    if ("t".equals(kv[0])) t = kv[1];
                    else if ("v1".equals(kv[0])) v1 = kv[1];
                }
            }
            if (t == null || v1 == null) {
                ctx.status(HttpStatus.UNAUTHORIZED).json(Map.of("error", "malformed_signature"));
                return;
            }

            // Timestamp window ±5 min (replay protection)
            long ts;
            try {
                ts = Long.parseLong(t);
            } catch (NumberFormatException e) {
                ctx.status(HttpStatus.UNAUTHORIZED).json(Map.of("error", "invalid_timestamp"));
                return;
            }
            long now = System.currentTimeMillis() / 1000;
            if (Math.abs(now - ts) > 300) {
                ctx.status(HttpStatus.UNAUTHORIZED).json(Map.of("error", "timestamp_out_of_window"));
                return;
            }

            String body = ctx.body();
            String expectedSig = HmacUtil.sign(HMAC_SECRET, t + "." + body);
            if (!HmacUtil.constantTimeEquals(expectedSig, v1)) {
                ctx.status(HttpStatus.UNAUTHORIZED).json(Map.of("error", "invalid_signature"));
                return;
            }

            // 2. Parse request
            String signedUrl;
            String validationId;
            try {
                JsonNode req = MAPPER.readTree(body);
                if (req == null || !req.has("epub_storage_path") || !req.has("validation_id")) {
                    ctx.status(HttpStatus.BAD_REQUEST).json(Map.of(
                        "error", "missing_fields",
                        "required", new String[]{"epub_storage_path", "validation_id"}
                    ));
                    return;
                }
                signedUrl = req.get("epub_storage_path").asText();
                validationId = req.get("validation_id").asText();
            } catch (Exception e) {
                ctx.status(HttpStatus.BAD_REQUEST).json(Map.of("error", "invalid_json", "message", e.getMessage()));
                return;
            }

            if (signedUrl.isBlank() || validationId.isBlank()) {
                ctx.status(HttpStatus.BAD_REQUEST).json(Map.of("error", "empty_required_fields"));
                return;
            }

            // 3. Run validation (always clean up temp dir)
            try (TempFileManager.TempDir tempDir = tempManager.create(validationId)) {
                ValidationResult result = service.validate(signedUrl, validationId, tempDir);
                ctx.json(MAPPER.writeValueAsString(result));
            } catch (EpubcheckService.SizeException e) {
                ctx.status(HttpStatus.CONTENT_TOO_LARGE).json(Map.of("error", "epub_too_large", "message", e.getMessage()));
            } catch (EpubcheckService.DownloadException e) {
                ctx.status(HttpStatus.BAD_GATEWAY).json(Map.of("error", "download_failed", "message", e.getMessage()));
            } catch (EpubcheckService.TimeoutException e) {
                ctx.status(HttpStatus.GATEWAY_TIMEOUT).json(Map.of("error", "validation_timeout", "message", e.getMessage()));
            } catch (EpubcheckService.InvocationException e) {
                ctx.status(HttpStatus.INTERNAL_SERVER_ERROR).json(Map.of("error", "validation_failed", "message", e.getMessage()));
            } catch (Exception e) {
                ctx.status(HttpStatus.INTERNAL_SERVER_ERROR).json(Map.of("error", "internal_error", "message", e.getMessage()));
            }
        });

        app.get("/health", ctx -> ctx.json(Map.of(
            "status", "ok",
            "epubcheck_version", "5.3.0"
        )));

        int port = Integer.parseInt(System.getenv().getOrDefault("PORT", "8080"));
        app.start(port);
        System.out.println("epubcheck-validator listening on port " + port);
    }
}

package com.cathedral.epubcheck;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import java.util.regex.*;

/**
 * Runs EPUBCheck on a downloaded EPUB and parses the output into a structured
 * ValidationResult. Fixed CLI args (no caller injection).
 */
public class EpubcheckService {

    private static final String EPUBCHECK_JAR =
        System.getenv().getOrDefault("EPUBCHECK_JAR", "/app/epubcheck.jar");
    private static final long TIMEOUT_SECONDS =
        Long.parseLong(System.getenv().getOrDefault("EPUBCHECK_TIMEOUT_SECONDS", "60"));
    private static final long MAX_SIZE_MB =
        Long.parseLong(System.getenv().getOrDefault("MAX_EPUB_SIZE_MB", "100"));
    private static final String PINNED_VERSION = "5.3.0";

    private static final ObjectMapper MAPPER = new ObjectMapper();

    public static class SizeException extends RuntimeException {
        public SizeException(String msg) { super(msg); }
    }
    public static class DownloadException extends RuntimeException {
        public DownloadException(String msg) { super(msg); }
    }
    public static class TimeoutException extends RuntimeException {
        public TimeoutException(String msg) { super(msg); }
    }
    public static class InvocationException extends RuntimeException {
        public InvocationException(String msg) { super(msg); }
    }

    public ValidationResult validate(String signedUrl, String validationId, TempFileManager.TempDir tempDir) {
        Path epubPath = tempDir.path().resolve("input.epub");
        downloadWithLimit(signedUrl, epubPath);

        long startMs = System.currentTimeMillis();
        ProcessResult proc = runEpubcheck(epubPath);
        long durationMs = System.currentTimeMillis() - startMs;

        ValidationResult result = parseOutput(proc);
        result.validation_id = validationId;
        result.validation_duration_ms = durationMs;
        result.epubcheck_version = PINNED_VERSION;
        return result;
    }

    private void downloadWithLimit(String urlStr, Path dest) {
        HttpURLConnection conn = null;
        try {
            URL url = new URL(urlStr);
            conn = (HttpURLConnection) url.openConnection();
            conn.setConnectTimeout(10_000);
            conn.setReadTimeout(30_000);
            conn.setRequestMethod("GET");

            int contentLength = conn.getContentLength();
            long maxBytes = MAX_SIZE_MB * 1024 * 1024L;
            if (contentLength > maxBytes) {
                throw new SizeException(
                    "EPUB exceeds " + MAX_SIZE_MB + "MB (Content-Length: " + contentLength + ")");
            }

            try (InputStream in = conn.getInputStream();
                 OutputStream out = Files.newOutputStream(dest,
                     StandardOpenOption.CREATE, StandardOpenOption.TRUNCATE_EXISTING)) {
                byte[] buf = new byte[64 * 1024];
                long total = 0;
                int n;
                while ((n = in.read(buf)) > 0) {
                    total += n;
                    if (total > maxBytes) {
                        throw new SizeException(
                            "EPUB exceeds " + MAX_SIZE_MB + "MB during download");
                    }
                    out.write(buf, 0, n);
                }
            }
        } catch (SizeException e) {
            throw e;
        } catch (Exception e) {
            throw new DownloadException("download failed: " + e.getMessage());
        } finally {
            if (conn != null) conn.disconnect();
        }
    }

    private ProcessResult runEpubcheck(Path epubPath) {
        // Fixed CLI args — callers cannot inject
        ProcessBuilder pb = new ProcessBuilder(
            "java", "-jar", EPUBCHECK_JAR,
            epubPath.toString(),
            "--mode", "exp",
            "--profile", "default"
        );
        pb.redirectErrorStream(false);

        try {
            Process proc = pb.start();
            boolean finished = proc.waitFor(TIMEOUT_SECONDS, TimeUnit.SECONDS);
            if (!finished) {
                proc.destroyForcibly();
                throw new TimeoutException(
                    "EPUBCheck timed out after " + TIMEOUT_SECONDS + "s");
            }

            String stdout = new String(proc.getInputStream().readAllBytes(), StandardCharsets.UTF_8);
            String stderr = new String(proc.getErrorStream().readAllBytes(), StandardCharsets.UTF_8);
            ProcessResult result = new ProcessResult();
            result.stdout = stdout;
            result.stderr = stderr;
            result.exitCode = proc.exitValue();
            return result;
        } catch (TimeoutException e) {
            throw e;
        } catch (Exception e) {
            throw new InvocationException("EPUBCheck invocation failed: " + e.getMessage());
        }
    }

    private ValidationResult parseOutput(ProcessResult proc) {
        ValidationResult result = new ValidationResult();
        result.diagnostics = new ArrayList<>();
        result.error_count = 0;
        result.warning_count = 0;

        // EPUBCheck exit codes:
        // 0 = no errors or warnings (valid)
        // 1 = warnings only (still valid — warnings logged but don't block)
        // 2 = errors (invalid)
        // 3 = fatal errors (invalid)
        boolean parseSucceeded = false;
        if (!proc.stdout.isBlank()) {
            try {
                parseText(proc.stdout, result);
                parseSucceeded = true;
            } catch (Exception e) {
                System.err.println("text parse failed: " + e.getMessage());
            }
        }

        if (!parseSucceeded && !proc.stderr.isBlank()) {
            try {
                parseText(proc.stderr, result);
            } catch (Exception e) {
                System.err.println("stderr parse failed: " + e.getMessage());
            }
        }

        // valid = (no fatal/error diagnostics)
        for (ValidationResult.Diagnostic d : result.diagnostics) {
            if ("fatal".equals(d.severity) || "error".equals(d.severity)) {
                result.valid = false;
                break;
            }
        }
        if (result.error_count == 0 && proc.exitCode >= 2) {
            // Exit code suggests errors but none parsed — mark invalid defensively
            result.valid = false;
        }
        return result;
    }

    /** EPUBCheck text format: "ERROR(RSC-005): message (path:line:col)" */
    private static final Pattern TEXT_PATTERN = Pattern.compile(
        "(ERROR|FATAL|WARNING|INFO)\\((\\S+)\\):\\s*(.+?)(?:\\s+\\(([^)]+?)(?::(\\d+))?(?::(\\d+))?\\))?\\s*$",
        Pattern.MULTILINE
    );

    private void parseText(String text, ValidationResult result) {
        Matcher m = TEXT_PATTERN.matcher(text);
        while (m.find()) {
            String rawSeverity = m.group(1);
            String severity = switch (rawSeverity) {
                case "ERROR" -> "error";
                case "FATAL" -> "fatal";
                case "WARNING" -> "warning";
                default -> "info";
            };
            ValidationResult.Diagnostic d = new ValidationResult.Diagnostic();
            d.severity = severity;
            d.code = m.group(2);
            d.message = m.group(3).trim();
            if (m.group(4) != null && !m.group(4).isEmpty()) {
                d.file = m.group(4);
            }
            if (m.group(5) != null) d.line = Integer.parseInt(m.group(5));
            if (m.group(6) != null) d.column = Integer.parseInt(m.group(6));
            result.diagnostics.add(d);
            switch (severity) {
                case "fatal":
                case "error":
                    result.error_count++;
                    break;
                case "warning":
                    result.warning_count++;
                    break;
            }
        }
    }

    private static class ProcessResult {
        String stdout = "";
        String stderr = "";
        int exitCode = -1;
    }
}

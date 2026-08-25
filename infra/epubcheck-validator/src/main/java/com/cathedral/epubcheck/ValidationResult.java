package com.cathedral.epubcheck;

import java.util.List;

/** Structured validation response shape (matches _validator_client.ts in Cathedral backend). */
public class ValidationResult {
    public String validation_id;
    public String epubcheck_version;
    public long validation_duration_ms;
    public boolean valid;
    public int error_count;
    public int warning_count;
    public List<Diagnostic> diagnostics;

    public static class Diagnostic {
        public String severity;     // "fatal" | "error" | "warning" | "info"
        public String code;
        public String message;
        public String file;         // internal EPUB path (e.g., "OEBPS/content.opf")
        public Integer line;
        public Integer column;
    }
}

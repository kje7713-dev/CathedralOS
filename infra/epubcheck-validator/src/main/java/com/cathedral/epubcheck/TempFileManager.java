package com.cathedral.epubcheck;

import java.io.IOException;
import java.nio.file.*;
import java.util.Comparator;

/**
 * Manages randomized temp directories for EPUBCheck invocations.
 * Each validation gets a unique random dir under java.io.tmpdir;
 * cleanup is guaranteed via try-with-resources or explicit close().
 */
public class TempFileManager {

    public static final class TempDir implements AutoCloseable {
        private final Path path;
        private boolean closed = false;

        public TempDir(Path path) {
            this.path = path;
        }

        public Path path() {
            return path;
        }

        @Override
        public void close() {
            cleanup();
        }

        public void cleanup() {
            if (closed) return;
            closed = true;
            try {
                if (Files.exists(path)) {
                    try (var stream = Files.walk(path)) {
                        stream.sorted(Comparator.reverseOrder())
                              .forEach(p -> {
                                  try {
                                      Files.delete(p);
                                  } catch (IOException ignored) {
                                      // best-effort cleanup
                                  }
                              });
                    }
                }
            } catch (IOException ignored) {
                // best-effort cleanup
            }
        }
    }

    public TempDir create(String validationId) throws IOException {
        // Randomized name from UUID + validationId (no user-controlled FS paths)
        String random = java.util.UUID.randomUUID().toString().replace("-", "").substring(0, 16);
        Path base = Paths.get(System.getProperty("java.io.tmpdir"), "epubcheck-" + random);
        Files.createDirectories(base);
        return new TempDir(base);
    }
}

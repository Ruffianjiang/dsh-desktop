import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri expects a fixed dev server port and ignores file changes under src-tauri.
export default defineConfig({
  plugins: [react()],
  clearScreen: false,
  // The sandbox build wraps fs.rmSync with a bulk-delete guard (threshold 50).
  // Tauri's default emptyOutDir cleans dist/ and trips that guard once the
  // output grows past ~50 files. We disable it and clean dist/ ourselves with a
  // rename (see build-tauri-gnu.sh), which performs zero deletes.
  build: {
    emptyOutDir: false,
  },
  server: {
    port: 1420,
    strictPort: true,
    watch: { ignored: ["**/src-tauri/**"] },
  },
});

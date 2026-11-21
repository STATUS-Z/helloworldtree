import { defineConfig, type UserConfig } from "vite";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));

/**
 * Hello World Tree.
 *
 * `base` is the project-page path on GitHub Pages. Setting it to "/" works in dev and 404s every asset in
 * production, which is the classic way this fails.
 *
 * Babylon is behind a dynamic import in the vessel renderer, so the initial payload is the page plus a
 * small entry chunk and the engine arrives only when a scene is actually built.
 */
const config: UserConfig = {
  base: "/helloworldtree/",
  publicDir: "public",
  build: {
    outDir: "docs",
    emptyOutDir: true,
    target: "es2022",
    assetsInlineLimit: 2048,
    chunkSizeWarningLimit: 2600,
  },
  server: { port: 5180, open: false },
  optimizeDeps: { include: ["@babylonjs/core"] },
};

export default defineConfig(config);

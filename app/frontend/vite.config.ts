import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  build: {
    outDir: "dist",
    sourcemap: true,
  },
  server: {
    proxy: {
      "/chat": "http://localhost:8080",
      "/config": "http://localhost:8080",
    },
  },
});

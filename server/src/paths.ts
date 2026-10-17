import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));

/** server/assets, resolved the same way from src/ (tsx) and dist/ (compiled). */
export const ASSETS_DIR = process.env.PRESENT_ASSETS_DIR ?? path.resolve(here, "..", "assets");

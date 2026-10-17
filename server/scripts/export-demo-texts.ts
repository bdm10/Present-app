// Prints every line the demo voice must be able to read (as JSON) for render-demo-voice.py.
import { DEMO_SCRIPTS } from "../src/providers/script/demo-scripts.js";
import { cleanSpokenText } from "../src/providers/script/prompt.js";
import { PREVIEW_TEXT } from "../src/previews.js";

const lines = new Set<string>();
for (const s of DEMO_SCRIPTS) for (const l of s.lines) lines.add(cleanSpokenText(l.t, false));
process.stdout.write(JSON.stringify({ preview: PREVIEW_TEXT, lines: [...lines] }, null, 2));

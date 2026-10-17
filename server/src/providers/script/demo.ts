import type { ScriptProvider, ScriptRequest, ScriptResult } from "../types.js";
import { DEMO_SCRIPTS } from "./demo-scripts.js";

/** Demo mode: returns a pre-written script for the theme. No AI is involved. */
export class DemoScriptProvider implements ScriptProvider {
  readonly name = "demo";
  readonly mode = "demo" as const;
  readonly detail = "Demo mode: pre-written sample scripts (add ANTHROPIC_API_KEY for new scripts written by Claude)";

  async write(req: ScriptRequest): Promise<ScriptResult> {
    const base = DEMO_SCRIPTS.find((s) => s.theme === req.theme) ?? DEMO_SCRIPTS[0];
    const lines = base.lines.filter((l) => req.durationMinutes > 5 || !l.ext);
    return {
      script: {
        title: base.title,
        summary: base.summary,
        reflectionQuestion: base.reflectionQuestion,
        motifs: base.motifs,
        segments: lines.map((l) => ({ text: l.t, pauseAfterSeconds: l.p })),
      },
      model: "demo-script",
      costUsd: 0,
    };
  }
}

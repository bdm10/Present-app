import Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import * as z from "zod/v4";
import type { Config } from "../../config.js";
import type { ScriptProvider, ScriptRequest, ScriptResult } from "../types.js";
import { SYSTEM_PROMPT, buildUserPrompt } from "./prompt.js";

const ScriptSchema = z.object({
  title: z.string().describe("Two to five words, evocative and plain. No colon."),
  summary: z.string().describe("One gentle sentence describing the session, shown on the home screen."),
  segments: z
    .array(
      z.object({
        text: z.string().describe("One to three short sentences to be spoken."),
        pauseAfterSeconds: z.number().describe("Requested silence after this segment, in seconds."),
      }),
    )
    .describe("The spoken script in order."),
  reflectionQuestion: z.string().describe("One open reflection question for the journal."),
  motifs: z.array(z.string()).describe("Three to six short phrases naming the central images and practices used."),
});

export class AnthropicScriptProvider implements ScriptProvider {
  readonly name = "anthropic";
  readonly mode = "live" as const;
  private client: Anthropic;

  constructor(private cfg: Config) {
    // The base URL is explicit so a stray ANTHROPIC_BASE_URL in the environment is never picked up.
    this.client = new Anthropic({ apiKey: cfg.anthropicApiKey, baseURL: cfg.anthropicBaseUrl, maxRetries: 2, timeout: 180_000 });
  }

  get detail(): string {
    return `Claude (${this.cfg.anthropicModel}) writes each script`;
  }

  async write(req: ScriptRequest): Promise<ScriptResult> {
    const response = await this.client.beta.messages.parse({
      model: this.cfg.anthropicModel,
      max_tokens: 16000,
      betas: ["server-side-fallback-2026-07-01"],
      // If the primary model declines (very unlikely for meditation scripts),
      // the API retries on its default fallback model within the same call.
      fallbacks: "default",
      system: [{ type: "text", text: SYSTEM_PROMPT, cache_control: { type: "ephemeral" } }],
      messages: [{ role: "user", content: buildUserPrompt(req) }],
      output_config: {
        effort: this.cfg.anthropicEffort,
        format: betaZodOutputFormat(ScriptSchema),
      },
    });

    if (response.stop_reason === "refusal") {
      throw new Error("The script model declined this request");
    }
    if (response.stop_reason === "max_tokens") {
      throw new Error("The script was cut off before it finished");
    }
    const parsed = response.parsed_output;
    if (!parsed) throw new Error("The script model returned an unreadable response");

    const inputTokens =
      response.usage.input_tokens +
      (response.usage.cache_creation_input_tokens ?? 0) * 1.25 +
      (response.usage.cache_read_input_tokens ?? 0) * 0.1;
    const outputTokens = response.usage.output_tokens;
    const costUsd =
      (inputTokens / 1e6) * this.cfg.anthropicUsdPerMTokIn + (outputTokens / 1e6) * this.cfg.anthropicUsdPerMTokOut;

    return {
      script: parsed,
      model: response.model,
      costUsd,
      usage: { inputTokens: Math.round(inputTokens), outputTokens },
    };
  }
}

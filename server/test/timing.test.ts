import { describe, expect, it } from "vitest";
import { SpeechTooLongError, framingFor, planTiming } from "../src/audio/timing.js";

const SR = 44100;

describe("planTiming", () => {
  it("fills silence so the total is exact to the sample", () => {
    const speech = [3.2, 5.1, 4.4, 6.0, 2.5].map((s) => Math.round(s * SR));
    const plan = planTiming({ sampleRate: SR, targetSeconds: 300, speechSamples: speech, pauseHints: [4, 10, 30, 6, 0], leadInSeconds: 6, tailSeconds: 14 });
    const total = plan.leadInSamples + speech.reduce((a, b) => a + b) + plan.pauseSamples.reduce((a, b) => a + b) + plan.tailSamples;
    expect(total).toBe(300 * SR);
    expect(plan.totalSamples).toBe(300 * SR);
    expect(plan.pauseSamples).toHaveLength(4);
  });

  it("keeps the relative shape of requested pauses, within limits", () => {
    const speech = Array(10).fill(4 * SR);
    const hints = [2, 2, 10, 10, 30, 30, 2, 2, 10, 0];
    const plan = planTiming({ sampleRate: SR, targetSeconds: 300, speechSamples: speech, pauseHints: hints, leadInSeconds: 6, tailSeconds: 14, maxPauseSeconds: 60 });
    const p = plan.pauseSamples.map((s) => s / SR);
    expect(p[4]).toBeGreaterThan(p[2]);
    expect(p[2]).toBeGreaterThan(p[0]);
    expect(Math.min(...p)).toBeGreaterThanOrEqual(1.2 - 1e-6);
    expect(Math.max(...p)).toBeLessThanOrEqual(60 + 1e-6);
  });

  it("speech starts are monotonic and include the lead-in", () => {
    const speech = [2 * SR, 3 * SR, 4 * SR];
    const plan = planTiming({ sampleRate: SR, targetSeconds: 60, speechSamples: speech, pauseHints: [5, 5, 0], leadInSeconds: 6, tailSeconds: 10 });
    expect(plan.speechStartSeconds[0]).toBeCloseTo(6, 5);
    expect(plan.speechStartSeconds[1]).toBeGreaterThan(plan.speechStartSeconds[0] + 2);
    expect(plan.speechIntervals[2][1]).toBeLessThanOrEqual(60);
  });

  it("throws when the script cannot fit, even after shrinking intro/outro", () => {
    const speech = Array(40).fill(8 * SR); // 320 s of speech for a 300 s session
    expect(() => planTiming({ sampleRate: SR, targetSeconds: 300, speechSamples: speech, pauseHints: Array(40).fill(3), leadInSeconds: 6, tailSeconds: 14 })).toThrow(
      SpeechTooLongError,
    );
  });

  it("spreads leftover time when every pause is already at its maximum", () => {
    const speech = [2 * SR, 2 * SR, 2 * SR];
    const plan = planTiming({ sampleRate: SR, targetSeconds: 1200, speechSamples: speech, pauseHints: [10, 10, 0], leadInSeconds: 10, tailSeconds: 22, maxPauseSeconds: 90 });
    const total = plan.leadInSamples + 6 * SR + plan.pauseSamples.reduce((a, b) => a + b) + plan.tailSamples;
    expect(total).toBe(1200 * SR);
  });

  it("gives sleep sessions a longer tail", () => {
    expect(framingFor(20, "sleep").tail).toBeGreaterThan(framingFor(20, "presence").tail);
  });
});

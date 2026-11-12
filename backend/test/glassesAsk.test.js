import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import request from "supertest";

import { buildHermesArgs, createApp, parseHermesOutput } from "../src/app.js";

function appWithRunner(runner, options = {}) {
  return createApp({
    appToken: "test-token",
    rateLimit: false,
    runHermes: runner,
    ...options
  });
}

test("rejects missing or invalid bearer token", async () => {
  const app = appWithRunner(async () => ({ answer: "unused" }));

  await request(app)
    .post("/api/glasses/ask")
    .field("text", "What do you see?")
    .expect(401)
    .expect(({ body }) => {
      assert.equal(body.error, "unauthorized");
    });

  await request(app)
    .post("/api/glasses/ask")
    .set("Authorization", "Bearer wrong-token")
    .field("text", "What do you see?")
    .expect(401);
});

test("builds Hermes args with an optional model override before source flags", () => {
  assert.deepEqual(
    buildHermesArgs({
      text: "Какая погода?",
      model: "gpt-5.4-mini",
      ignoreRules: true,
      source: "rayban-ios",
      maxTurns: "1"
    }),
    [
      "chat",
      "-q",
      "Какая погода?",
      "-m",
      "gpt-5.4-mini",
      "--ignore-rules",
      "-Q",
      "--max-turns",
      "1",
      "--source",
      "rayban-ios"
    ]
  );

  assert.deepEqual(
    buildHermesArgs({
      text: "Что передо мной?",
      imagePath: "/tmp/frame.jpg",
      source: "rayban-ios",
      maxTurns: "1"
    }),
    [
      "chat",
      "-q",
      "Что передо мной?",
      "--image",
      "/tmp/frame.jpg",
      "-Q",
      "--max-turns",
      "1",
      "--source",
      "rayban-ios"
    ]
  );
});

test("parses Hermes output without technical max-turn warning lines", () => {
  assert.deepEqual(
    parseHermesOutput(
      "session_id: abc123\n⚠️  Reached maximum iterations (1). Requesting summary...\nНа картинке зелёный фон.",
      ""
    ),
    {
      answer: "На картинке зелёный фон.",
      sessionId: "abc123"
    }
  );
});

test("requires text and enforces the 2000 character text limit", async () => {
  const app = appWithRunner(async () => ({ answer: "unused" }));

  await request(app)
    .post("/api/glasses/ask")
    .set("Authorization", "Bearer test-token")
    .expect(400)
    .expect(({ body }) => {
      assert.equal(body.error, "text_required");
    });

  await request(app)
    .post("/api/glasses/ask")
    .set("Authorization", "Bearer test-token")
    .field("text", "x".repeat(2001))
    .expect(413)
    .expect(({ body }) => {
      assert.equal(body.error, "text_too_large");
    });
});

test("answers weather requests without a location immediately", async () => {
  let called = false;
  const app = appWithRunner(async () => {
    called = true;
    return { answer: "Hermes should not be called." };
  });

  await request(app)
    .post("/api/glasses/ask")
    .set("Authorization", "Bearer test-token")
    .field("text", "какая погода сегодня")
    .field("sessionId", "ios-session-1")
    .expect(200)
    .expect(({ body }) => {
      assert.match(body.answer, /город|место/i);
      assert.equal(body.sessionId, "ios-session-1");
    });

  assert.equal(called, false);
});

function jsonResponse(body, status = 200) {
  return {
    ok: status >= 200 && status < 300,
    status,
    async json() {
      return body;
    }
  };
}

test("answers weather requests with a location through the weather API", async () => {
  let hermesCalled = false;
  const weatherFetchCalls = [];
  const app = appWithRunner(async ({ text }) => {
    hermesCalled = true;
    assert.equal(text, "какая погода в Алматы");
    return { answer: "Hermes should not be called." };
  }, {
    weatherFetch: async (url) => {
      const href = String(url);
      weatherFetchCalls.push(href);
      if (href.startsWith("https://geocoding-api.open-meteo.com/")) {
        return jsonResponse({
          results: [{
            name: "Алматы",
            country: "Казахстан",
            latitude: 43.2364,
            longitude: 76.9457
          }]
        });
      }
      if (href.startsWith("https://api.open-meteo.com/")) {
        return jsonResponse({
          current: {
            temperature_2m: 27,
            apparent_temperature: 28,
            precipitation: 0,
            weather_code: 1,
            wind_speed_10m: 4
          },
          current_units: {
            temperature_2m: "°C",
            apparent_temperature: "°C",
            precipitation: "mm",
            wind_speed_10m: "km/h"
          },
          daily: {
            temperature_2m_min: [20],
            temperature_2m_max: [31],
            precipitation_probability_max: [10]
          }
        });
      }
      throw new Error(`Unexpected weather URL ${href}`);
    }
  });

  await request(app)
    .post("/api/glasses/ask")
    .set("Authorization", "Bearer test-token")
    .field("text", "какая погода в Алматы")
    .field("sessionId", "ios-session-1")
    .expect(200)
    .expect(({ body }) => {
      assert.match(body.answer, /Алматы/);
      assert.match(body.answer, /27/);
      assert.match(body.answer, /ветер/i);
      assert.match(body.answer, /км\/ч/);
      assert.equal(body.sessionId, "ios-session-1");
    });

  assert.equal(hermesCalled, false);
  assert.equal(weatherFetchCalls.length, 2);
});

test("rejects non-image uploads before invoking Hermes", async () => {
  let called = false;
  const app = appWithRunner(async () => {
    called = true;
    return { answer: "unused" };
  });

  await request(app)
    .post("/api/glasses/ask")
    .set("Authorization", "Bearer test-token")
    .field("text", "Read this")
    .attach("image", Buffer.from("hello"), {
      filename: "note.txt",
      contentType: "text/plain"
    })
    .expect(415)
    .expect(({ body }) => {
      assert.equal(body.error, "unsupported_image_type");
    });

  assert.equal(called, false);
});

test("passes text and optional sessionId to Hermes without requiring an image", async () => {
  const app = appWithRunner(async ({ text, imagePath, sessionId }) => {
    assert.equal(text, "Tell me the next step");
    assert.equal(imagePath, undefined);
    assert.equal(sessionId, "ios-session-1");
    return { answer: "Walk forward carefully." };
  });

  await request(app)
    .post("/api/glasses/ask")
    .set("Authorization", "Bearer test-token")
    .field("text", "Tell me the next step")
    .field("sessionId", "ios-session-1")
    .expect(200)
    .expect(({ body }) => {
      assert.equal(body.answer, "Walk forward carefully.");
      assert.equal(body.sessionId, "ios-session-1");
    });
});

test("writes uploaded image to a temporary file and deletes it after Hermes returns", async () => {
  let capturedImagePath;
  const app = appWithRunner(async ({ text, imagePath }) => {
    assert.equal(text, "Describe this frame");
    capturedImagePath = imagePath;
    const stat = await fs.stat(imagePath);
    assert.equal(stat.size, 4);
    return { answer: "A tiny JPEG-like frame." };
  });

  await request(app)
    .post("/api/glasses/ask")
    .set("Authorization", "Bearer test-token")
    .field("text", "Describe this frame")
    .attach("image", Buffer.from([0xff, 0xd8, 0xff, 0xd9]), {
      filename: "frame.jpg",
      contentType: "image/jpeg"
    })
    .expect(200)
    .expect(({ body }) => {
      assert.equal(body.answer, "A tiny JPEG-like frame.");
      assert.ok(body.sessionId);
    });

  assert.ok(capturedImagePath);
  await assert.rejects(fs.stat(capturedImagePath), { code: "ENOENT" });
  assert.equal(path.dirname(capturedImagePath).startsWith(os.tmpdir()), true);
});

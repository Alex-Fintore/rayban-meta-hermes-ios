import crypto from "node:crypto";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";
import express from "express";
import rateLimit from "express-rate-limit";
import multer from "multer";
import { v4 as uuidv4 } from "uuid";

const DEFAULT_TIMEOUT_MS = 240_000;
const MAX_TEXT_CHARS = 2000;
const MAX_IMAGE_BYTES = 5 * 1024 * 1024;
const ALLOWED_IMAGE_TYPES = new Set(["image/jpeg", "image/png"]);
const WEATHER_MARKERS = [
  "погода",
  "погоде",
  "прогноз",
  "температура",
  "градус",
  "осадки",
  "дождь",
  "снег",
  "ветер",
  "weather",
  "forecast",
  "temperature"
];
const WEATHER_FILLER_WORDS = new Set([
  "а",
  "в",
  "во",
  "и",
  "на",
  "по",
  "у",
  "для",
  "какая",
  "какой",
  "какую",
  "какие",
  "скажи",
  "расскажи",
  "покажи",
  "сейчас",
  "сегодня",
  "завтра",
  "утром",
  "днем",
  "днём",
  "вечером",
  "ночью",
  "там",
  "тут",
  "здесь",
  "меня",
  "будет",
  "за",
  "окном",
  "please",
  "tell",
  "me",
  "the",
  "in",
  "what",
  "whats",
  "what's",
  "is",
  "now",
  "today",
  "tomorrow",
  "here",
  "there"
]);
const WEATHER_CODE_LABELS = new Map([
  [0, "ясно"],
  [1, "преимущественно ясно"],
  [2, "переменная облачность"],
  [3, "пасмурно"],
  [45, "туман"],
  [48, "изморозь и туман"],
  [51, "лёгкая морось"],
  [53, "морось"],
  [55, "сильная морось"],
  [61, "небольшой дождь"],
  [63, "дождь"],
  [65, "сильный дождь"],
  [71, "небольшой снег"],
  [73, "снег"],
  [75, "сильный снег"],
  [80, "небольшие ливни"],
  [81, "ливни"],
  [82, "сильные ливни"],
  [95, "гроза"],
  [96, "гроза с градом"],
  [99, "сильная гроза с градом"]
]);

class HttpError extends Error {
  constructor(status, code, message = code) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

function secureEquals(actual, expected) {
  const actualBuffer = Buffer.from(actual);
  const expectedBuffer = Buffer.from(expected);
  if (actualBuffer.length !== expectedBuffer.length) {
    return false;
  }
  return crypto.timingSafeEqual(actualBuffer, expectedBuffer);
}

function bearerTokenFrom(headerValue = "") {
  const match = headerValue.match(/^Bearer\s+(.+)$/i);
  return match?.[1] ?? "";
}

function stripAnsi(value) {
  return value.replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, "");
}

export function parseHermesOutput(stdout = "", stderr = "") {
  const combinedOutput = `${stripAnsi(stdout)}\n${stripAnsi(stderr)}`.replace(/\r\n/g, "\n");
  const sessionId = combinedOutput.match(/(?:^|\n)session_id:\s*([A-Za-z0-9_-]+)/)?.[1] ?? "";
  const answer = stripAnsi(stdout)
    .replace(/\r\n/g, "\n")
    .replace(/(?:^|\n)session_id:\s*[A-Za-z0-9_-]+\s*/g, "\n")
    .replace(/(?:^|\n)⚠️\s+Reached maximum iterations \(\d+\)\. Requesting summary\.\.\.\s*/g, "\n")
    .trim();
  return { answer, sessionId };
}

function normalizeWords(text) {
  return text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}'-]+/gu, " ")
    .trim()
    .split(/\s+/)
    .filter(Boolean);
}

function isWeatherRequest(text) {
  const lowerText = text.toLowerCase();
  return WEATHER_MARKERS.some((marker) => lowerText.includes(marker));
}

function weatherLocationFrom(text) {
  const meaningfulWords = normalizeWords(text).filter((word) => {
    if (WEATHER_FILLER_WORDS.has(word)) return false;
    return !WEATHER_MARKERS.some((marker) => word.includes(marker));
  });
  return meaningfulWords.join(" ").trim();
}

export function createFastGlassesResponse(text, sessionId = "") {
  if (!isWeatherRequest(text)) {
    return null;
  }

  if (weatherLocationFrom(text)) {
    return null;
  }

  return {
    answer: "Нужен город или место, чтобы сказать погоду. Скажите, например: погода Москва или погода Алматы.",
    sessionId: sessionId || uuidv4()
  };
}

function formatNumber(value, digits = 0) {
  if (!Number.isFinite(value)) return "";
  return new Intl.NumberFormat("ru-RU", { maximumFractionDigits: digits }).format(value);
}

function localizedWeatherUnit(unit, fallback) {
  if (unit === "km/h") return "км/ч";
  if (unit === "mm") return "мм";
  return unit || fallback;
}

function formatWeatherAnswer(place, forecast) {
  const current = forecast.current ?? {};
  const units = forecast.current_units ?? {};
  const daily = forecast.daily ?? {};
  const placeName = [place.name, place.country].filter(Boolean).join(", ");
  const temperatureUnit = localizedWeatherUnit(units.temperature_2m, "°C");
  const windUnit = localizedWeatherUnit(units.wind_speed_10m, "км/ч");
  const precipitationUnit = localizedWeatherUnit(units.precipitation, "мм");
  const description = WEATHER_CODE_LABELS.get(current.weather_code) ?? "погода обновлена";

  const parts = [
    `${placeName}: сейчас ${formatNumber(current.temperature_2m)}${temperatureUnit}, ${description}`
  ];

  if (Number.isFinite(current.apparent_temperature)) {
    parts.push(`ощущается как ${formatNumber(current.apparent_temperature)}${temperatureUnit}`);
  }
  if (Number.isFinite(current.wind_speed_10m)) {
    parts.push(`ветер ${formatNumber(current.wind_speed_10m)} ${windUnit}`);
  }
  if (Number.isFinite(current.precipitation) && current.precipitation > 0) {
    parts.push(`осадки ${formatNumber(current.precipitation, 1)} ${precipitationUnit}`);
  }
  if (Number.isFinite(daily.temperature_2m_min?.[0]) && Number.isFinite(daily.temperature_2m_max?.[0])) {
    parts.push(`сегодня ${formatNumber(daily.temperature_2m_min[0])}–${formatNumber(daily.temperature_2m_max[0])}${temperatureUnit}`);
  }
  if (Number.isFinite(daily.precipitation_probability_max?.[0])) {
    parts.push(`шанс осадков ${formatNumber(daily.precipitation_probability_max[0])}%`);
  }

  return `${parts.join(". ")}.`;
}

async function fetchJson(fetchImpl, url) {
  const response = await fetchImpl(url);
  if (!response?.ok) {
    throw new Error(`Weather API failed with status ${response?.status ?? "unknown"}`);
  }
  return response.json();
}

export async function createWeatherGlassesResponse(text, sessionId = "", fetchImpl = globalThis.fetch) {
  if (!isWeatherRequest(text)) {
    return null;
  }

  const missingLocationResponse = createFastGlassesResponse(text, sessionId);
  if (missingLocationResponse) {
    return missingLocationResponse;
  }

  if (typeof fetchImpl !== "function") {
    return {
      answer: "Не могу быстро проверить погоду: weather API сейчас недоступен на сервере.",
      sessionId: sessionId || uuidv4()
    };
  }

  const location = weatherLocationFrom(text);
  try {
    const geocodeUrl = new URL("https://geocoding-api.open-meteo.com/v1/search");
    geocodeUrl.searchParams.set("name", location);
    geocodeUrl.searchParams.set("count", "1");
    geocodeUrl.searchParams.set("language", "ru");
    geocodeUrl.searchParams.set("format", "json");
    const geocode = await fetchJson(fetchImpl, geocodeUrl);
    const place = geocode.results?.[0];
    if (!place) {
      return {
        answer: `Не нашёл место «${location}». Назовите город или страну чуть точнее.`,
        sessionId: sessionId || uuidv4()
      };
    }

    const forecastUrl = new URL("https://api.open-meteo.com/v1/forecast");
    forecastUrl.searchParams.set("latitude", String(place.latitude));
    forecastUrl.searchParams.set("longitude", String(place.longitude));
    forecastUrl.searchParams.set(
      "current",
      "temperature_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m"
    );
    forecastUrl.searchParams.set(
      "daily",
      "temperature_2m_min,temperature_2m_max,precipitation_probability_max"
    );
    forecastUrl.searchParams.set("forecast_days", "1");
    forecastUrl.searchParams.set("timezone", "auto");
    const forecast = await fetchJson(fetchImpl, forecastUrl);

    return {
      answer: formatWeatherAnswer(place, forecast),
      sessionId: sessionId || uuidv4()
    };
  } catch {
    return {
      answer: "Не смог быстро получить погоду. Попробуйте ещё раз через минуту или назовите город точнее.",
      sessionId: sessionId || uuidv4()
    };
  }
}

function makeUpload() {
  const storage = multer.diskStorage({
    destination: os.tmpdir(),
    filename: (_req, file, callback) => {
      const extension = file.mimetype === "image/png" ? ".png" : ".jpg";
      callback(null, `rayban-hermes-${uuidv4()}${extension}`);
    }
  });

  return multer({
    storage,
    limits: {
      fileSize: MAX_IMAGE_BYTES,
      files: 1,
      fields: 4
    },
    fileFilter: (_req, file, callback) => {
      if (!ALLOWED_IMAGE_TYPES.has(file.mimetype)) {
        callback(new HttpError(415, "unsupported_image_type"));
        return;
      }
      callback(null, true);
    }
  });
}

function createSemaphore(maxConcurrent) {
  let active = 0;
  const queue = [];

  async function acquire() {
    if (active < maxConcurrent) {
      active += 1;
      return;
    }
    await new Promise((resolve) => queue.push(resolve));
    active += 1;
  }

  function release() {
    active -= 1;
    const next = queue.shift();
    if (next) {
      next();
    }
  }

  return async function withSlot(work) {
    await acquire();
    try {
      return await work();
    } finally {
      release();
    }
  };
}

export function buildHermesArgs({
  text,
  imagePath,
  model,
  ignoreRules = false,
  maxTurns = "1",
  source = "rayban-ios"
}) {
  const args = ["chat", "-q", text];
  if (imagePath) {
    args.push("--image", imagePath);
  }
  if (model?.trim()) {
    args.push("-m", model.trim());
  }
  if (ignoreRules) {
    args.push("--ignore-rules");
  }
  args.push("-Q", "--max-turns", String(maxTurns), "--source", source);
  return args;
}

function createHermesRunner({ timeoutMs = DEFAULT_TIMEOUT_MS, model = process.env.HERMES_GLASSES_MODEL } = {}) {
  return ({ text, imagePath }) =>
    new Promise((resolve, reject) => {
      const args = buildHermesArgs({
        text,
        imagePath,
        model,
        ignoreRules: process.env.HERMES_GLASSES_IGNORE_RULES === "1",
        maxTurns: process.env.HERMES_MAX_TURNS ?? "1",
        source: process.env.HERMES_GLASSES_SOURCE ?? "rayban-ios"
      });

      const child = spawn("hermes", args, {
        stdio: ["ignore", "pipe", "pipe"]
      });

      let stdout = "";
      let stderr = "";
      let settled = false;
      const timer = setTimeout(() => {
        settled = true;
        child.kill("SIGTERM");
        reject(new HttpError(504, "hermes_timeout"));
      }, timeoutMs);

      child.stdout.setEncoding("utf8");
      child.stderr.setEncoding("utf8");
      child.stdout.on("data", (chunk) => {
        stdout += chunk;
      });
      child.stderr.on("data", (chunk) => {
        stderr += chunk;
      });
      child.on("error", (error) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        reject(new HttpError(502, "hermes_unavailable", error.message));
      });
      child.on("close", (code) => {
        if (settled) return;
        settled = true;
        clearTimeout(timer);
        if (code !== 0) {
          reject(new HttpError(502, "hermes_failed", stderr.trim() || `Hermes exited with ${code}`));
          return;
        }
        resolve(parseHermesOutput(stdout, stderr));
      });
    });
}

function mapUploadError(error) {
  if (error instanceof HttpError) {
    return error;
  }

  if (error instanceof multer.MulterError) {
    if (error.code === "LIMIT_FILE_SIZE") {
      return new HttpError(413, "image_too_large");
    }
    if (error.code === "LIMIT_FILE_COUNT" || error.code === "LIMIT_UNEXPECTED_FILE") {
      return new HttpError(400, "invalid_image_field");
    }
    return new HttpError(400, "invalid_multipart");
  }

  return error;
}

export function createApp(options = {}) {
  const appToken = options.appToken ?? process.env.APP_TOKEN;
  if (!appToken) {
    throw new Error("APP_TOKEN is required");
  }

  const maxConcurrent = Number(options.maxConcurrent ?? process.env.HERMES_MAX_CONCURRENT ?? 1);
  const withHermesSlot = createSemaphore(Math.max(1, maxConcurrent));
  const runHermes = options.runHermes ?? createHermesRunner({
    timeoutMs: options.timeoutMs ?? DEFAULT_TIMEOUT_MS,
    model: options.hermesModel ?? process.env.HERMES_GLASSES_MODEL
  });
  const weatherFetch = options.weatherFetch ?? globalThis.fetch?.bind(globalThis);
  const upload = makeUpload();
  const app = express();

  app.disable("x-powered-by");
  app.set("trust proxy", true);

  if (options.rateLimit !== false) {
    app.use(
      "/api/glasses/ask",
      rateLimit({
        windowMs: 60_000,
        limit: 20,
        standardHeaders: true,
        legacyHeaders: false,
        message: { error: "rate_limited" }
      })
    );
  }

  app.post("/api/glasses/ask", (req, res, next) => {
    const suppliedToken = bearerTokenFrom(req.get("authorization"));
    if (!secureEquals(suppliedToken, appToken)) {
      res.status(401).json({ error: "unauthorized" });
      return;
    }

    upload.single("image")(req, res, async (uploadError) => {
      let imagePath;
      let responsePayload;
      try {
        if (uploadError) {
          throw mapUploadError(uploadError);
        }

        imagePath = req.file?.path;
        const text = typeof req.body?.text === "string" ? req.body.text.trim() : "";
        const sessionId = typeof req.body?.sessionId === "string" && req.body.sessionId.trim()
          ? req.body.sessionId.trim()
          : uuidv4();

        if (!text) {
          throw new HttpError(400, "text_required");
        }
        if ([...text].length > MAX_TEXT_CHARS) {
          throw new HttpError(413, "text_too_large");
        }

        const weatherResponse = await createWeatherGlassesResponse(text, sessionId, weatherFetch);
        if (weatherResponse) {
          responsePayload = weatherResponse;
        } else {
          const result = await withHermesSlot(() => runHermes({ text, imagePath, sessionId }));
          responsePayload = {
            answer: result.answer ?? "",
            sessionId: result.sessionId ?? sessionId
          };
        }
      } catch (error) {
        next(error);
        return;
      } finally {
        if (imagePath) {
          await fs.rm(imagePath, { force: true }).catch(() => {});
        }
      }

      res.json(responsePayload);
    });
  });

  app.use((error, _req, res, _next) => {
    const status = Number.isInteger(error.status) ? error.status : 500;
    const code = error.code ?? "internal_error";
    res.status(status).json({ error: code });
  });

  return app;
}

export const limits = {
  maxTextChars: MAX_TEXT_CHARS,
  maxImageBytes: MAX_IMAGE_BYTES,
  timeoutMs: DEFAULT_TIMEOUT_MS
};

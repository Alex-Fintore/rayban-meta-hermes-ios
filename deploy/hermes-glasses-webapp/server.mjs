import { createReadStream } from "node:fs";
import { rm, stat, writeFile } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { execFile } from "node:child_process";
import { randomUUID, timingSafeEqual } from "node:crypto";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const publicDir = path.join(__dirname, "public");

const host = process.env.HOST || "127.0.0.1";
const port = Number(process.env.PORT || 8765);
const appToken = process.env.APP_TOKEN || "";
const hermesCmd = process.env.HERMES_CMD || "/usr/local/bin/hermes";
const hermesTimeoutMs = Number(process.env.HERMES_TIMEOUT_MS || 240000);
const hermesMaxTurns = String(process.env.HERMES_MAX_TURNS || "1");
const hermesSource = process.env.HERMES_SOURCE || "rayban-webapp";
const hermesGlassesSource = process.env.HERMES_GLASSES_SOURCE || "rayban-ios";
const hermesGlassesModel = process.env.HERMES_GLASSES_MODEL || "";
const hermesGlassesIgnoreRules = process.env.HERMES_GLASSES_IGNORE_RULES !== "0";
const maxPromptChars = Number(process.env.MAX_PROMPT_CHARS || 2000);
const maxConcurrent = Number(process.env.MAX_CONCURRENT_HERMES || 1);
const maxImageBytes = Number(process.env.MAX_IMAGE_BYTES || 5 * 1024 * 1024);
const weatherMarkers = [
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
const weatherFillerWords = new Set([
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
const weatherCodeLabels = new Map([
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

if (!appToken) {
  console.error("APP_TOKEN is required");
  process.exit(1);
}

const mimeTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".css", "text/css; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".svg", "image/svg+xml"],
  [".png", "image/png"],
  [".ico", "image/x-icon"]
]);

const rateLimits = new Map();
let activeHermes = 0;

function sendJson(res, status, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(body)
  });
  res.end(body);
}

function getClientIp(req) {
  const forwarded = req.headers["x-forwarded-for"];
  if (typeof forwarded === "string" && forwarded.trim()) {
    return forwarded.split(",")[0].trim();
  }
  return req.socket.remoteAddress || "unknown";
}

function checkRateLimit(ip) {
  const now = Date.now();
  const windowMs = 60_000;
  const limit = 20;
  const bucket = rateLimits.get(ip) || [];
  const recent = bucket.filter((ts) => now - ts < windowMs);
  recent.push(now);
  rateLimits.set(ip, recent);
  return recent.length <= limit;
}

function isAuthorized(req) {
  const auth = req.headers.authorization || "";
  const token = auth.startsWith("Bearer ") ? auth.slice(7).trim() : "";
  if (!token) return false;
  const tokenBytes = Buffer.from(token);
  const appTokenBytes = Buffer.from(appToken);
  return tokenBytes.length === appTokenBytes.length && timingSafeEqual(tokenBytes, appTokenBytes);
}

function readBody(req, limitBytes = 24 * 1024) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.setEncoding("utf8");
    req.on("data", (chunk) => {
      body += chunk;
      if (Buffer.byteLength(body, "utf8") > limitBytes) {
        reject(Object.assign(new Error("Payload too large"), { statusCode: 413 }));
        req.destroy();
      }
    });
    req.on("end", () => resolve(body));
    req.on("error", reject);
  });
}

function readBinaryBody(req, limitBytes) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    req.on("data", (chunk) => {
      total += chunk.length;
      if (total > limitBytes) {
        reject(Object.assign(new Error("Payload too large"), { statusCode: 413 }));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on("end", () => resolve(Buffer.concat(chunks)));
    req.on("error", reject);
  });
}

function stripAnsi(value) {
  return value.replace(/\x1B\[[0-?]*[ -/]*[@-~]/g, "");
}

function parseHermesOutput(stdout, stderr) {
  const cleanOut = stripAnsi(stdout || "").replace(/\r\n/g, "\n");
  const cleanErr = stripAnsi(stderr || "").replace(/\r\n/g, "\n");
  const match = `${cleanOut}\n${cleanErr}`.match(/(?:^|\n)session_id:\s*([A-Za-z0-9_-]+)/);
  const sessionId = match ? match[1] : "";
  const answer = cleanOut
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
  return weatherMarkers.some((marker) => lowerText.includes(marker));
}

function weatherLocationFrom(text) {
  const meaningfulWords = normalizeWords(text).filter((word) => {
    if (weatherFillerWords.has(word)) return false;
    return !weatherMarkers.some((marker) => word.includes(marker));
  });
  return meaningfulWords.join(" ").trim();
}

function createFastGlassesResponse(text, sessionId = "") {
  if (!isWeatherRequest(text)) return null;

  if (weatherLocationFrom(text)) return null;

  return {
    answer: "Нужен город или место, чтобы сказать погоду. Скажите, например: погода Москва или погода Алматы.",
    sessionId: sessionId || randomUUID()
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
  const current = forecast.current || {};
  const units = forecast.current_units || {};
  const daily = forecast.daily || {};
  const placeName = [place.name, place.country].filter(Boolean).join(", ");
  const temperatureUnit = localizedWeatherUnit(units.temperature_2m, "°C");
  const windUnit = localizedWeatherUnit(units.wind_speed_10m, "км/ч");
  const precipitationUnit = localizedWeatherUnit(units.precipitation, "мм");
  const description = weatherCodeLabels.get(current.weather_code) || "погода обновлена";
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

async function fetchJson(url) {
  const response = await fetch(url);
  if (!response.ok) {
    throw new Error(`Weather API failed with status ${response.status}`);
  }
  return response.json();
}

async function createWeatherGlassesResponse(text, sessionId = "") {
  if (!isWeatherRequest(text)) return null;

  const missingLocationResponse = createFastGlassesResponse(text, sessionId);
  if (missingLocationResponse) return missingLocationResponse;

  const location = weatherLocationFrom(text);
  try {
    const geocodeUrl = new URL("https://geocoding-api.open-meteo.com/v1/search");
    geocodeUrl.searchParams.set("name", location);
    geocodeUrl.searchParams.set("count", "1");
    geocodeUrl.searchParams.set("language", "ru");
    geocodeUrl.searchParams.set("format", "json");
    const geocode = await fetchJson(geocodeUrl);
    const place = geocode.results?.[0];
    if (!place) {
      return {
        answer: `Не нашёл место «${location}». Назовите город или страну чуть точнее.`,
        sessionId: sessionId || randomUUID()
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
    const forecast = await fetchJson(forecastUrl);

    return {
      answer: formatWeatherAnswer(place, forecast),
      sessionId: sessionId || randomUUID()
    };
  } catch {
    return {
      answer: "Не смог быстро получить погоду. Попробуйте ещё раз через минуту или назовите город точнее.",
      sessionId: sessionId || randomUUID()
    };
  }
}

function isHermesSessionId(sessionId) {
  return /^\d{8}_\d{6}_\d{6}$/.test(sessionId || "");
}

function runHermes(prompt, sessionId, options = {}) {
  const args = [
    "chat",
    "-q",
    prompt,
    "-Q",
    "--max-turns",
    hermesMaxTurns,
    "--source",
    options.source || hermesSource
  ];

  if (options.imagePath) {
    args.splice(3, 0, "--image", options.imagePath);
  }

  if (options.model) {
    args.push("-m", options.model);
  }

  if (options.ignoreRules) {
    args.push("--ignore-rules");
  }

  if (options.resumeSession !== false && isHermesSessionId(sessionId)) {
    args.push("--resume", sessionId);
  }

  return new Promise((resolve, reject) => {
    execFile(
      hermesCmd,
      args,
      {
        timeout: hermesTimeoutMs,
        maxBuffer: 1024 * 1024 * 8,
        env: {
          ...process.env,
          HOME: process.env.HOME || "/root",
          HERMES_ACCEPT_HOOKS: "1"
        }
      },
      (error, stdout, stderr) => {
        if (error) {
          const message = stripAnsi(`${stdout || ""}\n${stderr || ""}`).trim();
          reject(Object.assign(error, { publicMessage: message || error.message }));
          return;
        }
        resolve(parseHermesOutput(stdout, stderr));
      }
    );
  });
}

function parseBoundary(contentType) {
  const match = /boundary=(?:"([^"]+)"|([^;]+))/i.exec(contentType || "");
  return match ? (match[1] || match[2]).trim() : "";
}

function parseMultipart(buffer, boundary) {
  const raw = buffer.toString("latin1");
  const delimiter = `--${boundary}`;
  const parts = raw.split(delimiter).slice(1);
  const fields = new Map();
  const files = new Map();

  for (let part of parts) {
    if (!part || part.startsWith("--")) continue;
    if (part.startsWith("\r\n")) part = part.slice(2);
    const headerEnd = part.indexOf("\r\n\r\n");
    if (headerEnd === -1) continue;

    const headerText = part.slice(0, headerEnd);
    let content = part.slice(headerEnd + 4);
    if (content.endsWith("\r\n")) content = content.slice(0, -2);

    const disposition = /content-disposition:\s*form-data;([^\r\n]+)/i.exec(headerText)?.[1] || "";
    const name = /name="([^"]+)"/i.exec(disposition)?.[1] || "";
    if (!name) continue;

    const filename = /filename="([^"]*)"/i.exec(disposition)?.[1] || "";
    const contentType = /content-type:\s*([^\r\n]+)/i.exec(headerText)?.[1]?.trim().toLowerCase() || "";
    const data = Buffer.from(content, "latin1");

    if (filename) {
      files.set(name, { filename, contentType, data });
    } else {
      fields.set(name, data.toString("utf8"));
    }
  }

  return { fields, files };
}

function errorCodeForStatus(status) {
  if (status === 413) return "image_too_large";
  return "invalid_multipart";
}

async function handleGlassesAsk(req, res) {
  const ip = getClientIp(req);
  if (!checkRateLimit(ip)) {
    sendJson(res, 429, { error: "rate_limited" });
    return;
  }

  if (!isAuthorized(req)) {
    sendJson(res, 401, { error: "unauthorized" });
    return;
  }

  const boundary = parseBoundary(req.headers["content-type"]);
  if (!boundary) {
    sendJson(res, 400, { error: "invalid_multipart" });
    return;
  }

  let imagePath = "";
  let sessionId = "";
  let acquiredHermes = false;
  try {
    const body = await readBinaryBody(req, maxImageBytes + 32 * 1024);
    const multipart = parseMultipart(body, boundary);
    const text = String(multipart.fields.get("text") || "").trim();
    sessionId = String(multipart.fields.get("sessionId") || "").trim();

    if (!text) {
      sendJson(res, 400, { error: "text_required" });
      return;
    }
    if ([...text].length > maxPromptChars) {
      sendJson(res, 413, { error: "text_too_large" });
      return;
    }

    const image = multipart.files.get("image");
    if (image) {
      if (!["image/jpeg", "image/png"].includes(image.contentType)) {
        sendJson(res, 415, { error: "unsupported_image_type" });
        return;
      }
      if (image.data.length > maxImageBytes) {
        sendJson(res, 413, { error: "image_too_large" });
        return;
      }
      const extension = image.contentType === "image/png" ? ".png" : ".jpg";
      imagePath = path.join(os.tmpdir(), `rayban-hermes-${randomUUID()}${extension}`);
      await writeFile(imagePath, image.data);
    }

    const weatherResponse = await createWeatherGlassesResponse(text, sessionId);
    if (weatherResponse) {
      sendJson(res, 200, weatherResponse);
      return;
    }

    if (activeHermes >= maxConcurrent) {
      sendJson(res, 429, { error: "hermes_busy" });
      return;
    }

    activeHermes += 1;
    acquiredHermes = true;
    let result = await runHermes(text, sessionId, {
      imagePath,
      source: hermesGlassesSource,
      model: hermesGlassesModel,
      ignoreRules: hermesGlassesIgnoreRules,
      resumeSession: false
    });
    if (!result.answer) {
      result = await runHermes(text, sessionId, {
        imagePath,
        source: hermesGlassesSource,
        model: hermesGlassesModel,
        ignoreRules: hermesGlassesIgnoreRules,
        resumeSession: false
      });
    }
    sendJson(res, 200, {
      answer: result.answer || "(empty response)",
      sessionId: result.sessionId || sessionId || randomUUID()
    });
  } catch (error) {
    const status = error.statusCode || 502;
    sendJson(res, status, {
      error: status === 502 ? "hermes_failed" : errorCodeForStatus(status),
      detail: status === 502 ? String(error.publicMessage || error.message || "Unknown error").slice(0, 2000) : undefined
    });
  } finally {
    if (acquiredHermes) activeHermes -= 1;
    if (imagePath) {
      await rm(imagePath, { force: true }).catch(() => {});
    }
  }
}

async function handleChat(req, res) {
  const ip = getClientIp(req);
  if (!checkRateLimit(ip)) {
    sendJson(res, 429, { error: "Too many requests" });
    return;
  }

  if (!isAuthorized(req)) {
    sendJson(res, 401, { error: "Unauthorized" });
    return;
  }

  if (activeHermes >= maxConcurrent) {
    sendJson(res, 429, { error: "Hermes is busy" });
    return;
  }

  let payload;
  try {
    payload = JSON.parse(await readBody(req));
  } catch (error) {
    sendJson(res, error.statusCode || 400, { error: "Invalid request" });
    return;
  }

  const message = String(payload.message || "").trim();
  const sessionId = String(payload.sessionId || "").trim();
  if (!message) {
    sendJson(res, 400, { error: "Empty message" });
    return;
  }
  if (message.length > maxPromptChars) {
    sendJson(res, 400, { error: `Message is too long, max ${maxPromptChars} characters` });
    return;
  }

  activeHermes += 1;
  try {
    let result = await runHermes(message, sessionId);
    if (!result.answer) {
      result = await runHermes(message, sessionId);
    }
    sendJson(res, 200, {
      answer: result.answer || "(empty response)",
      sessionId: result.sessionId || sessionId || null
    });
  } catch (error) {
    sendJson(res, 502, {
      error: "Hermes failed",
      detail: String(error.publicMessage || error.message || "Unknown error").slice(0, 2000)
    });
  } finally {
    activeHermes -= 1;
  }
}

async function serveStatic(req, res) {
  let pathname;
  try {
    const rawUrl = new URL(req.url || "/", `http://${req.headers.host || "localhost"}`);
    pathname = decodeURIComponent(rawUrl.pathname);
  } catch {
    res.writeHead(400, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Bad request");
    return;
  }
  if (pathname === "/") pathname = "/index.html";
  const safePath = path.normalize(pathname).replace(/^(\.\.[/\\])+/, "");
  const filePath = path.join(publicDir, safePath);

  if (!filePath.startsWith(publicDir)) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }

  try {
    const info = await stat(filePath);
    if (!info.isFile()) throw new Error("not a file");
    res.writeHead(200, {
      "Content-Type": mimeTypes.get(path.extname(filePath)) || "application/octet-stream",
      "Cache-Control": pathname === "/index.html" ? "no-store" : "public, max-age=3600"
    });
    createReadStream(filePath).pipe(res);
  } catch {
    res.writeHead(404, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("Not found");
  }
}

const server = http.createServer(async (req, res) => {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "no-referrer");

  if (req.method === "GET" && req.url === "/health") {
    sendJson(res, 200, { ok: true, activeHermes });
    return;
  }

  if (req.method === "POST" && req.url === "/api/chat") {
    await handleChat(req, res);
    return;
  }

  if (req.method === "POST" && req.url === "/api/glasses/ask") {
    await handleGlassesAsk(req, res);
    return;
  }

  if (req.method === "GET" || req.method === "HEAD") {
    await serveStatic(req, res);
    return;
  }

  res.writeHead(405, { "Allow": "GET, POST, HEAD" });
  res.end("Method not allowed");
});

server.listen(port, host, () => {
  console.log(`Hermes glasses web app listening on http://${host}:${port}`);
});

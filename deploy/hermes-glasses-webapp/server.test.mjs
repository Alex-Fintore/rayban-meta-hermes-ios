import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import http from "node:http";
import net from "node:net";
import test from "node:test";
import { fileURLToPath } from "node:url";

test("invalid URLs return 400 and leave the server healthy", { timeout: 10000 }, async () => {
  const reservation = net.createServer().listen(0, "127.0.0.1");
  await once(reservation, "listening");
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const child = spawn(process.execPath, [fileURLToPath(new URL("server.mjs", import.meta.url))], {
    env: { PATH: process.env.PATH, HOST: "127.0.0.1", PORT: String(port), APP_TOKEN: "local-test" },
    stdio: ["ignore", "pipe", "pipe"]
  });
  const request = (url, headers = {}) => new Promise((resolve, reject) => {
    const req = http.get({ hostname: "127.0.0.1", port, path: url, headers }, res => {
      res.resume();
      res.on("end", () => resolve(res.statusCode));
    });
    req.on("error", reject);
    req.setTimeout(2000, () => req.destroy(new Error("request timeout")));
  });
  try {
    await Promise.race([
      once(child.stdout, "data"),
      once(child, "exit").then(() => { throw new Error("server exited during startup"); })
    ]);
    assert.equal(await request("/%E0%A4%A"), 400);
    assert.equal(await request("/", { Host: "[invalid" }), 400);
    assert.equal(await request("/health"), 200);
    assert.equal(await request("/__missing_test_asset__"), 404);
  } finally {
    if (child.exitCode === null) {
      const stopped = once(child, "exit");
      child.kill();
      await stopped;
    }
  }
});

/*
 * 市场动态与制造核算台 —— 本地服务器（主项目/母版本）v1.1
 * Copyright (C) 2026 Junchen-lich
 *
 * 功能：
 *   1. 在同源地址提供本应用的 HTML 页面与内置数据 JSON；
 *   2. /api /infapi /tqapi 前缀转发到市场数据服务；
 *   3. /publiccontracts/ 转发到官方公开合同接口；
 *   4. /userdata/<key> 读写“用户数据”目录下的个人数据文件（角色库、收藏、
 *      手动记录、自定义生产时间等），取代浏览器 localStorage；
 *   5. 端口自动回退：默认 8657，被占用时自动改用空闲端口并打开浏览器。
 *
 * 数据文件放在“data”子目录；用户数据保存在程序目录下的“用户数据”文件夹。
 */
"use strict";
const http = require("http");
const https = require("https");
const fs = require("fs");
const path = require("path");

const ROOT = __dirname;
const DATA_DIR = path.join(ROOT, "data");
const USER_DIR = path.join(ROOT, "用户数据");

const PORT = Number(process.env.PORT) || 8657;
const UPSTREAM = "www.ceve-market.org";

// 数据路由 → data 目录下的文件名
const DATA_FILES = {
  "/blueprints.json": ["blueprints.json", "application/json; charset=utf-8"],
  "/blueprint_times.json": ["blueprint_times.json", "application/json; charset=utf-8"],
  "/market_groups.json": ["market_groups.json", "application/json; charset=utf-8"],
  "/item_names.json": ["item_names.json", "application/json; charset=utf-8"],
  "/industry.json": ["industry.json", "application/json; charset=utf-8"],
  "/pi.json": ["pi.json", "application/json; charset=utf-8"],
  "/universe.json": ["universe.json", "application/json; charset=utf-8"],
  "/_ores.json": ["_ores.json", "application/json; charset=utf-8"],
  "/stations.json": ["stations.json", "application/json; charset=utf-8"],
  "/structures.json": ["structures.json", "application/json; charset=utf-8"],
};

function serveFile(res, filename, contentType) {
  fs.readFile(path.join(DATA_DIR, filename), (err, data) => {
    if (err) {
      res.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
      return res.end("无法读取资源：" + err.message);
    }
    res.writeHead(200, { "Content-Type": contentType, "Cache-Control": "no-cache" });
    res.end(data);
  });
}

function serveHtml(req, res) {
  fs.readFile(path.join(ROOT, "市场动态与制造核算台.html"), (err, data) => {
    if (err) {
      res.writeHead(500, { "Content-Type": "text/plain; charset=utf-8" });
      return res.end("无法读取页面：" + err.message);
    }
    res.writeHead(200, { "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-cache" });
    res.end(data);
  });
}

// ---- 用户数据读写（保存到程序目录下“用户数据”文件夹） ----
function readUserData(key) {
  const file = path.join(USER_DIR, key + ".json");
  try { return JSON.parse(fs.readFileSync(file, "utf8")); }
  catch (e) { return null; }
}
function writeUserData(key, data) {
  try {
    if (!fs.existsSync(USER_DIR)) fs.mkdirSync(USER_DIR, { recursive: true });
    fs.writeFileSync(path.join(USER_DIR, key + ".json"), JSON.stringify(data, null, 2), "utf8");
    return true;
  } catch (e) { return false; }
}

function handleUserData(req, res, p) {
  const parts = p.split("/");
  const key = decodeURIComponent(parts[2] || "").replace(/[^a-zA-Z0-9_-]/g, "");
  if (!key) {
    res.writeHead(400, { "Content-Type": "application/json; charset=utf-8" });
    return res.end(JSON.stringify({ error: "缺少有效的数据键" }));
  }
  if (req.method === "GET") {
    const data = readUserData(key);
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-cache" });
    // 缺失返回 JSON null（语义同 localStorage.getItem 未命中），前端据此取默认值
    return res.end(data === null ? "null" : JSON.stringify(data));
  }
  if (req.method === "PUT") {
    let body = "";
    req.on("data", (c) => { body += c; if (body.length > 50 * 1024 * 1024) req.destroy(); });
    req.on("end", () => {
      let parsed = null;
      try { parsed = JSON.parse(body); } catch (e) { /* 保留空 */ }
      if (parsed === null || typeof parsed !== "object") {
        res.writeHead(400, { "Content-Type": "application/json; charset=utf-8" });
        return res.end(JSON.stringify({ error: "请求体不是有效 JSON 对象" }));
      }
      const ok = writeUserData(key, parsed);
      res.writeHead(ok ? 200 : 500, { "Content-Type": "application/json; charset=utf-8" });
      res.end(JSON.stringify({ ok: ok }));
    });
    return;
  }
  res.writeHead(405, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify({ error: "仅支持 GET/PUT" }));
}

// ---- 转发代理 ----
function proxy(req, res) {
  const options = {
    host: UPSTREAM,
    path: req.url,
    method: req.method,
    headers: Object.assign({}, req.headers, { Host: UPSTREAM }),
    timeout: 30000,
  };
  const upstream = https.request(options, (ures) => {
    const headers = Object.assign({}, ures.headers);
    delete headers["transfer-encoding"];
    delete headers.connection;
    res.writeHead(ures.statusCode || 502, headers);
    ures.pipe(res);
  });
  upstream.on("error", (e) => {
    res.writeHead(502, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("代理到市场数据服务失败：" + e.message);
  });
  upstream.on("timeout", () => {
    upstream.destroy();
    res.writeHead(504, { "Content-Type": "text/plain; charset=utf-8" });
    res.end("上游请求超时");
  });
  req.on("data", (chunk) => upstream.write(chunk));
  req.on("end", () => upstream.end());
}

function fetchPublicContracts(res, pathStr) {
  https.get({ host: "esi.evetech.net", path: pathStr, headers: { "User-Agent": "MarketCalc/1.0 (local tool)" } }, (ures) => {
    res.writeHead(ures.statusCode || 502, { "Content-Type": "application/json; charset=utf-8" });
    ures.pipe(res);
  }).on("error", (e) => {
    res.writeHead(502, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ error: "官方公开接口请求失败：" + e.message }));
  });
}

const server = http.createServer((req, res) => {
  const p = req.url || "/";
  if (p === "/" || p === "/index.html") return serveHtml(req, res);
  if (p === "/favicon.ico") { res.writeHead(204); return res.end(); }
  if (p in DATA_FILES) {
    const [f, ct] = DATA_FILES[p];
    return serveFile(res, f, ct);
  }
  if (p === "/dbupdate-status") return dbUpdateStatus(req, res);
  if (p === "/dbupdate-run") return dbUpdateRun(req, res);
  if (p === "/dbupdate-ignore") return dbUpdateIgnore(req, res);
  if (p.startsWith("/userdata/")) return handleUserData(req, res, p);
  if (p.startsWith("/api/") || p.startsWith("/infapi/") || p.startsWith("/tqapi/")) return proxy(req, res);
  if (p.startsWith("/publiccontracts/")) {
    const region = decodeURIComponent(p.split("/")[2] || "").replace(/[^0-9]/g, "");
    if (!region) { res.writeHead(400, { "Content-Type": "application/json; charset=utf-8" }); return res.end(JSON.stringify({ error: "缺少有效的 regionId" })); }
    return fetchPublicContracts(res, "/latest/contracts/public/" + region + "/?datasource=tranquility&page=1");
  }
  return serveHtml(req, res);
});

// 端口自动回退：端口被占用时递增重试，避免进程崩溃闪退
let currentPort = PORT;
server.on("error", (err) => {
  if (err.code === "EADDRINUSE" && currentPort < PORT + 20) {
    currentPort += 1;
    console.log("端口 " + (currentPort - 1) + " 被占用，自动改用 " + currentPort);
    server.listen(currentPort);
  } else {
    console.error("服务器启动失败: " + err.message);
    process.exit(1);
  }
});
server.listen(currentPort, () => {
  console.log("市场动态与制造核算台 已在 http://localhost:" + currentPort + " 运行");
  console.log("用户数据目录: " + USER_DIR);
  console.log("按 Ctrl+C 停止。");
  try {
    if (!fs.existsSync(USER_DIR)) fs.mkdirSync(USER_DIR, { recursive: true });
    fs.writeFileSync(path.join(USER_DIR, "server.port"), String(currentPort), "utf8");
  } catch (e) { /* 端口记录失败不影响运行 */ }
  if (!process.env.NO_AUTO_OPEN) {
    try {
      const { exec } = require("child_process");
      exec('start "" http://localhost:' + currentPort);
    } catch (e) { /* 忽略：手动打开即可 */ }
  }
});

// ---- 每日数据库更新提示：每天 8:00 后首次打开时，提示用户下载 evedata.xlsx，可更新或忽略 ----
const DB_PROMPT_FILE = path.join(DATA_DIR, "_db_prompt_last.json");
let dbRunning = false;

function todayStr() {
  const d = new Date();
  const y = d.getFullYear();
  const m = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  return y + "-" + m + "-" + dd;
}
function readPromptDate() {
  try { return (JSON.parse(fs.readFileSync(DB_PROMPT_FILE, "utf8")).date) || ""; }
  catch (e) { return ""; }
}
function writePromptDate(date) {
  try { fs.writeFileSync(DB_PROMPT_FILE, JSON.stringify({ date, time: new Date().toISOString() }), "utf8"); }
  catch (e) { /* 记录失败不影响 */ }
}
// 状态：今天尚未提示过、且当前时间 >= 08:00，才需要提示
function dbUpdateStatus(req, res) {
  const now = new Date();
  const today = todayStr();
  const last = readPromptDate();
  const needs = today !== last && now.getHours() >= 8;
  res.writeHead(200, { "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-cache" });
  res.end(JSON.stringify({ today, lastPromptDate: last, needsPrompt: needs, nowHour: now.getHours(), dataDir: DATA_DIR }));
}
// 用户选择“忽略”，记录今日已提示，本次使用现有数据库
function dbUpdateIgnore(req, res) {
  writePromptDate(todayStr());
  res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
  res.end(JSON.stringify({ ok: true, message: "已记录，本次使用现有数据库" }));
}
// 用户点击“确定”（已把 evedata.xlsx 放到 data 目录），执行数据库更新
function dbUpdateRun(req, res) {
  if (dbRunning) {
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    return res.end(JSON.stringify({ ok: false, busy: true, message: "数据库更新正在进行中，请稍候" }));
  }
  const { execFile } = require("child_process");
  const py = path.join(ROOT, "开发脚本", "_update_db.py");
  dbRunning = true;
  const start = Date.now();
  execFile("python", [py], { timeout: 300000 }, (err, stdout, stderr) => {
    dbRunning = false;
    writePromptDate(todayStr());
    const out = String(stdout || "").trim().replace(/\s+/g, " ") || (err ? String(err.message) : "已完成");
    console.log("[" + new Date().toLocaleString("zh-CN") + "] 数据库更新:", out);
    res.writeHead(200, { "Content-Type": "application/json; charset=utf-8" });
    res.end(JSON.stringify({ ok: !err, message: out, elapsedMs: Date.now() - start }));
  });
}

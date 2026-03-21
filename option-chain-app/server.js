require("dotenv").config();
const express = require("express");
const http = require("http");
const { WebSocketServer } = require("ws");
const WebSocket = require("ws");
const axios = require("axios");
const { authenticator } = require("otplib");
const { Parser } = require("binary-parser");
const os = require("os");

const app = express();
const server = http.createServer(app);
const wss = new WebSocketServer({ server });
app.use(express.static("public"));

// ==================== API CONFIG ====================
const API_BASE = "https://apiconnect.angelone.in";
const ENDPOINTS = {
  login: `${API_BASE}/rest/auth/angelbroking/user/v1/loginByPassword`,
  marketData: `${API_BASE}/rest/secure/angelbroking/market/v1/quote`,
};
const WS_URL = "wss://smartapisocket.angelone.in/smart-stream";
const INSTRUMENT_URL =
  "https://margincalculator.angelbroking.com/OpenAPI_File/files/OpenAPIScripMaster.json";

const ACTION = { Subscribe: 1, Unsubscribe: 0 };
const MODE = { LTP: 1, Quote: 2, SnapQuote: 3, Depth: 4 };
const EXCHANGE_TYPES = {
  nse_cm: 1, nse_fo: 2, bse_cm: 3, bse_fo: 4, mcx_fo: 5, ncx_fo: 7, cde_fo: 13,
};

// ==================== INDEX CONFIG ====================
const INDEX_CONFIG = {
  NIFTY:       { exchange: "NSE", token: "99926000", optExchange: "NFO", interval: 50, optType: "OPTIDX", name: "NIFTY" },
  BANKNIFTY:   { exchange: "NSE", token: "99926009", optExchange: "NFO", interval: 100, optType: "OPTIDX", name: "BANKNIFTY" },
  FINNIFTY:    { exchange: "NSE", token: "99926037", optExchange: "NFO", interval: 50, optType: "OPTIDX", name: "FINNIFTY" },
  MIDCPNIFTY:  { exchange: "NSE", token: "99926074", optExchange: "NFO", interval: 25, optType: "OPTIDX", name: "MIDCPNIFTY" },
  SENSEX:      { exchange: "BSE", token: "99919000", optExchange: "BFO", interval: 100, optType: "OPTIDX", name: "SENSEX" },
  BANKEX:      { exchange: "BSE", token: "99919015", optExchange: "BFO", interval: 100, optType: "OPTIDX", name: "BANKEX" },
};

// ==================== GLOBAL STATE ====================
let authToken = null;
let feedToken = null;
let clientCode = null;
let apiKey = null;
let instrumentCache = null;
let instrumentCacheDate = null;
let angelWs = null;
let pingInterval = null;
let pollingInterval = null;
let currentSubscription = null;
let localIP = null;
let publicIP = null;
let macAddress = null;

const browserClients = new Set();
const livePrices = {};

// ==================== NETWORK HELPERS ====================
function getLocalIP() {
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const iface of ifaces[name]) {
      if (!iface.internal && iface.family === "IPv4") return iface.address;
    }
  }
  return "192.168.1.1";
}

function getMACAddress() {
  const ifaces = os.networkInterfaces();
  for (const name of Object.keys(ifaces)) {
    for (const iface of ifaces[name]) {
      if (!iface.internal && iface.family === "IPv4" && iface.mac !== "00:00:00:00:00:00")
        return iface.mac;
    }
  }
  return "fe:80:21:6e:65:07";
}

async function getPublicIP() {
  try {
    const r = await axios.get("https://api.ipify.org?format=json", { timeout: 5000 });
    return r.data.ip;
  } catch {
    try {
      const r = await axios.get("https://ifconfig.me/ip", { timeout: 5000 });
      return r.data.trim();
    } catch {
      return "106.193.147.98";
    }
  }
}

async function initNetwork() {
  localIP = getLocalIP();
  macAddress = getMACAddress();
  publicIP = await getPublicIP();
  console.log(`🌐 IP: ${localIP} | Public: ${publicIP} | MAC: ${macAddress}`);
}

function baseHeaders() {
  return {
    "Content-Type": "application/json",
    Accept: "application/json",
    "X-UserType": "USER",
    "X-SourceID": "WEB",
    "X-PrivateKey": apiKey,
    "X-ClientLocalIP": localIP,
    "X-ClientPublicIP": publicIP,
    "X-MACAddress": macAddress,
  };
}

function authHeaders() {
  return { ...baseHeaders(), Authorization: `Bearer ${authToken}` };
}

// ==================== LOGIN ====================
async function login() {
  try {
    apiKey = process.env.ANGEL_API_KEY;
    clientCode = process.env.ANGEL_CLIENT_ID;
    const password = process.env.ANGEL_PASSWORD;
    const totpSecret = process.env.ANGEL_TOTP_SECRET;

    if (!apiKey || !clientCode || !password || !totpSecret) {
      throw new Error("Missing credentials in .env");
    }

    await initNetwork();

    const totp = authenticator.generate(totpSecret);

    const res = await axios.post(
      ENDPOINTS.login,
      { clientcode: clientCode, password, totp },
      { headers: baseHeaders(), timeout: 15000 }
    );

    if (!res.data.status) throw new Error(`${res.data.message} (${res.data.errorcode})`);

    authToken = res.data.data.jwtToken;
    feedToken = res.data.data.feedToken;
    console.log("✅ Login successful");
    return true;
  } catch (err) {
    console.error("❌ Login failed:", err.response?.data?.message || err.message);
    return false;
  }
}

// ==================== MARKET DATA ====================
async function getMarketData(exchange, tokens, mode = "LTP") {
  try {
    const res = await axios.post(
      ENDPOINTS.marketData,
      { mode, exchangeTokens: { [exchange]: tokens } },
      { headers: authHeaders(), timeout: 10000 }
    );
    return res.data;
  } catch (err) {
    console.error("❌ MarketData:", err.response?.data?.message || err.message);
    return null;
  }
}

// ==================== INSTRUMENTS ====================
async function loadInstruments() {
  const today = new Date().toISOString().split("T")[0];
  if (instrumentCache && instrumentCacheDate === today) {
    console.log("📁 Cached instruments");
    return instrumentCache;
  }
  console.log("⬇️  Downloading instruments (~50MB)...");
  try {
    const r = await axios.get(INSTRUMENT_URL, { timeout: 120000 });
    instrumentCache = r.data;
    instrumentCacheDate = today;
    console.log(`✅ ${instrumentCache.length} instruments loaded`);
    return instrumentCache;
  } catch (err) {
    console.error("❌ Download failed:", err.message);
    return [];
  }
}

// ==================== BUILD OPTION CHAIN ====================
function parseExpiry(s) {
  if (!s) return new Date(0);
  const m = { JAN:0, FEB:1, MAR:2, APR:3, MAY:4, JUN:5, JUL:6, AUG:7, SEP:8, OCT:9, NOV:10, DEC:11 };
  const match = s.match(/^(\d{2})([A-Z]{3})(\d{4})$/);
  if (match) return new Date(parseInt(match[3]), m[match[2]], parseInt(match[1]));
  return new Date(s);
}

async function buildOptionChain(symbol, expiryIndex = 0, strikeRange = 10) {
  const upper = symbol.toUpperCase();
  const config = INDEX_CONFIG[upper];
  if (!config) return { error: `Unknown index: ${upper}` };

  const instruments = await loadInstruments();

  // Get spot
  const spotData = await getMarketData(config.exchange, [config.token], "LTP");
  if (!spotData?.status || !spotData?.data?.fetched?.length)
    return { error: `Could not fetch ${upper} spot price` };

  const spotPrice = spotData.data.fetched[0].ltp;
  console.log(`✅ ${upper} Spot: ₹${spotPrice}`);

  // Filter options
  const options = instruments.filter(
    (i) => i.name === config.name && i.exch_seg === config.optExchange && i.instrumenttype === config.optType
  );
  if (!options.length) return { error: `No options for ${upper}` };

  // Expiries
  const expiries = [...new Set(options.map((o) => o.expiry))]
    .sort((a, b) => parseExpiry(a) - parseExpiry(b));
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const future = expiries.filter((e) => parseExpiry(e) >= today);
  if (!future.length) return { error: "No upcoming expiries" };

  const selectedExpiry = future[Math.min(expiryIndex, future.length - 1)];

  // ATM & range
  const atm = Math.round(spotPrice / config.interval) * config.interval;
  const lo = atm - strikeRange * config.interval;
  const hi = atm + strikeRange * config.interval;

  // Build maps
  const strikeMap = {};
  const tokenList = [];
  const tokenInfoMap = {};

  for (const opt of options) {
    const strike = parseFloat(opt.strike) / 100;
    if (opt.expiry !== selectedExpiry || strike < lo || strike > hi) continue;
    if (!strikeMap[strike]) strikeMap[strike] = { ce: null, pe: null };
    const t = opt.symbol.endsWith("CE") ? "ce" : "pe";
    strikeMap[strike][t] = { token: opt.token, symbol: opt.symbol };
    tokenList.push(opt.token);
    tokenInfoMap[opt.token] = { strike, type: t.toUpperCase(), symbol: opt.symbol };
  }

  console.log(`📅 ${selectedExpiry} | ATM: ${atm} | Tokens: ${tokenList.length}`);

  return {
    symbol: upper, spotPrice, atmStrike: atm, selectedExpiry,
    allExpiries: future, interval: config.interval,
    exchange: config.optExchange, strikeMap, tokenList, tokenInfoMap,
    strikes: Object.keys(strikeMap).map(Number).sort((a, b) => a - b),
  };
}

// ==================== BATCH FETCH PRICES ====================
async function fetchPrices(chainData) {
  const ex = chainData.exchange;
  const tokens = chainData.tokenList;
  for (let i = 0; i < tokens.length; i += 50) {
    const batch = tokens.slice(i, i + 50);
    const data = await getMarketData(ex, batch, "FULL");
    if (data?.status && data?.data?.fetched) {
      for (const item of data.data.fetched) {
        livePrices[String(item.symbolToken)] = {
          ltp: item.ltp || 0, open: item.open || 0, high: item.high || 0,
          low: item.low || 0, close: item.close || 0,
        };
      }
      console.log(`✅ Batch ${Math.floor(i / 50) + 1}: ${data.data.fetched.length} prices`);
    }
    if (i + 50 < tokens.length) await new Promise((r) => setTimeout(r, 300));
  }
}

// ==================== BINARY PARSERS ====================
function _atos(arr) {
  let s = "";
  for (let i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i]);
  return s.replace(/\0/g, "").replace(/"/g, "");
}
function toNum(n) { return n.toString(); }

function parseLTP(b) {
  return new Parser().endianness("little")
    .int8("sub_mode", { formatter: toNum })
    .int8("exch_type", { formatter: toNum })
    .array("token", { type: "uint8", length: 25, formatter: _atos })
    .int64("seq", { formatter: toNum })
    .int64("exch_ts", { formatter: toNum })
    .int32("last_traded_price", { formatter: toNum })
    .parse(b);
}

function parseQuote(b) {
  return new Parser().endianness("little")
    .uint8("sub_mode", { formatter: toNum })
    .uint8("exch_type", { formatter: toNum })
    .array("token", { type: "int8", length: 25, formatter: _atos })
    .uint64("seq", { formatter: toNum })
    .uint64("exch_ts", { formatter: toNum })
    .uint64("last_traded_price", { formatter: toNum })
    .int64("last_traded_qty", { formatter: toNum })
    .int64("avg_price", { formatter: toNum })
    .int64("vol_traded", { formatter: toNum })
    .doublele("total_buy_qty", { formatter: toNum })
    .doublele("total_sell_qty", { formatter: toNum })
    .int64("open_price_day", { formatter: toNum })
    .int64("high_price_day", { formatter: toNum })
    .int64("low_price_day", { formatter: toNum })
    .int64("close_price", { formatter: toNum })
    .parse(b);
}

function parseTick(buf) {
  const mode = new Parser().uint8("m").parse(buf)?.m;
  if (mode === MODE.LTP) return parseLTP(buf);
  if (mode === MODE.Quote) return parseQuote(buf);
  return null;
}

// ==================== WEBSOCKET ====================
function connectWS(chainData) {
  if (angelWs) { try { angelWs.removeAllListeners(); angelWs.close(); } catch (e) {} angelWs = null; }
  if (pingInterval) { clearInterval(pingInterval); pingInterval = null; }

  const exType = chainData.exchange === "BFO" ? EXCHANGE_TYPES.bse_fo : EXCHANGE_TYPES.nse_fo;

  angelWs = new WebSocket(WS_URL, {
    headers: {
      Authorization: authToken,
      "x-api-key": apiKey,
      "x-client-code": clientCode,
      "x-feed-token": feedToken,
    },
  });

  let shouldReconnect = true;

  angelWs.on("open", () => {
    console.log("✅ WebSocket connected");
    angelWs.send(JSON.stringify({
      correlationID: "oc",
      action: ACTION.Subscribe,
      params: { mode: MODE.Quote, tokenList: [{ exchangeType: exType, tokens: chainData.tokenList }] },
    }));
    console.log(`📡 Subscribed ${chainData.tokenList.length} tokens`);
    pingInterval = setInterval(() => {
      if (angelWs?.readyState === WebSocket.OPEN) angelWs.send("ping");
    }, 10000);
  });

  angelWs.on("message", (raw) => {
    try {
      const buf = Buffer.from(raw);
      if (buf.length < 10) return;
      if (buf[0] === 123) { console.log("⚠️ Server:", buf.toString()); return; }
      const tick = parseTick(buf);
      if (!tick?.token) return;
      const tk = tick.token.replace(/['"]/g, "").trim();
      if (chainData.tokenInfoMap[tk]) {
        livePrices[tk] = {
          ltp: parseInt(tick.last_traded_price || "0") / 100,
          open: parseInt(tick.open_price_day || "0") / 100,
          high: parseInt(tick.high_price_day || "0") / 100,
          low: parseInt(tick.low_price_day || "0") / 100,
          close: parseInt(tick.close_price || "0") / 100,
        };
        broadcast(chainData);
      }
    } catch (e) {}
  });

  angelWs.on("error", (e) => { console.error("❌ WS:", e.message); });

  angelWs.on("close", (code) => {
    console.log(`🔌 WS closed (${code})`);
    if (pingInterval) clearInterval(pingInterval);
    if (code === 1008 || code === 1003) {
      console.log("❌ Auth error → REST polling");
      shouldReconnect = false;
      startPolling(chainData);
      return;
    }
    if (shouldReconnect && currentSubscription) {
      const now = new Date();
      const h = (now.getUTCHours() + 5 + Math.floor((now.getUTCMinutes() + 30) / 60)) % 24;
      const m = (now.getUTCMinutes() + 30) % 60;
      if (h >= 9 && (h < 15 || (h === 15 && m <= 35))) {
        console.log("🔄 Reconnecting 5s...");
        setTimeout(() => connectWS(currentSubscription), 5000);
      } else {
        console.log("🌙 Market closed → REST polling");
        startPolling(chainData);
      }
    }
  });

  currentSubscription = chainData;
}

// ==================== REST POLLING ====================
function startPolling(chainData) {
  stopPolling();
  console.log("🔄 REST polling (5s)...");
  const poll = async () => { await fetchPrices(chainData); broadcast(chainData); };
  poll();
  pollingInterval = setInterval(poll, 5000);
  currentSubscription = chainData;
}
function stopPolling() { if (pollingInterval) { clearInterval(pollingInterval); pollingInterval = null; } }

// ==================== BROADCAST ====================
function broadcast(chainData) {
  const rows = [];
  for (const strike of chainData.strikes) {
    const ce = chainData.strikeMap[strike]?.ce;
    const pe = chainData.strikeMap[strike]?.pe;
    const ceP = ce ? livePrices[ce.token]?.ltp || 0 : 0;
    const peP = pe ? livePrices[pe.token]?.ltp || 0 : 0;
    const ceI = Math.max(0, chainData.spotPrice - strike);
    const peI = Math.max(0, strike - chainData.spotPrice);
    rows.push({
      strike, isATM: strike === chainData.atmStrike,
      ce: { premium: ceP, intrinsic: ceI, extrinsic: Math.max(0, ceP - ceI), itm: chainData.spotPrice > strike },
      pe: { premium: peP, intrinsic: peI, extrinsic: Math.max(0, peP - peI), itm: chainData.spotPrice < strike },
    });
  }
  const msg = JSON.stringify({
    type: "option_chain", symbol: chainData.symbol, spotPrice: chainData.spotPrice,
    atmStrike: chainData.atmStrike, expiry: chainData.selectedExpiry,
    allExpiries: chainData.allExpiries, rows, timestamp: new Date().toISOString(),
  });
  for (const c of browserClients) { if (c.readyState === 1) c.send(msg); }
}

// ==================== BROWSER WS ====================
wss.on("connection", (ws) => {
  console.log("🌐 Browser connected");
  browserClients.add(ws);
  ws.on("message", async (msg) => {
    try {
      const m = JSON.parse(msg);
      if (m.type === "subscribe") {
        const sym = m.symbol || "NIFTY";
        const ei = m.expiryIndex || 0;
        const sr = m.strikeRange || 10;
        console.log(`\n📥 ${sym} | Expiry: ${ei} | ±${sr}`);
        ws.send(JSON.stringify({ type: "status", message: `Loading ${sym}...` }));
        stopPolling();
        const chain = await buildOptionChain(sym, ei, sr);
        if (chain.error) { ws.send(JSON.stringify({ type: "error", message: chain.error })); return; }
        ws.send(JSON.stringify({
          type: "chain_info", symbol: chain.symbol, spotPrice: chain.spotPrice,
          atmStrike: chain.atmStrike, expiry: chain.selectedExpiry,
          allExpiries: chain.allExpiries, strikes: chain.strikes,
        }));
        ws.send(JSON.stringify({ type: "status", message: `Fetching ${chain.tokenList.length} prices...` }));
        await fetchPrices(chain);
        broadcast(chain);
        ws.send(JSON.stringify({ type: "status", message: `Connecting live...` }));
        connectWS(chain);
        ws.send(JSON.stringify({ type: "status", message: `✅ Live: ${sym}` }));
      }
    } catch (e) {
      ws.send(JSON.stringify({ type: "error", message: e.message }));
    }
  });
  ws.on("close", () => { browserClients.delete(ws); console.log("🌐 Browser disconnected"); });
});

// ==================== START ====================
(async () => {
  console.log("🚀 Starting Option Chain App...\n");
  if (!(await login())) { console.error("❌ Login failed"); process.exit(1); }
  await loadInstruments();
  const PORT = process.env.PORT || 3000;
  server.listen(PORT, () => {
    console.log(`\n✅ http://localhost:${PORT}`);
    console.log("📊 Open browser → select index → see live option chain\n");
  });
})();
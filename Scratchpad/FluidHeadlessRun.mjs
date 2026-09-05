//==============================================================================================================================================
// Scratchpad/FluidHeadlessRun.mjs — headless WebGPU runner for Projects/Project-Fluid (SwiftShader Vulkan, no GPU, Linux sandbox)
//    Counts, proofs and trace hashes are exact on SwiftShader; milliseconds are meaningless (≈ 100–1000× a real GPU).
//    One-time setup (only github.com / npm reachable):
//        mkdir -p /tmp/pw && cd /tmp/pw && npm init -y && npm i @sparticuz/chromium puppeteer-core
//        node -e "import('./node_modules/@sparticuz/chromium/build/index.js').then(m=>m.default.executablePath()).then(console.log)"   # → /tmp/chromium
//        node -e "import('./node_modules/@sparticuz/chromium/build/lambdafs.js').then(m=>m.inflate(process.cwd()+'/node_modules/@sparticuz/chromium/bin/al2023.tar.br')).then(console.log)"   # → /tmp/al2023/lib (nss3)
//        cd /home/user/Slate && python3 -m http.server 8765 --bind 0.0.0.0 &
//    Run (from /tmp/pw so puppeteer-core resolves):
//        node /home/user/Slate/Scratchpad/FluidHeadlessRun.mjs "http://127.0.0.1:8765/Projects/Project-Fluid/Source/index.html?resolution=32&seconds=0.6&proof=1&fixed=1&offscreen=1" 150000 /tmp/pw/shot.png
//    Budget: 32 cells ≈ 35 s per simulated second; 64 cells ≈ 7 min per 0.2 s. Use setsid nohup for anything over ~150 s.
//==============================================================================================================================================
import { createRequire } from "node:module";
const require   = createRequire("/tmp/pw/");
const puppeteer = require("puppeteer-core");

const [url, waitMs, png] = [process.argv[2], Number(process.argv[3] ?? 20000), process.argv[4] ?? "/tmp/pw/shot.png"];
const browser = await puppeteer.launch({
    executablePath: "/tmp/chromium", headless: true,
    args: ["--no-sandbox", "--disable-gpu-sandbox", "--headless=new", "--use-angle=vulkan", "--use-vulkan=swiftshader",
           "--enable-features=Vulkan,WebGPU,WebGPUDeveloperFeatures", "--enable-unsafe-webgpu", "--ignore-gpu-blocklist",
           "--disable-vulkan-surface", "--disable-dev-shm-usage", "--single-process", "--no-zygote", "--window-size=960,600"],
    env: { ...process.env, LD_LIBRARY_PATH: "/tmp/al2023/lib:/tmp", VK_ICD_FILENAMES: "/tmp/vk_swiftshader_icd.json" },
    protocolTimeout: 0,
});
const page = await browser.newPage();
await page.setViewport({ width: 960, height: 600 });
page.on("console",   m => console.log("[page]", m.text()));
page.on("pageerror", e => console.log("[pageerror]", e.message));
await page.goto(url, { waitUntil: "load", timeout: 0 });

const start = Date.now();
let exit = null;
while (Date.now() - start < waitMs)
{
    exit = await page.evaluate(() => window.ProjectFluidExit ?? null).catch(() => null);   // 0 pass · 2 fail · 1 error
    if (exit !== null) { break; }
    await new Promise(r => setTimeout(r, 1000));
}
await page.screenshot({ path: png });
const status = await page.evaluate(() => document.getElementById("status")?.textContent ?? "").catch(() => "");
console.log("STATUS:", status);
console.log("EXIT:", exit);
await browser.close();
process.exit(0);

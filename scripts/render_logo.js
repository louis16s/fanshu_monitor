const { execFileSync } = require("node:child_process");
const { existsSync, unlinkSync } = require("node:fs");
const { tmpdir } = require("node:os");
const { join, resolve } = require("node:path");
const { chromium } = require("playwright");

const root = resolve(__dirname, "..");
const master = join(tmpdir(), "fanshu-monitor-logo-master.png");
const assets = [
  ["FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_16x16.png", 16],
  ["FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_16x16@2x.png", 32],
  ["FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_32x32.png", 32],
  ["FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_32x32@2x.png", 64],
  ["FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_128x128.png", 128],
  ["FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png", 256],
  ["FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_256x256.png", 256],
  ["FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_256x256@2x.png", 512],
  ["FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_512x512.png", 512],
  ["FanshuMonitor/Assets.xcassets/AppIcon.appiconset/icon_512x512@2x.png", 1024],
  ["docs/images/icon-128.png", 128],
  ["docs/images/icon.png", 1024],
  ["docs/images/logo.png", 1024],
  ["docs/apple-touch-icon.png", 180],
  ["docs/apple-touch-icon-precomposed.png", 180]
];

async function render() {
  const browser = await chromium.launch({ headless: true });
  const page = await browser.newPage({ viewport: { width: 1024, height: 1024 } });
  await page.goto(`file://${resolve(__dirname, "logo.html")}`);
  await page.screenshot({ path: master, omitBackground: true });
  await browser.close();

  for (const [relativePath, size] of assets) {
    execFileSync("sips", ["-z", String(size), String(size), master, "--out", resolve(root, relativePath)], { stdio: "ignore" });
  }

  if (existsSync(master)) unlinkSync(master);
  console.log(`Rendered ${assets.length} logo assets from scripts/logo.html`);
}

render().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

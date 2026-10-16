const { existsSync, readFileSync, writeFileSync } = require("node:fs");
const { spawnSync } = require("node:child_process");
const { join, resolve } = require("node:path");

const root = resolve(__dirname, "..");
const version = readFileSync(join(root, "VERSION"), "utf8").trim();
if (!/^\d+\.\d+\.\d+$/.test(version)) {
  throw new Error(`VERSION must use x.y.z format, got: ${version}`);
}

const projectPath = join(root, "番薯monitor.xcodeproj/project.pbxproj");
const project = readFileSync(projectPath, "utf8");
const updatedProject = project.replace(/(MARKETING_VERSION = )\d+\.\d+\.\d+(;)/g, `$1${version}$2`);
if (updatedProject !== project) writeFileSync(projectPath, updatedProject);

const websiteFiles = [
  "README.md",
  "docs/README.en.md",
  "docs/zh/index.html",
  "docs/en/index.html"
];
let websiteChanged = false;

for (const relativePath of websiteFiles) {
  const path = join(root, relativePath);
  const source = readFileSync(path, "utf8");
  const updated = source.replace(/\d+\.\d+\.\d+/g, version);
  if (updated !== source) {
    writeFileSync(path, updated);
    if (relativePath.startsWith("docs/zh/") || relativePath.startsWith("docs/en/")) websiteChanged = true;
  }
}

const previewVersionPath = join(root, "docs/images/site-preview.version");
if (websiteChanged || !existsSync(previewVersionPath) || readFileSync(previewVersionPath, "utf8").trim() !== version) {
  const result = spawnSync("swift", [join(root, "scripts/render_site_preview.swift")], {
    cwd: root,
    stdio: "inherit"
  });
  if (result.status !== 0) {
    throw new Error("Could not render docs/images/site-preview.png");
  }
  writeFileSync(previewVersionPath, `${version}\n`);
}

console.log(`Synchronized app and website version ${version}`);

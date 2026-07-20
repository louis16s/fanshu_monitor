const root = document.documentElement;
const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
const storedTheme = localStorage.getItem("fanshu-theme");

if (storedTheme === "light" || storedTheme === "dark") {
  root.dataset.theme = storedTheme;
}

document.querySelectorAll("[data-theme-toggle]").forEach((button) => {
  button.addEventListener("click", () => {
    const current = root.dataset.theme || (window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light");
    const next = current === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    localStorage.setItem("fanshu-theme", next);
  });
});

document.querySelectorAll("[data-lang]").forEach((link) => {
  link.addEventListener("click", () => localStorage.setItem("fanshu-lang", link.dataset.lang));
});

const nav = document.querySelector("[data-nav]");
const menuButton = document.querySelector("[data-menu]");
menuButton?.addEventListener("click", () => {
  const isOpen = nav?.classList.toggle("is-open") ?? false;
  menuButton.setAttribute("aria-expanded", String(isOpen));
});

nav?.querySelectorAll("a").forEach((link) => {
  link.addEventListener("click", () => {
    nav.classList.remove("is-open");
    menuButton?.setAttribute("aria-expanded", "false");
  });
});

const revealElements = document.querySelectorAll(".reveal");
if (reducedMotion.matches || !("IntersectionObserver" in window)) {
  revealElements.forEach((element) => element.classList.add("is-visible"));
} else {
  const revealObserver = new IntersectionObserver((entries, observer) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("is-visible");
      observer.unobserve(entry.target);
    });
  }, { threshold: 0.12, rootMargin: "0px 0px -35px" });
  revealElements.forEach((element) => revealObserver.observe(element));
}

function syncRange(range) {
  const minimum = Number(range.min || 0);
  const maximum = Number(range.max || 100);
  const progress = ((Number(range.value) - minimum) / (maximum - minimum)) * 100;
  range.style.setProperty("--range-progress", `${progress}%`);
  const output = range.closest("label")?.querySelector("output");
  if (output && !range.hasAttribute("data-dpi-range")) output.textContent = `${range.value}%`;
}

document.querySelectorAll('input[type="range"]').forEach((range) => {
  syncRange(range);
  range.addEventListener("input", () => syncRange(range));
});

const demoTabs = document.querySelectorAll("[data-demo-tab]");
function activateDemo(name) {
  demoTabs.forEach((tab) => tab.setAttribute("aria-selected", String(tab.dataset.demoTab === name)));
  document.querySelectorAll("[data-demo-copy]").forEach((copy) => copy.classList.toggle("is-active", copy.dataset.demoCopy === name));
  document.querySelectorAll("[data-demo-canvas]").forEach((canvas) => { canvas.hidden = canvas.dataset.demoCanvas !== name; });
}
demoTabs.forEach((tab) => tab.addEventListener("click", () => activateDemo(tab.dataset.demoTab)));

const brightnessRange = document.querySelector("[data-demo-brightness]");
const brightnessOutput = document.querySelector("[data-demo-brightness-output]");
const screenName = document.querySelector("[data-screen-name]");
const screenLayout = document.querySelector(".screen-layout");
const screenValues = { "built-in": 46, external: 20 };
const screenLabels = {
  "built-in": document.documentElement.lang === "en" ? "Retina Display" : "视网膜显示器",
  external: "PG271Q"
};
let selectedScreen = "external";

function updateBrightness(value) {
  const next = Math.max(0, Math.min(100, Number(value)));
  screenValues[selectedScreen] = next;
  if (brightnessRange) {
    brightnessRange.value = String(next);
    syncRange(brightnessRange);
  }
  if (brightnessOutput) brightnessOutput.textContent = `${next}%`;
  const screen = document.querySelector(`[data-screen="${selectedScreen}"]`);
  const label = screen?.querySelector("small");
  if (label) label.textContent = selectedScreen === "external" ? `DDC ${next}%` : "macOS";
}

document.querySelectorAll("[data-screen]").forEach((screen) => {
  screen.addEventListener("click", () => {
    selectedScreen = screen.dataset.screen;
    document.querySelectorAll("[data-screen]").forEach((item) => item.classList.toggle("selected", item === screen));
    screenLayout?.classList.toggle("built-in-target", selectedScreen === "built-in");
    if (screenName) screenName.textContent = screenLabels[selectedScreen];
    updateBrightness(screenValues[selectedScreen]);
  });
});

brightnessRange?.addEventListener("input", () => updateBrightness(brightnessRange.value));
document.querySelectorAll("[data-brightness-step]").forEach((button) => {
  button.addEventListener("click", () => updateBrightness(screenValues[selectedScreen] + Number(button.dataset.brightnessStep)));
});

const dpiRange = document.querySelector("[data-dpi-range]");
const dpiOutput = document.querySelector("[data-dpi-output]");
function updateDPI(value) {
  const next = Math.max(400, Math.min(8000, Number(value)));
  if (dpiRange) {
    dpiRange.value = String(next);
    syncRange(dpiRange);
  }
  if (dpiOutput) dpiOutput.textContent = String(next);
  document.querySelectorAll("[data-dpi]").forEach((button) => button.classList.toggle("selected", Number(button.dataset.dpi) === next));
}
dpiRange?.addEventListener("input", () => updateDPI(dpiRange.value));
document.querySelectorAll("[data-dpi]").forEach((button) => button.addEventListener("click", () => updateDPI(button.dataset.dpi)));

document.querySelectorAll(".faq-list details").forEach((detail) => {
  detail.addEventListener("toggle", () => {
    if (!detail.open) return;
    document.querySelectorAll(".faq-list details").forEach((other) => {
      if (other !== detail) other.open = false;
    });
  });
});

const clockNodes = document.querySelectorAll(".panel-topbar time, [data-demo-clock]");
function updateClock() {
  const now = new Date();
  const value = new Intl.DateTimeFormat(document.documentElement.lang, { hour: "2-digit", minute: "2-digit", hour12: false }).format(now);
  clockNodes.forEach((node) => { node.textContent = value; });
}
updateClock();
window.setInterval(updateClock, 60_000);

const livePanel = document.querySelector("[data-live-panel]");
let panelIsVisible = true;
if (livePanel && "IntersectionObserver" in window) {
  const panelObserver = new IntersectionObserver(([entry]) => { panelIsVisible = entry.isIntersecting; }, { threshold: 0.05 });
  panelObserver.observe(livePanel);
}

let liveTick = 0;
window.setInterval(() => {
  if (!panelIsVisible || document.hidden || reducedMotion.matches) return;
  liveTick += 1;
  const cpu = 12 + ((liveTick * 7) % 9);
  const memory = 57 + ((liveTick * 3) % 4);
  const cpuNode = document.querySelector('[data-live-value="cpu"]');
  const memoryNode = document.querySelector('[data-live-value="memory"]');
  const memoryBar = document.querySelector('[data-live-bar="memory"]');
  if (cpuNode) cpuNode.textContent = String(cpu);
  if (memoryNode) memoryNode.textContent = String(memory);
  if (memoryBar) memoryBar.style.width = `${memory}%`;
}, 2800);

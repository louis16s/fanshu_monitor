const root = document.documentElement;
const storedTheme = localStorage.getItem("fanshu-theme");
if (storedTheme === "light" || storedTheme === "dark") {
  root.dataset.theme = storedTheme;
}

document.querySelectorAll("[data-theme-toggle]").forEach((button) => {
  button.addEventListener("click", () => {
    const next = root.dataset.theme === "dark" ? "light" : "dark";
    root.dataset.theme = next;
    localStorage.setItem("fanshu-theme", next);
  });
});

document.querySelectorAll("[data-lang]").forEach((link) => {
  link.addEventListener("click", () => {
    localStorage.setItem("fanshu-lang", link.dataset.lang);
  });
});

const nav = document.querySelector("[data-nav]");
document.querySelector("[data-menu]")?.addEventListener("click", () => {
  nav?.classList.toggle("is-open");
});

const observer = new IntersectionObserver(
  (entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("is-visible");
        observer.unobserve(entry.target);
      }
    });
  },
  { threshold: 0.14 }
);

document.querySelectorAll(".reveal").forEach((element) => observer.observe(element));

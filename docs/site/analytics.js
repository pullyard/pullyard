(function () {
  var WEBSITE_ID = "a010e150-7bbe-4701-997e-f537873e8784";
  var SITE_HOST = "pullyard.github.io";
  var local = /^(localhost|127\.0\.0\.1|\[::1\])$/.test(location.hostname);

  if (WEBSITE_ID && !local) {
    var s = document.createElement("script");
    s.defer = true;
    s.src = "https://cloud.umami.is/script.js";
    s.setAttribute("data-website-id", WEBSITE_ID);
    s.setAttribute("data-domains", SITE_HOST);
    s.setAttribute("data-exclude-hash", "true");
    document.head.appendChild(s);
  }

  function track(name, data) {
    if (local) {
      console.info("[analytics]", name, data || {});
      return;
    }
    if (window.umami && typeof window.umami.track === "function") window.umami.track(name, data);
  }

  function platformOf(file) {
    var f = file.toLowerCase();
    if (/\.dmg$/.test(f)) return "macos";
    if (/windows|\.exe$|\.msi$/.test(f)) return "windows";
    if (/linux|\.deb$|\.rpm$|\.flatpak$|\.appimage$|\.tar\.gz$/.test(f)) return "linux";
    return "other";
  }

  function placementOf(el) {
    if (el.closest("header")) return "nav";
    if (el.closest("footer")) return "footer";
    var section = el.closest("section");
    if (!section) return "page";
    return section.id || section.classList[0] || "section";
  }

  function commandOf(text) {
    if (/^brew /.test(text)) return "homebrew";
    if (/^xattr /.test(text)) return "macos-quarantine";
    if (/Expand-Archive/.test(text)) return "windows-portable";
    if (/apt install/.test(text)) return "deb";
    if (/^flatpak /.test(text)) return "flatpak";
    if (/^tar /.test(text)) return "tarball";
    return "other";
  }

  document.addEventListener("click", function (e) {
    var a = e.target.closest && e.target.closest("a[href]");
    if (a) {
      var href = a.href;
      var m = href.match(/github\.com\/pullyard\/pullyard\/releases\/(?:latest\/)?download\/(?:[^/]+\/)?([^/?#]+)/i);
      if (m) {
        track("download-" + platformOf(m[1]), { file: m[1], placement: placementOf(a), page: location.pathname });
        return;
      }
      if (/github\.com\/pullyard\/pullyard\/releases/i.test(href)) {
        track("releases-page", { placement: placementOf(a), page: location.pathname });
        return;
      }
      if (/github\.com\/pullyard\/pullyard/i.test(href)) {
        track("github", { placement: placementOf(a), page: location.pathname });
        return;
      }
    }
    var copy = e.target.closest && e.target.closest(".code button");
    if (copy) {
      var code = copy.parentNode.querySelector("code");
      var text = code ? code.textContent : "";
      track("copy-command", { command: commandOf(text.trim()), page: location.pathname });
    }
  }, true);
})();

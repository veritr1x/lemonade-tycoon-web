// Installation is optional. Existing games continue while a new build downloads;
// updates take effect after all tabs using the old build have closed.
export function setupOffline() {
  const status = document.querySelector("#offline-status"),
    install = document.querySelector("#install-app");
  let prompt;
  window.addEventListener("beforeinstallprompt", (event) => {
    event.preventDefault();
    prompt = event;
    install.hidden = false;
  });
  install.addEventListener("click", async () => {
    if (!prompt) return;
    await prompt.prompt();
    prompt = null;
    install.hidden = true;
  });
  window.addEventListener("appinstalled", () => {
    install.hidden = true;
  });
  if (!("serviceWorker" in navigator)) {
    status.textContent = "This browser does not support offline installation.";
    return;
  }
  navigator.serviceWorker
    .register("./sw.js", { scope: "./", updateViaCache: "none" })
    .then((registration) => {
      const update = () => {
        if (registration.waiting)
          status.textContent =
            "Update ready. Close all game tabs, then reopen to apply it.";
        else if (registration.active)
          status.textContent = "Ready to play offline.";
        else status.textContent = "Downloading the game for offline play…";
      };
      update();
      registration.addEventListener("updatefound", () => {
        const worker = registration.installing;
        worker?.addEventListener("statechange", () => {
          if (worker.state === "redundant" && !registration.active)
            status.textContent =
              "Offline download did not finish. Reopen online to try again.";
          else update();
        });
      });
      navigator.serviceWorker.addEventListener("controllerchange", update);
      navigator.serviceWorker.ready.then(update);
    })
    .catch(() => {
      status.textContent =
        "Offline setup is unavailable. You can still play while online.";
    });
}

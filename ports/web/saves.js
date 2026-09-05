const errors = [
  "Save ready.",
  "There is no checkpoint here yet.",
  "This save is incomplete, damaged, or an unsupported version.",
  "Close the game before importing a save.",
  "The save could not be written. Your previous checkpoint is unchanged.",
];
export class SaveControls {
  constructor({ game, running, sync, close }) {
    this.game = game;
    this.running = running;
    this.sync = sync;
    this.feedback = document.querySelector("#transfer-status");
    document.querySelectorAll("[data-export]").forEach((button) => {
      button.addEventListener("click", async () => {
        try {
          // Export the completed in-memory checkpoint even when IndexedDB is
          // blocked; downloading a copy is the player's recovery path.
          const stored = await sync();
          const result = game()._lemon_web_export(
            Number(button.dataset.export),
          );
          if (result) throw new Error(errors[result]);
          const bytes = game().FS.readFile("/transfer.lemonade-save");
          const url = URL.createObjectURL(
            new Blob([bytes], { type: "application/octet-stream" }),
          );
          const link = document.createElement("a");
          link.href = url;
          link.download = `Lemonade-${["latest", "previous", "before-import"][Number(button.dataset.export)]}.lemonade-save`;
          link.click();
          setTimeout(() => URL.revokeObjectURL(url), 1000);
          game().FS.unlink("/transfer.lemonade-save");
          this.feedback.textContent = stored
            ? "Save exported."
            : "Save exported. Browser storage is still unavailable; keep this copy.";
        } catch (error) {
          this.feedback.textContent = error.message;
        }
      });
    });
    const file = document.querySelector("#import-file");
    document
      .querySelector("#import-save")
      .addEventListener("click", () => file.click());
    file.addEventListener("change", async () => {
      try {
        const chosen = file.files[0];
        if (!chosen) return;
        if (this.running()) throw new Error(errors[3]);
        if (chosen.size > 8 * 1024 * 1024 + 16) throw new Error(errors[2]);
        game().FS.writeFile(
          "/import.lemonade-save",
          new Uint8Array(await chosen.arrayBuffer()),
        );
        let result = game()._lemon_web_import(1);
        if (result) throw new Error(errors[result]);
        if (
          !confirm(
            "Replace all careers with this save? Your current checkpoint will remain available as the pre-import backup.",
          )
        )
          return;
        result = game()._lemon_web_import(0);
        if (result) throw new Error(errors[result]);
        const stored = await sync();
        this.feedback.textContent = stored
          ? "Imported. Close settings, then choose Play again."
          : "Imported for this tab, but browser storage failed. Export a copy before leaving.";
        game()._lemon_web_read_state();
      } catch (error) {
        this.feedback.textContent = error.message;
      } finally {
        file.value = "";
        try {
          game().FS.unlink("/import.lemonade-save");
        } catch {}
      }
    });
    document.querySelector("#close-game").addEventListener("click", () => {
      if (
        confirm(
          "Close the game? The latest normal checkpoint stays saved. Progress since that checkpoint will be lost.",
        )
      )
        close();
    });
  }
  update(state) {
    this.state = state;
    document.querySelectorAll("[data-export]").forEach((button) => {
      button.disabled = !(
        state.available &
        (1 << Number(button.dataset.export))
      );
    });
    document.querySelector("#import-save").disabled = this.running();
    document.querySelector("#close-game").hidden = !this.running();
  }
}

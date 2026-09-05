// Storage can be blocked in private or embedded contexts. Preferences should
// never prevent a game from starting; the current tab remains usable either way.
export function readPreference(key, fallback) {
  try {
    const value = localStorage.getItem(key);
    return value === null ? fallback : JSON.parse(value);
  } catch {
    return fallback;
  }
}
export function writePreference(key, value) {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {}
}
export function setupVolumes(game) {
  const levels = ["musicVolume", "effectsVolume"];
  const values = levels.map((key) => {
    const value = readPreference(key, 100);
    return typeof value === "number" && Number.isFinite(value)
      ? Math.max(0, Math.min(100, value))
      : 100;
  });
  const apply = () =>
    game()._lemon_audio_levels(values[0] / 100, values[1] / 100);
  levels.forEach((key, i) => {
    const slider = document.querySelector(`#${key}`),
      output = document.querySelector(`#${key}-value`);
    slider.value = values[i];
    output.textContent = `${values[i]}%`;
    slider.addEventListener("input", () => {
      values[i] = Number(slider.value);
      output.textContent = `${values[i]}%`;
      writePreference(key, values[i]);
      if (game()) apply();
    });
  });
  return apply;
}

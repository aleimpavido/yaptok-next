"use client";

import { useState } from "react";
import { callRpc } from "@/lib/social/client";

type Cosmetic = {
  id: string;
  name: string;
  category: string;
  rarity: string;
  unlock_level: number;
  required_xp: number;
  style: Record<string, unknown>;
};
type Owned = { cosmetic_id: string; equipped: boolean };

function CosmeticPreview({ item }: { item: Cosmetic }) {
  const effect = typeof item.style?.effect === "string" ? item.style.effect : "spark";
  const palette: Record<string, string> = {
    spark: "from-cyan-400/30 via-blue-500/10 to-transparent",
    neon: "from-fuchsia-500/40 via-violet-500/20 to-cyan-400/20",
    glitch: "from-red-500/30 via-cyan-400/20 to-violet-500/30",
    galaxy: "from-indigo-500/40 via-fuchsia-500/25 to-sky-400/20",
    sunset: "from-orange-500/40 via-rose-500/30 to-amber-300/20",
    aurora: "from-emerald-400/35 via-cyan-400/30 to-violet-500/30",
    particles: "from-sky-400/25 via-violet-500/20 to-transparent",
    chrome: "from-slate-200/50 via-slate-500/20 to-slate-300/30",
    lightning: "from-yellow-300/35 via-blue-500/20 to-indigo-500/30",
  };
  const symbol: Record<string, string> = {
    spark: "✦", neon: "◉", glitch: "▧", galaxy: "✧", sunset: "☼",
    aurora: "✺", particles: "⁕", chrome: "◆", lightning: "ϟ",
  };
  const motion = ["neon", "glitch", "galaxy", "aurora", "particles", "lightning"].includes(effect);
  return (
    <div className={`mt-4 flex h-20 items-center justify-center gap-3 overflow-hidden rounded-xl border border-white/10 bg-gradient-to-br ${palette[effect] ?? palette.spark}`}>
      <span className={`text-[34px] text-white drop-shadow-lg ${motion ? "motion-safe:animate-pulse motion-reduce:animate-none" : ""}`}>{symbol[effect] ?? "✦"}</span>
      <span className="text-[13px] font-semibold tracking-wide text-white drop-shadow">{item.name}</span>
    </div>
  );
}

export function CollectionGrid({ items, owned, xp, level }: { items: Cosmetic[]; owned: Owned[]; xp: number; level: number }) {
  const [unlocked, setUnlocked] = useState(() => new Set(owned.map((item) => item.cosmetic_id)));
  const [equipped, setEquipped] = useState(() => new Set(owned.filter((item) => item.equipped).map((item) => item.cosmetic_id)));
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState("");

  async function claim(id: string) {
    setBusy(id); setMessage("");
    const result = await callRpc("claim_cosmetic", { p_cosmetic: id });
    if (result.ok) {
      setUnlocked((old) => new Set(old).add(id));
      setMessage("Cosmetic unlocked.");
    } else setMessage(result.code === "cosmetic_locked" ? "Keep earning XP to unlock this item." : "Could not unlock this item.");
    setBusy(null);
  }

  async function equip(id: string) {
    setBusy(id); setMessage("");
    const result = await callRpc("equip_cosmetic", { p_cosmetic: id });
    if (result.ok) {
      const category = items.find((item) => item.id === id)?.category;
      setEquipped((old) => {
        const next = new Set(old);
        for (const item of items) if (item.category === category) next.delete(item.id);
        next.add(id);
        return next;
      });
      setMessage("Cosmetic equipped.");
    } else setMessage("Could not equip this item.");
    setBusy(null);
  }

  return (
    <div>
      <div className="mb-4 flex items-center justify-between gap-3 rounded-2xl border border-divider bg-panel p-4">
        <div><p className="text-[12px] text-text-2">Your collection</p><p className="text-[22px] font-semibold text-text">Level {level} · {xp.toLocaleString()} XP</p></div>
        <span className="text-[12px] text-text-3">{unlocked.size} / {items.length} unlocked</span>
      </div>
      {message && <p role="status" className="mb-3 text-[13px] text-text-2">{message}</p>}
      <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
        {items.map((item) => {
          const has = unlocked.has(item.id);
          const canUnlock = xp >= item.required_xp && level >= item.unlock_level;
          const isEquipped = equipped.has(item.id);
          return (
            <article key={item.id} className="rounded-2xl border border-divider bg-panel p-4">
              <div className="flex items-start justify-between gap-3">
                <div>
                  <p className="font-semibold text-text">{item.name}</p>
                  <p className="mt-1 text-[12px] capitalize text-text-3">{item.category.replaceAll("_", " ")} · {item.rarity}</p>
                </div>
                <span className="rounded-full bg-hover px-2.5 py-1 text-[11px] text-text-2">{has ? "Unlocked" : "Locked"}</span>
              </div>
              <CosmeticPreview item={item} />
              <p className="mt-3 text-[13px] text-text-2">Level {item.unlock_level} · {item.required_xp.toLocaleString()} XP</p>
              <div className="mt-4">
                {has ? (
                  <button type="button" disabled={busy === item.id || isEquipped} onClick={() => void equip(item.id)} className="btn-secondary w-full disabled:opacity-60">{isEquipped ? "Equipped" : busy === item.id ? "Saving…" : "Equip"}</button>
                ) : (
                  <button type="button" disabled={!canUnlock || busy === item.id} onClick={() => void claim(item.id)} className="btn-secondary w-full disabled:opacity-50">{busy === item.id ? "Unlocking…" : canUnlock ? "Unlock for free" : "Earn more XP"}</button>
                )}
              </div>
            </article>
          );
        })}
      </div>
    </div>
  );
}

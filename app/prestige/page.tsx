import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import { Suspense } from "react";
import Link from "next/link";
import { DbNotConnected } from "@/components/auth/AuthCard";
import { getCurrentUser } from "@/lib/auth";
import { flagOn } from "@/lib/flags";
import { readSupabaseConfig } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const metadata = { title: "YapTok Prestige | YapTok" };

type Prestige = { xp: number; level: number; next_level_xp: number; best_streak: number };

function readPrestige(value: unknown): Prestige | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  return {
    xp: Math.max(0, Number(row.xp) || 0),
    level: Math.max(1, Number(row.level) || 1),
    next_level_xp: Math.max(100, Number(row.next_level_xp) || 100),
    best_streak: Math.max(0, Number(row.best_streak) || 0),
  };
}

async function PrestigeContent() {
  await connection();
  if (!readSupabaseConfig()) return <DbNotConnected />;
  const user = await getCurrentUser();
  if (!(await flagOn("prestige", user?.id ?? null))) notFound();
  if (!user) redirect("/login?next=/prestige");
  const supabase = await createClient();
  const { data, error } = supabase ? await supabase.rpc("my_yap_progress") : { data: null, error: true };
  const progress = readPrestige(data);
  const currentLevelXp = progress ? (progress.level - 1) * (progress.level - 1) * 100 : 0;
  const progressPct = progress ? Math.min(100, Math.round(((progress.xp - currentLevelXp) / Math.max(1, progress.next_level_xp - currentLevelXp)) * 100)) : 0;

  return (
    <main className="mx-auto max-w-[720px] px-4 py-8 sm:px-6">
      <div className="flex items-center justify-between gap-3">
        <div>
          <p className="text-[12px] font-semibold uppercase tracking-[0.18em] text-[var(--accent)]">Earned, never bought</p>
          <h1 className="mt-1 text-[28px] font-semibold text-text">YapTok Prestige</h1>
        </div>
        <Link href="/collection" className="btn-secondary">Collection</Link>
      </div>
      {error || !progress ? (
        <p role="alert" className="mt-6 rounded-xl border border-divider p-4 text-[14px] text-text-2">Your Prestige data could not be loaded. Please try again later.</p>
      ) : (
        <>
          <section className="mt-6 rounded-2xl border border-divider bg-panel p-6">
            <div className="flex items-end justify-between gap-4">
              <div><p className="text-[13px] text-text-2">Your level</p><p className="mt-1 text-[52px] font-bold text-text">{progress.level}</p></div>
              <div className="text-right"><p className="text-[13px] text-text-2">Total XP</p><p className="mt-1 text-[28px] font-semibold text-text">{progress.xp.toLocaleString()}</p></div>
            </div>
            <div className="mt-5 h-3 overflow-hidden rounded-full bg-hover"><div className="h-full rounded-full bg-[var(--accent)]" style={{ width: progressPct + "%" }} /></div>
            <p className="mt-2 text-[12px] text-text-3">{Math.max(0, progress.xp - currentLevelXp).toLocaleString()} / {Math.max(1, progress.next_level_xp - currentLevelXp).toLocaleString()} XP toward the next level</p>
          </section>
          <section className="mt-5 rounded-2xl border border-divider p-5">
            <h2 className="font-semibold text-text">How XP is earned</h2>
            <ul className="mt-3 space-y-2 text-[14px] leading-6 text-text-2">
              <li>20 XP for the first valid public post each local day.</li>
              <li>5 XP for a distinct repost, capped at 10 rewarded reposts per day.</li>
              <li>One-time streak milestone bonuses at 3, 7, 14, 30 and 100 days.</li>
            </ul>
            <p className="mt-3 text-[12px] text-text-3">XP is validated and recorded by the database. Client-side requests cannot award points.</p>
            <Link href="/streaks" className="mt-4 inline-block text-[14px] font-medium text-[var(--accent)] hover:underline">View your YapStreak →</Link>
          </section>
        </>
      )}
    </main>
  );
}

export default function PrestigePage() {
  return <Suspense fallback={<div className="mx-auto mt-8 h-48 max-w-[680px] rounded-2xl bg-skeleton" aria-hidden />}><PrestigeContent /></Suspense>;
}

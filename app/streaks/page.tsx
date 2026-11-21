import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import { Suspense } from "react";
import Link from "next/link";
import { TimezoneForm } from "@/components/streaks/TimezoneForm";
import { DbNotConnected } from "@/components/auth/AuthCard";
import { getCurrentUser } from "@/lib/auth";
import { flagOn } from "@/lib/flags";
import { readSupabaseConfig } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const metadata = { title: "YapStreak | YapTok" };

type Day = { date: string; posted: boolean };
type Progress = {
  timezone: string;
  today: string;
  current_streak: number;
  best_streak: number;
  calendar: Day[];
};

function readProgress(value: unknown): Progress | null {
  if (!value || typeof value !== "object" || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  if (typeof row.timezone !== "string" || !Array.isArray(row.calendar)) return null;
  return {
    timezone: row.timezone,
    today: typeof row.today === "string" ? row.today : "",
    current_streak: Math.max(0, Number(row.current_streak) || 0),
    best_streak: Math.max(0, Number(row.best_streak) || 0),
    calendar: row.calendar.flatMap((entry) => {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) return [];
      const day = entry as Record<string, unknown>;
      return typeof day.date === "string" ? [{ date: day.date, posted: day.posted === true }] : [];
    }),
  };
}

async function StreakContent() {
  await connection();
  if (!readSupabaseConfig()) return <DbNotConnected />;
  const user = await getCurrentUser();
  if (!(await flagOn("streaks", user?.id ?? null))) notFound();
  if (!user) redirect("/login?next=/streaks");

  const supabase = await createClient();
  const { data, error } = supabase ? await supabase.rpc("my_yap_progress") : { data: null, error: true };
  const progress = readProgress(data);

  return (
    <main className="mx-auto max-w-[720px] px-4 py-8 sm:px-6">
      <div className="flex items-center justify-between gap-3">
        <div>
          <p className="text-[12px] font-semibold uppercase tracking-[0.18em] text-[var(--accent)]">Daily creator habit</p>
          <h1 className="mt-1 text-[28px] font-semibold text-text">YapStreak</h1>
        </div>
        <Link href="/prestige" className="btn-secondary">Prestige</Link>
      </div>

      {error || !progress ? (
        <p role="alert" className="mt-6 rounded-xl border border-divider p-4 text-[14px] text-text-2">Your streak data could not be loaded. Please try again later.</p>
      ) : (
        <>
          <section className="mt-6 grid grid-cols-2 gap-3">
            <div className="rounded-2xl border border-divider bg-panel p-5">
              <p className="text-[13px] text-text-2">Current streak</p>
              <p className="mt-2 text-[40px] font-bold text-text">{progress.current_streak} <span className="text-[16px] font-medium text-text-2">days</span></p>
            </div>
            <div className="rounded-2xl border border-divider bg-panel p-5">
              <p className="text-[13px] text-text-2">Personal record</p>
              <p className="mt-2 text-[40px] font-bold text-text">{progress.best_streak} <span className="text-[16px] font-medium text-text-2">days</span></p>
            </div>
          </section>

          <section className="mt-6 rounded-2xl border border-divider bg-panel p-5">
            <div className="flex items-center justify-between gap-3">
              <h2 className="text-[16px] font-semibold text-text">Your last 90 days</h2>
              <span className="text-[12px] text-text-3">{progress.timezone}</span>
            </div>
            <div className="mt-4 grid grid-cols-10 gap-1.5 sm:grid-cols-15">
              {progress.calendar.map((day) => (
                <div key={day.date} title={day.date + (day.posted ? " · valid post" : " · no valid post")} className={`aspect-square rounded-[5px] border ${day.posted ? "border-[var(--accent)] bg-[var(--accent)]" : "border-divider bg-hover"}`}>
                  <span className="sr-only">{day.date}: {day.posted ? "posted" : "no post"}</span>
                </div>
              ))}
            </div>
            <div className="mt-4 flex items-center gap-2 text-[12px] text-text-3">
              <span className="h-3 w-3 rounded-[3px] bg-[var(--accent)]" /> Valid public post
              <span className="ml-3 h-3 w-3 rounded-[3px] border border-divider bg-hover" /> No valid post
            </div>
          </section>

          {progress.current_streak > 0 && !progress.calendar.find((day) => day.date === progress.today)?.posted && (
            <p className="mt-4 rounded-xl border border-divider bg-panel p-4 text-[13px] leading-5 text-text-2">Your streak is still active. One valid public post before midnight in {progress.timezone} will keep it going. If you miss a day, you can simply start again.</p>
          )}

          <section className="mt-5 rounded-2xl border border-divider p-5">
            <h2 className="font-semibold text-text">How it works</h2>
            <p className="mt-2 text-[14px] leading-6 text-text-2">Publish at least one public video that finishes processing each local day. More posts on the same day do not increase the streak. Private, failed, deleted or moderation-removed videos do not count.</p>
            <p className="mt-2 text-[13px] text-text-3">Your calendar follows your IANA timezone. Set it here so day boundaries match your local time.</p>
            <TimezoneForm initial={progress.timezone} />
          </section>
        </>
      )}
    </main>
  );
}

export default function StreakPage() {
  return <Suspense fallback={<div className="mx-auto mt-8 h-48 max-w-[680px] rounded-2xl bg-skeleton" aria-hidden />}><StreakContent /></Suspense>;
}

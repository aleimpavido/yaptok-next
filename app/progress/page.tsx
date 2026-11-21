import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import { Suspense } from "react";
import Link from "next/link";
import { DbNotConnected } from "@/components/auth/AuthCard";
import { getCurrentUser } from "@/lib/auth";
import { flagOn } from "@/lib/flags";
import { readSupabaseConfig } from "@/lib/supabase/env";

export const metadata = { title: "Rewards | YapTok" };

async function RewardsContent() {
  await connection();
  if (!readSupabaseConfig()) return <DbNotConnected />;
  const user = await getCurrentUser();
  if (!user) redirect("/login?next=/progress");
  const [streaks, prestige, collection, reposts] = await Promise.all([
    flagOn("streaks", user.id),
    flagOn("prestige", user.id),
    flagOn("collection", user.id),
    flagOn("reposts", user.id),
  ]);
  if (!streaks && !prestige && !collection && !reposts) notFound();
  const cards = [
    streaks && { href: "/streaks", title: "YapStreak", description: "Keep your personal daily posting streak alive." },
    prestige && { href: "/prestige", title: "YapTok Prestige", description: "Earn XP, levels and milestone rewards." },
    collection && { href: "/collection", title: "YapTok Collection", description: "Unlock and equip free profile and chat cosmetics." },
    reposts && { href: "/reposts", title: "Your Reposts", description: "Find every public clip you have reposted." },
    reposts && { href: "/following/reposts", title: "Following Reposts", description: "See what the creators you follow have reposted." },
  ].filter((item): item is { href: string; title: string; description: string } => item !== false);
  return (
    <main className="mx-auto max-w-[720px] px-4 py-8 sm:px-6">
      <p className="text-[12px] font-semibold uppercase tracking-[0.18em] text-[var(--accent)]">Progress and rewards</p>
      <h1 className="mt-1 text-[28px] font-semibold text-text">Your rewards</h1>
      <div className="mt-6 grid gap-3">
        {cards.map((card) => (
          <Link key={card.href} href={card.href} className="rounded-2xl border border-divider bg-panel p-5 transition-colors hover:bg-hover">
            <h2 className="font-semibold text-text">{card.title}</h2>
            <p className="mt-1 text-[14px] text-text-2">{card.description}</p>
            <p className="mt-3 text-[13px] font-medium text-[var(--accent)]">Open →</p>
          </Link>
        ))}
      </div>
    </main>
  );
}

export default function RewardsPage() {
  return <Suspense fallback={<div className="mx-auto mt-8 h-48 max-w-[680px] rounded-2xl bg-skeleton" aria-hidden />}><RewardsContent /></Suspense>;
}

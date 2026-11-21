import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import { Suspense } from "react";
import Link from "next/link";
import { DbNotConnected } from "@/components/auth/AuthCard";
import { CollectionGrid } from "@/components/collection/CollectionGrid";
import { getCurrentUser } from "@/lib/auth";
import { flagOn } from "@/lib/flags";
import { readSupabaseConfig } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const metadata = { title: "YapTok Collection | YapTok" };

async function CollectionContent() {
  await connection();
  if (!readSupabaseConfig()) return <DbNotConnected />;
  const user = await getCurrentUser();
  if (!(await flagOn("collection", user?.id ?? null))) notFound();
  if (!user) redirect("/login?next=/collection");
  const supabase = await createClient();
  if (!supabase) return <DbNotConnected />;

  const [{ data: progressData }, { data: itemsData }, { data: ownedData }] = await Promise.all([
    supabase.rpc("my_yap_progress"),
    supabase.from("prestige_cosmetics").select("id,name,category,rarity,unlock_level,required_xp,style").eq("active", true).order("required_xp"),
    supabase.from("user_cosmetics").select("cosmetic_id,equipped"),
  ]);
  const progress = progressData && typeof progressData === "object" ? progressData as Record<string, unknown> : {};
  const xp = Math.max(0, Number(progress.xp) || 0);
  const level = Math.max(1, Number(progress.level) || 1);
  const items = Array.isArray(itemsData) ? itemsData : [];
  const owned = Array.isArray(ownedData) ? ownedData : [];

  return (
    <main className="mx-auto max-w-[900px] px-4 py-8 sm:px-6">
      <div className="mb-6 flex items-center justify-between gap-3">
        <div><p className="text-[12px] font-semibold uppercase tracking-[0.18em] text-[var(--accent)]">All rewards are free</p><h1 className="mt-1 text-[28px] font-semibold text-text">YapTok Collection</h1></div>
        <Link href="/prestige" className="btn-secondary">Prestige</Link>
      </div>
      <CollectionGrid items={items} owned={owned} xp={xp} level={level} />
      <p className="mt-5 text-[12px] text-text-3">Frames, banners and effects are earned through activity. No paid cosmetics, premium currency or paywall.</p>
    </main>
  );
}

export default function CollectionPage() {
  return <Suspense fallback={<div className="mx-auto mt-8 h-48 max-w-[860px] rounded-2xl bg-skeleton" aria-hidden />}><CollectionContent /></Suspense>;
}

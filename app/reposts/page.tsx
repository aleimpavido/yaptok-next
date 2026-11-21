import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import { Suspense } from "react";
import Link from "next/link";
import { DbNotConnected } from "@/components/auth/AuthCard";
import { getCurrentUser } from "@/lib/auth";
import { flagOn } from "@/lib/flags";
import { readSupabaseConfig } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const metadata = { title: "Your Reposts | YapTok" };

type Repost = { id: string; caption: string; thumbnail_url: string | null; reposted_at: string; reposted_by?: string; author?: { username?: string } };

function readReposts(value: unknown): Repost[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry): Repost[] => {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return [];
    const row = entry as Record<string, unknown>;
    const rawAuthor = row.author && typeof row.author === "object" && !Array.isArray(row.author) ? row.author as Record<string, unknown> : {};
    if (typeof row.id !== "string") return [];
    return [{
      id: row.id,
      caption: typeof row.caption === "string" ? row.caption : "",
      thumbnail_url: typeof row.thumbnail_url === "string" ? row.thumbnail_url : null,
      reposted_at: typeof row.reposted_at === "string" ? row.reposted_at : "",
      reposted_by: typeof row.reposted_by === "string" ? row.reposted_by : undefined,
      author: { username: typeof rawAuthor.username === "string" ? rawAuthor.username : undefined },
    }];
  });
}

async function RepostsContent() {
  await connection();
  if (!readSupabaseConfig()) return <DbNotConnected />;
  const user = await getCurrentUser();
  if (!(await flagOn("reposts", user?.id ?? null))) notFound();
  if (!user) redirect("/login?next=/reposts");
  const supabase = await createClient();
  const { data, error } = supabase ? await supabase.rpc("my_reposts", { p_username: user.username }) : { data: null, error: true };
  const rows = readReposts(data);
  return (
    <main className="mx-auto max-w-[900px] px-4 py-8 sm:px-6">
      <div className="flex items-center justify-between gap-3"><div><p className="text-[12px] font-semibold uppercase tracking-[0.18em] text-[var(--accent)]">Shared, not copied</p><h1 className="mt-1 text-[28px] font-semibold text-text">Your Reposts</h1></div><Link href="/progress" className="btn-secondary">Rewards</Link></div>
      {error ? <p role="alert" className="mt-6 text-[14px] text-text-2">Reposts could not be loaded.</p> : rows.length === 0 ? <p className="mt-8 rounded-2xl border border-divider p-5 text-[14px] text-text-2">You have not reposted any clips yet. Repost a public clip from its action rail and it will appear here.</p> : (
        <div className="mt-6 grid grid-cols-2 gap-3 sm:grid-cols-3">
          {rows.map((row) => <Link key={row.id} href={`/v/${row.id}`} className="overflow-hidden rounded-2xl border border-divider bg-panel">
            {row.thumbnail_url ? <div role="img" aria-label="Video thumbnail" style={{ backgroundImage: `url("${row.thumbnail_url}")` }} className="aspect-[9/16] w-full bg-hover bg-cover bg-center" /> : <div className="aspect-[9/16] bg-hover" />}
            <div className="p-3"><p className="line-clamp-2 text-[13px] text-text">{row.caption || "Video"}</p><p className="mt-1 text-[11px] text-text-3">Original by @{row.author?.username ?? "creator"}</p></div>
          </Link>)}
        </div>
      )}
    </main>
  );
}

export default function RepostsPage() {
  return <Suspense fallback={<div className="mx-auto mt-8 h-48 max-w-[860px] rounded-2xl bg-skeleton" aria-hidden />}><RepostsContent /></Suspense>;
}

import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import { Suspense } from "react";
import Link from "next/link";
import { DbNotConnected } from "@/components/auth/AuthCard";
import { BlockedUsers, type BlockedUser } from "@/components/messages/BlockedUsers";
import { getCurrentUser } from "@/lib/auth";
import { flagOn } from "@/lib/flags";
import { readSupabaseConfig } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const metadata = { title: "Blocked Accounts | YapTok" };

function readBlocked(value: unknown): BlockedUser[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry): BlockedUser[] => {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return [];
    const row = entry as Record<string, unknown>;
    if (typeof row.id !== "string" || typeof row.username !== "string") return [];
    return [{
      id: row.id,
      username: row.username,
      displayName: typeof row.display_name === "string" ? row.display_name : row.username,
      avatarUrl: typeof row.avatar_url === "string" ? row.avatar_url : null,
    }];
  });
}

async function BlockedContent() {
  await connection();
  if (!readSupabaseConfig()) return <DbNotConnected />;
  const user = await getCurrentUser();
  if (!(await flagOn("messages", user?.id ?? null))) notFound();
  if (!user) redirect("/login?next=/messages/blocked");
  const supabase = await createClient();
  const { data, error } = supabase ? await supabase.rpc("my_message_blocks") : { data: null, error: true };
  return (
    <main className="mx-auto max-w-[640px] px-4 py-6 sm:px-6">
      <div className="flex items-center justify-between gap-3"><h1 className="text-[24px] font-medium text-text">Blocked accounts</h1><Link href="/messages/requests" className="btn-secondary">Requests</Link></div>
      {error ? <p role="alert" className="mt-5 text-[14px] text-text-2">Blocked accounts could not be loaded.</p> : <BlockedUsers initial={readBlocked(data)} />}
    </main>
  );
}

export default function BlockedPage() {
  return <Suspense fallback={<div className="mx-auto mt-8 h-48 max-w-[600px] rounded-2xl bg-skeleton" aria-hidden />}><BlockedContent /></Suspense>;
}

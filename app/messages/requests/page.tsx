import { notFound, redirect } from "next/navigation";
import { connection } from "next/server";
import { Suspense } from "react";
import Link from "next/link";
import { DbNotConnected } from "@/components/auth/AuthCard";
import { MessageRequests, type MessageRequestView } from "@/components/messages/MessageRequests";
import { getCurrentUser } from "@/lib/auth";
import { flagOn } from "@/lib/flags";
import { readSupabaseConfig } from "@/lib/supabase/env";
import { createClient } from "@/lib/supabase/server";

export const metadata = { title: "Message Requests | YapTok" };

function readRequests(value: unknown): MessageRequestView[] {
  if (!Array.isArray(value)) return [];
  return value.flatMap((entry): MessageRequestView[] => {
    if (!entry || typeof entry !== "object" || Array.isArray(entry)) return [];
    const row = entry as Record<string, unknown>;
    const from = row.from && typeof row.from === "object" && !Array.isArray(row.from) ? row.from as Record<string, unknown> : {};
    const last = row.last && typeof row.last === "object" && !Array.isArray(row.last) ? row.last as Record<string, unknown> : {};
    if (typeof from.id !== "string" || typeof from.username !== "string") return [];
    return [{
      senderId: from.id,
      username: from.username,
      displayName: typeof from.display_name === "string" ? from.display_name : from.username,
      avatarUrl: typeof from.avatar_url === "string" ? from.avatar_url : null,
      body: typeof last.body === "string" ? last.body : "",
      createdAt: typeof last.created_at === "string" ? last.created_at : "",
    }];
  });
}

async function RequestsContent() {
  await connection();
  if (!readSupabaseConfig()) return <DbNotConnected />;
  const user = await getCurrentUser();
  if (!(await flagOn("messages", user?.id ?? null))) notFound();
  if (!user) redirect("/login?next=/messages/requests");
  const supabase = await createClient();
  const { data, error } = supabase ? await supabase.rpc("dm_requests") : { data: null, error: true };
  const requests = readRequests(data);
  return (
    <main className="mx-auto max-w-[640px] px-4 py-6 sm:px-6">
      <div className="flex items-center justify-between gap-3">
        <div><p className="text-[12px] font-semibold uppercase tracking-[0.18em] text-[var(--accent)]">YapChat</p><h1 className="mt-1 text-[24px] font-medium text-text">Message requests</h1></div>
        <Link href="/messages" className="btn-secondary">Inbox</Link>
      </div>
      {error ? <p role="alert" className="mt-5 text-[14px] text-text-2">Requests could not be loaded.</p> : <MessageRequests initial={requests} currentUserId={user.id} />}
    </main>
  );
}

export default function MessageRequestsPage() {
  return <Suspense fallback={<div className="mx-auto mt-8 h-48 max-w-[600px] rounded-2xl bg-skeleton" aria-hidden />}><RequestsContent /></Suspense>;
}

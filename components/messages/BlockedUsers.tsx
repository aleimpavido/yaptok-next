"use client";

import { useState } from "react";
import { Avatar } from "@/components/Avatar";
import { callRpc } from "@/lib/social/client";

export type BlockedUser = { id: string; username: string; displayName: string; avatarUrl: string | null };

export function BlockedUsers({ initial }: { initial: BlockedUser[] }) {
  const [users, setUsers] = useState(initial);
  const [busy, setBusy] = useState<string | null>(null);
  const [message, setMessage] = useState("");

  async function unblock(user: BlockedUser) {
    setBusy(user.id); setMessage("");
    const result = await callRpc("unblock_user", { p_user: user.id });
    if (result.ok) {
      setUsers((old) => old.filter((item) => item.id !== user.id));
      setMessage(`@${user.username} has been unblocked.`);
    } else setMessage("Could not unblock this account.");
    setBusy(null);
  }

  return (
    <div className="mt-5">
      {message && <p role="status" className="mb-3 text-[13px] text-text-2">{message}</p>}
      {users.length === 0 ? <p className="rounded-xl border border-divider p-5 text-[14px] text-text-2">You have not blocked anyone.</p> : (
        <ul className="divide-y divide-divider">
          {users.map((user) => <li key={user.id} className="flex items-center gap-3 py-3">
            <Avatar name={user.displayName} url={user.avatarUrl} size={40} />
            <span className="min-w-0 flex-1"><span className="block truncate text-[14px] font-medium text-text">{user.displayName}</span><span className="text-[12px] text-text-3">@{user.username}</span></span>
            <button type="button" disabled={busy === user.id} onClick={() => void unblock(user)} className="btn-secondary">{busy === user.id ? "Saving…" : "Unblock"}</button>
          </li>)}
        </ul>
      )}
    </div>
  );
}

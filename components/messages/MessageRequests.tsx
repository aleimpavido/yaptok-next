"use client";

import Link from "next/link";
import { useState } from "react";
import { Avatar } from "@/components/Avatar";
import { callRpc } from "@/lib/social/client";

export type MessageRequestView = {
  senderId: string;
  username: string;
  displayName: string;
  avatarUrl: string | null;
  body: string;
  createdAt: string;
};

export function MessageRequests({ initial }: { initial: MessageRequestView[] }) {
  const [requests, setRequests] = useState(initial);
  const [busy, setBusy] = useState<string | null>(null);
  const [accepted, setAccepted] = useState<string[]>([]);
  const [message, setMessage] = useState("");

  async function decide(request: MessageRequestView, accept: boolean) {
    setBusy(request.senderId);
    setMessage("");
    const result = await callRpc<string>("dm_request_action", { p_sender: request.senderId, p_accept: accept });
    if (result.ok) {
      setRequests((old) => old.filter((item) => item.senderId !== request.senderId));
      if (accept) setAccepted((old) => [...old, request.username]);
      setMessage(accept ? "Request accepted." : "Request declined.");
    } else setMessage("This request could not be updated. Refresh and try again.");
    setBusy(null);
  }

  return (
    <div className="mt-4">
      {message && <p role="status" className="mb-3 text-[13px] text-text-2">{message}</p>}
      {requests.length === 0 && accepted.length === 0 ? (
        <p className="rounded-xl border border-divider p-5 text-[14px] text-text-2">No pending message requests.</p>
      ) : null}
      <ul className="space-y-3">
        {requests.map((request) => (
          <li key={request.senderId} className="rounded-2xl border border-divider bg-panel p-4">
            <div className="flex items-start gap-3">
              <Avatar name={request.displayName} url={request.avatarUrl} size={44} />
              <div className="min-w-0 flex-1">
                <p className="font-semibold text-text">{request.displayName} <span className="font-normal text-text-3">@{request.username}</span></p>
                <p className="mt-1 whitespace-pre-wrap break-words text-[14px] text-text-2">{request.body || "Shared a clip with you."}</p>
                <div className="mt-3 flex gap-2">
                  <button type="button" disabled={busy === request.senderId} onClick={() => void decide(request, true)} className="btn-primary">{busy === request.senderId ? "Saving…" : "Accept"}</button>
                  <button type="button" disabled={busy === request.senderId} onClick={() => void decide(request, false)} className="btn-secondary">Decline</button>
                </div>
              </div>
            </div>
          </li>
        ))}
      </ul>
      {accepted.map((username) => <p key={username} className="mt-3 text-[13px] text-text-2">You accepted @{username}. <Link className="font-medium text-[var(--accent)] hover:underline" href={`/messages/${username}`}>Open conversation</Link></p>)}
    </div>
  );
}

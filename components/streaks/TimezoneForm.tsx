"use client";

import { useState, type FormEvent } from "react";
import { callRpc } from "@/lib/social/client";

export function TimezoneForm({ initial }: { initial: string }) {
  const [timezone, setTimezone] = useState(initial);
  const [busy, setBusy] = useState(false);
  const [message, setMessage] = useState("");

  async function save(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setMessage("");
    const result = await callRpc<string>("set_my_timezone", { p_timezone: timezone.trim() });
    setMessage(result.ok ? "Timezone saved. Your streak calendar will use this timezone." : result.code === "timezone_invalid" ? "Enter a valid IANA timezone, for example Europe/Berlin." : "Timezone could not be saved.");
    setBusy(false);
  }

  return (
    <form onSubmit={(event) => void save(event)} className="mt-3 flex flex-col gap-2 sm:flex-row">
      <label className="sr-only" htmlFor="streak-timezone">Timezone</label>
      <input id="streak-timezone" className="field min-w-0 flex-1" value={timezone} onChange={(event) => setTimezone(event.target.value)} placeholder="Europe/Berlin" maxLength={80} />
      <button type="submit" disabled={busy || !timezone.trim()} className="btn-secondary shrink-0">{busy ? "Saving…" : "Save timezone"}</button>
      {message && <p role="status" className="basis-full text-[12px] text-text-2 sm:basis-auto">{message}</p>}
    </form>
  );
}

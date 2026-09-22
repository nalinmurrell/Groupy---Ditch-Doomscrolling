// Fan a new message out to the other members' iPhones via APNs.
//
// Called by the `notify_new_message` database trigger with the standard
// webhook payload. The record is re-read from the database (service role)
// so the payload is only ever a hint.
//
// Secrets (supabase secrets set ...):
//   APNS_KEY_ID       10-char key id from the developer portal
//   APNS_TEAM_ID      S9XJ3Y8P67
//   APNS_PRIVATE_KEY  contents of the .p8 file, including BEGIN/END lines
//   APNS_BUNDLE_ID    com.groupy.app
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from "npm:@supabase/supabase-js@2";

const env = (name: string) => {
  const v = Deno.env.get(name);
  if (!v) throw new Error(`missing ${name}`);
  return v;
};

const db = createClient(env("SUPABASE_URL"), env("SUPABASE_SERVICE_ROLE_KEY"), {
  auth: { persistSession: false },
});

// ---- APNs auth: an ES256 JWT, good for an hour, reused across requests.

let cachedToken: { value: string; issuedAt: number } | null = null;

const base64url = (data: ArrayBuffer | Uint8Array | string) => {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : new Uint8Array(data);
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
};

async function apnsToken(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cachedToken && now - cachedToken.issuedAt < 50 * 60) return cachedToken.value;

  const pem = env("APNS_PRIVATE_KEY").replace(/\\n/g, "\n");
  const der = Uint8Array.from(
    atob(pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s+/g, "")),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  const header = base64url(JSON.stringify({ alg: "ES256", kid: env("APNS_KEY_ID") }));
  const claims = base64url(JSON.stringify({ iss: env("APNS_TEAM_ID"), iat: now }));
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(`${header}.${claims}`),
  );
  cachedToken = { value: `${header}.${claims}.${base64url(signature)}`, issuedAt: now };
  return cachedToken.value;
}

// ---- One push.

async function push(
  device: { token: string; environment: string },
  payload: Record<string, unknown>,
): Promise<"ok" | "dead" | "failed"> {
  const host = device.environment === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com";
  const res = await fetch(`${host}/3/device/${device.token}`, {
    method: "POST",
    headers: {
      "authorization": `bearer ${await apnsToken()}`,
      "apns-topic": env("APNS_BUNDLE_ID"),
      "apns-push-type": "alert",
      "apns-priority": "10",
    },
    body: JSON.stringify(payload),
  });
  if (res.ok) return "ok";
  const body = await res.text();
  console.error(`apns ${res.status} for ${device.environment} token: ${body}`);
  // 410 = no longer registered; BadDeviceToken usually means the token is
  // for the other environment. Either way, stop trying it.
  return res.status === 410 || body.includes("BadDeviceToken") ? "dead" : "failed";
}

// ---- The webhook.

Deno.serve(async (req) => {
  const hook = await req.json().catch(() => null);
  if (hook?.type !== "INSERT" || hook?.table !== "messages" || !hook.record?.id) {
    return new Response("ignored", { status: 200 });
  }

  const { data: message } = await db
    .from("messages")
    .select("id, conversation_id, sender_id, kind, body")
    .eq("id", hook.record.id)
    .single();
  if (!message) return new Response("no such message", { status: 200 });

  const [{ data: sender }, { data: conversation }, { data: members }] = await Promise.all([
    db.from("profiles").select("display_name").eq("id", message.sender_id).single(),
    db.from("conversations").select("is_group, name").eq("id", message.conversation_id).single(),
    db.from("conversation_members").select("user_id")
      .eq("conversation_id", message.conversation_id).neq("user_id", message.sender_id),
  ]);
  if (!sender || !conversation || !members?.length) return new Response("nobody to tell", { status: 200 });

  const { data: devices } = await db
    .from("device_tokens")
    .select("token, environment")
    .in("user_id", members.map((m) => m.user_id));
  if (!devices?.length) return new Response("no devices", { status: 200 });

  const first = sender.display_name.split(" ")[0];
  const text = message.kind === "photo" ? "📸 Snap" : message.kind === "video" ? "🎥 Video" : message.body ?? "";
  const alert = conversation.is_group
    ? { title: conversation.name ?? "Group", body: `${first}: ${text}` }
    : { title: sender.display_name, body: text };

  const payload = {
    aps: { alert, sound: "default", "thread-id": message.conversation_id },
    conversation_id: message.conversation_id,
  };

  const results = await Promise.all(devices.map((d) => push(d, payload)));
  const dead = devices.filter((_, i) => results[i] === "dead").map((d) => d.token);
  if (dead.length) await db.from("device_tokens").delete().in("token", dead);

  return new Response(JSON.stringify({ sent: results.filter((r) => r === "ok").length, dead: dead.length }), {
    headers: { "content-type": "application/json" },
  });
});

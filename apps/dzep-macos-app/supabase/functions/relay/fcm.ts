// Firebase Cloud Messaging (HTTP v1) for the relay's Android pushes: the
// service account's OAuth2 token, the message, and what an error means.

import { decodeBase64 } from "jsr:@std/encoding@1/base64";
import { encodeBase64Url } from "jsr:@std/encoding@1/base64url";

/** The fields of the Firebase service-account JSON the relay uses. */
export type ServiceAccount = {
  project_id: string;
  client_email: string;
  private_key: string;
  private_key_id?: string;
  token_uri?: string;
};

export const scope = "https://www.googleapis.com/auth/firebase.messaging";
export const tokenAudience = "https://oauth2.googleapis.com/token";

/** An FCM registration token. */
export const fcmToken = (v: unknown): v is string => typeof v === "string" && /^[A-Za-z0-9_:\-]{100,4096}$/.test(v);

export const fcmKinds = ["reminder", "terminal", "activity"] as const;
export type FcmKind = (typeof fcmKinds)[number];

/** The service account from FCM_SERVICE_ACCOUNT's JSON; a string says what's wrong. */
export function parseServiceAccount(raw: string): ServiceAccount | string {
  let sa: Record<string, unknown>;
  try {
    sa = JSON.parse(raw);
  } catch {
    return "FCM_SERVICE_ACCOUNT is not JSON";
  }
  for (const f of ["project_id", "client_email", "private_key"]) {
    if (typeof sa?.[f] !== "string" || !sa[f]) return `FCM_SERVICE_ACCOUNT has no ${f}`;
  }
  return sa as ServiceAccount;
}

/** The PEM private key (PKCS#8) for RS256. */
export const importPrivateKey = (pem: string) =>
  crypto.subtle.importKey(
    "pkcs8",
    decodeBase64(pem.replace(/-----[A-Z ]+-----/g, "").replace(/\s/g, "")),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );

/** The signed JWT the service account trades for an access token, valid an hour from [now] (unix seconds). */
export async function assertion(sa: ServiceAccount, key: CryptoKey, now: number): Promise<string> {
  const part = (o: unknown) => encodeBase64Url(new TextEncoder().encode(JSON.stringify(o)));
  const header = { alg: "RS256", typ: "JWT", ...(sa.private_key_id ? { kid: sa.private_key_id } : {}) };
  const claims = { iss: sa.client_email, scope, aud: tokenAudience, iat: now, exp: now + 3600 };
  const unsigned = `${part(header)}.${part(claims)}`;
  const sig = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, new TextEncoder().encode(unsigned));
  return `${unsigned}.${encodeBase64Url(new Uint8Array(sig))}`;
}

/** Trades [jwt] for an OAuth2 access token at Google; [fetcher] for tests. */
export async function exchange(
  jwt: string,
  fetcher: typeof fetch = fetch,
): Promise<{ token: string; expiresIn: number }> {
  const res = await fetcher(tokenAudience, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion: jwt }),
  });
  const answer = await res.json().catch(() => null);
  if (!res.ok || typeof answer?.access_token !== "string") {
    throw new Error(`OAuth ${res.status} ${answer?.error ?? ""} ${answer?.error_description ?? ""}`.trim());
  }
  return { token: answer.access_token, expiresIn: typeof answer.expires_in === "number" ? answer.expires_in : 3600 };
}

/** FCM v1's request body: data only, the app shows what it decrypts. */
export function fcmMessage(token: string, kind: FcmKind, enc: string, collapse?: string) {
  return {
    message: {
      token,
      data: { kind, enc },
      android: {
        priority: "high",
        ...(collapse ? { collapse_key: collapse } : {}),
        // A session's state is stale within the hour; a reminder or an alert keeps a day.
        ttl: kind === "activity" ? "3600s" : "86400s",
      },
    },
  };
}

/** Whether FCM's error answer says the token is gone for good (the app uninstalled, a token not FCM's). */
export function fcmGone(status: number, answer: unknown): boolean {
  const error = answer && typeof answer === "object" && "error" in answer ? answer.error : null;
  const field = (k: string) => (error && typeof error === "object" && k in error ? Reflect.get(error, k) : undefined);
  const details: unknown = field("details");
  const codes = Array.isArray(details)
    ? details.map((d) => (d && typeof d === "object" && "errorCode" in d ? d.errorCode : undefined))
    : [];
  const message = field("message");
  if (status === 404 || field("status") === "NOT_FOUND" || codes.includes("UNREGISTERED")) return true;
  return (
    (status === 400 || field("status") === "INVALID_ARGUMENT" || codes.includes("INVALID_ARGUMENT")) &&
    typeof message === "string" &&
    /registration token/i.test(message)
  );
}

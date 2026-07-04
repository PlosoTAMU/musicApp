import { initializeApp } from "firebase/app";
import { initializeFirestore } from "firebase/firestore";
import { getStorage } from "firebase/storage";
import { getAuth } from "firebase/auth";

// Same Firebase PROJECT as the iOS app, different app registration:
// console → Project settings → Add app → Web → copy this config.
// (GoogleService-Info.plist is iOS-only; the Web SDK uses this object.)
const firebaseConfig = {
  apiKey: "AIzaSyBVO42EH6y1VFY6HM14hZbdjmO4AoQfrl0",
  authDomain: "pulsor-912b7.firebaseapp.com",
  projectId: "pulsor-912b7",
  storageBucket: "pulsor-912b7.firebasestorage.app",
  messagingSenderId: "531735893373",
  appId: "1:531735893373:web:44c5b010df408b43696814"
};


const app = initializeApp(firebaseConfig);

// ignoreUndefinedProperties: optional TrackRef fields (`yt`, `track`) are
// simply omitted — matching how the Swift side skips nil keys.
export const db = initializeFirestore(app, { ignoreUndefinedProperties: true });
export const storage = getStorage(app);

// ── Shared-secret identity ──────────────────────────────────────────────
// The home secret deterministically derives an email/password pair; every
// device that knows the secret signs into the SAME Firebase account, so all
// state lives under one uid. Derivation strings must match the iOS side
// (SyncSessionManager.deriveCreds) byte-for-byte.
import { createHash } from "crypto";
import {
  signInWithEmailAndPassword, createUserWithEmailAndPassword,
} from "firebase/auth";

const sha = (s: string) => createHash("sha256").update(s, "utf8").digest("hex");

export const deriveCreds = (secret: string) => ({
  email: `${sha("pulsor-home-v1|" + secret).slice(0, 24)}@pulsor.app`,
  password: sha("pulsor-key-v1|" + secret),
});

/** Sign in with the derived account; first device ever creates it. */
export async function bootstrapAuth(secret: string): Promise<string> {
  const auth = getAuth(app);
  const { email, password } = deriveCreds(secret);
  try {
    return (await signInWithEmailAndPassword(auth, email, password)).user.uid;
  } catch (e: unknown) {
    const code = (e as { code?: string })?.code ?? "";
    if (code === "auth/user-not-found" || code === "auth/invalid-credential") {
      try {
        return (await createUserWithEmailAndPassword(auth, email, password)).user.uid;
      } catch (e2: unknown) {
        if ((e2 as { code?: string })?.code === "auth/email-already-in-use")
          throw new Error("Secret mismatch — this home exists but the secret differs.");
        throw e2;
      }
    }
    throw e;
  }
}

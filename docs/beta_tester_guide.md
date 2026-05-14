# HexTrail Beta — Tester Guide

**Build:** 0.9.1 (14)
**Tracks:** iOS TestFlight · Android Closed Testing (Play Console)
**Test window:** ~1 week
**Feedback channel:** _(fill in: Slack / email / form URL)_

Thanks for helping shape HexTrail. This guide tells you what's new, what to try, and what to flag. **Please skim it before your first walk** — a couple of behaviors are intentional and easy to misread as bugs.

---

## 1. What HexTrail is

HexTrail turns a real-world walk into a tile-capture game. As you walk along a supported trail (currently the **Burke-Gilman**), the map is divided into hexagonal tiles. Walking onto a tile within range captures it for you. Other players can take it back later. Sections of the trail are scored by who controls the most tiles. Milestones unlock as you progress.

You play either:
- **Anonymous** — works instantly, no sign-up. Your progress is tied to that one device install.
- **Signed in (Apple or Google)** — your progress is restored on any device, and won't be lost if you reinstall the app.

---

## 2. Install

### iOS (TestFlight)
1. Install **TestFlight** from the App Store if you don't already have it.
2. Open the invite email and tap **View in TestFlight** → **Accept** → **Install**.
3. Allow **Location** ("While Using" is fine; "Always" gives the best experience for background captures) and **Notifications** when prompted.

### Android (Closed Testing)
1. Open the **opt-in URL** from the invite email on the device you'll test on.
2. Tap **Become a tester** → wait a minute → tap **Download it on Google Play**.
3. Install. Allow **Location** and **Notifications** when prompted.
4. If the Play Store says "item not found," wait 10–15 minutes after opting in — the entitlement takes a moment to propagate.

---

## 3. First-launch flow (read this!)

1. The app starts you in **Anonymous** mode automatically. There is **no sign-in screen** — you can start walking immediately.
2. The map should center on your location (Seattle area, near the Burke-Gilman). If it doesn't, check Location permission.
3. The trail is drawn as a corridor of hexes. **Only the trail-core hexes glow** to suggest your next capture — that is intentional. If you see a non-trail hex glow, please report it (see §6).
4. Walk onto a hex within capture range — it'll flip to your color and the count goes up.

**Save your progress (recommended on first session):**
- Open the menu (top-left) → **"Save my progress…"** → choose **Apple** or **Google**.
- After linking, the menu changes to a green **"Signed in with Apple/Google"** row — that's the confirmation. The "Save my progress" CTA disappears once linked, by design.

---

## 4. What's new in build 14 — the focus areas

Please spend extra time on these. Each item lists **what to do** and **what should happen**.

### A. Account linking & recovery (top priority)

**A1. Link a fresh anonymous session.**
- Walk a few hexes (capture 1–5), then menu → "Save my progress…" → Apple or Google.
- **Expect:** sheet closes, menu now shows "Signed in with …", capture count is unchanged.

**A2. Reinstall recovery (the big one).**
- After A1, **delete the app**, reinstall it, open it.
- Tap menu → "Save my progress…" → choose the **same provider** you used in A1.
- **Expect:** your previous captures, milestones, and "Founder" badge come back **automatically and immediately** — without needing to close and re-open the app.
- **Flag if:** you see a different (smaller / empty) account, or the map stays empty until you restart.

**A3. Try to link with a *different* provider on a session that already has progress.**
- Capture a couple of hexes anonymously, then menu → "Save my progress…" → pick a provider that's already in use by **another** account on your device.
- **Expect:** the app refuses the swap and shows an error message rather than silently wiping your captures.

**A4. Cross-device check (optional, if you have a second device).**
- Sign in with the same provider on a second phone.
- **Expect:** your tiles appear on the second device too.

### B. Off-trail glow regression check

In a previous build, hexes outside the trail occasionally glowed as "next capture" suggestions. This was fixed in build 14.

- During your walk, watch the suggested-capture glow.
- **Expect:** the glowing target is always on the visible trail corridor.
- **Flag if:** any hex glows that's clearly off the trail (in a yard, parking lot, or street block away).

### C. Notifications

- Have a friend (or your other account) capture a tile you own.
- **Expect:** push notification "You lost a tile" within a few seconds. Tapping it opens the map.
- **Flag if:** notification never arrives, or tapping it doesn't open the map.

### D. Map performance

- Pan and zoom around the trail.
- **Expect:** smooth panning, no white flashes, no map disappearing for more than ~1 second.
- **Flag if:** the map goes blank, tiles fail to load, or the app stutters badly.

---

## 5. Smaller things worth poking at

- **Milestones:** capture your first tile, get a 3-in-a-row streak, hit 25% of the Burke-Gilman — each should pop a milestone toast/sheet.
- **Section flips:** when you take the majority of a trail section, the section color flips to yours.
- **Backgrounding:** lock your phone mid-walk for 30 seconds, unlock — the map should resume cleanly.
- **Permissions denied:** intentionally deny Location once and reopen — the app should explain what's needed instead of crashing.

---

## 6. How to report something

For each issue, please send:

1. **Platform + build** — e.g. "iOS TestFlight 0.9.1 (14)" or "Android 0.9.1 (14)".
2. **Device + OS** — e.g. "iPhone 14 Pro, iOS 18.2" / "Pixel 7, Android 15".
3. **What you did** — short numbered steps.
4. **What you expected.**
5. **What actually happened.**
6. **Screenshot or screen recording** if at all possible.
7. **Roughly when** it happened (helps us cross-reference logs).

Severity tags help us triage:
- **🔴 Blocker** — crashes, data loss, can't sign in, can't capture anything.
- **🟠 Major** — feature broken but workaround exists.
- **🟡 Minor** — visual glitch, copy issue, polish.

---

## 7. Privacy & data — what testers should know

- Location is used **only while the app is in use** (or in background if you grant Always) to compute hex captures. We don't sell or share location data.
- Apple/Google sign-in stores only your provider user ID and a derived account — no email scraping, no contacts.
- A test account can be wiped on request — message us your account ID (visible under menu → Account, in a future build) or describe the timing of your captures and we'll find it.

---

## 8. Known limitations in this build

- Only the **Burke-Gilman trail** is supported in this beta. Capturing off-trail won't work.
- The "Save my progress" sheet only offers **Apple** and **Google** — email/password is not in scope for this beta.
- A few analyzer-info lints exist in dev tooling (not in shipping code) — ignore.

---

## 9. Quick checklist for testers

Copy this into your reply when you're done with a session:

```
Build: 0.9.1 (14) — iOS / Android
Device: ___
Walk length: ___ minutes / ___ hexes captured

[ ] Anonymous capture worked
[ ] Linked with Apple — no progress lost
[ ] Linked with Google — no progress lost
[ ] Reinstalled + re-signed-in → progress restored automatically
[ ] No off-trail hex ever glowed
[ ] Notifications received when a tile was taken
[ ] No crashes, no blank-map episodes

Issues found:
1.
2.
```

Thanks again — your reports drive the next build. 🥾

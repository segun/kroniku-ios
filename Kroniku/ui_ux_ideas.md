UI/UX implementation plan

## 1. Timeline: make generated memories feel authored

- [x] Replace transcript-like/truncated card titles with a readable summary derived from the event's person, interaction, calendar title, or detail.
- [x] Resolve calendar attendee emails into display names where names are available; format remaining attendees as readable labels rather than a raw comma-separated payload.
- [x] Add a short label to the confidence shield so its meaning is explicit.
- [x] Remove the repeated Timeline heading and branded shell from the content hierarchy where the navigation already provides that context.
- [x] Replace the repeated time label on each card with a persistent vertical time rail and event dot.
- [x] Use subtle morning/day/evening tinting so the day thread communicates time-of-day context.

**Acceptance check:** timeline cards scan as summaries, attendees are human-readable, the status icon is self-explanatory, and the rail/tint remain legible on both empty and populated days.

## 2. Settings: separate controls from system state

- [x] Remove the redundant large Kroniku settings header card.
- [x] Group the long settings screen into clear sections: Data sources, Permissions, Health, and Account/data.
- [x] Move Export and Delete data near the top of the settings flow.
- [x] Give permission rows a muted read-only treatment distinct from user-controlled toggles.
- [x] Merge the duplicate HealthKit permission row into the Health section.
- [x] Rename the time-semantics toggle and add a concise examples caption.
- [x] Add explanatory captions for voice, notes, contacts, and Bluetooth controls.

**Acceptance check:** every row makes it clear whether it is controlled in Kroniku or in iOS Settings, HealthKit appears once, and core data actions are easy to find.

## 3. Capture: reduce framing and make the primary action clear

- [x] Remove the redundant branded Capture card/header from the capture flow.
- [x] Keep voice as the primary capture path; expose the manual form behind a compact “Type instead” control after voice is available.
- [x] Give Shared note a useful placeholder and compact empty state.
- [x] Style Link photos, Select related memories, and Resolve person as matching secondary actions rather than competing primary CTAs.
- [x] Keep Save as the only form-level primary action.

**Acceptance check:** capture opens directly on the fast path, manual entry remains available, and optional enrichment actions have equal visual weight.

## 4. Onboarding: fix clarity and visual hierarchy

- [x] Fix the last-slide Get Started ghosting/z-order issue by keeping the CTA outside the slide artwork.
- [x] Increase icon contrast inside the blurred circles.
- [x] Use the available slide space for a restrained timeline preview behind the onboarding content.
- [x] Preserve the working eyebrow/headline/subtext hierarchy and progress indicators.

**Acceptance check:** the final slide has no ghost CTA, icons are readable, and the layout feels intentional on compact and regular iPhone sizes.

## 5. Verification

- [x] Build the iOS app with the existing project scheme.
- [x] Run the focused Swift tests that cover event presentation/privacy behavior, or record the existing scheme limitation if tests cannot run. The current scheme has no test action, so `xcodebuild test` remains unavailable until the test action is configured.
- [ ] Review the changed screens in the simulator/device and check dynamic text does not overlap or truncate unexpectedly.

## Source notes

The original unstructured observations are retained below as design context and traceability.

---

UI/UX

Biggest levers:
Raw data is leaking through the "diary that writes itself" promise — card titles are literal truncated transcripts, calendar attendees show as bare emails, and some settings copy reads like a variable name. The gap between the pitch and what's on screen is the most visible issue in the whole app.
A branded "Kroniku" header card repeats on every screen (Settings, Contact moment, Timeline), restating the app name plus a category label the nav bar or tab bar already shows. That's space you don't get back, especially in a capture flow that's supposed to be fast.
Settings is one long undifferentiated list — toggles you control and read-only iOS permission statuses look identical, and Health data shows up in two different sections.

Onboarding
On the last slide ("Your story stays yours"), there's ghost text reading "Get Started" showing through behind the lock icon inside the dark circle — reads like a caught mid-transition frame or a z-index issue. Since these are simulator captures, worth checking on a real device.
The icon-in-blurred-circle treatment is soft to the point of low contrast — the shield/lock on the navy slide is barely readable against its own blur.
Each slide leaves roughly half the screen empty between the subtext and the button. A faded preview of the actual timeline behind glass would sell "your life, remembered" harder than negative space does.
What's working: the eyebrow/headline/subtext hierarchy is clean, and the pill progress dots with the elongated active state are a nice detail.


Settings
The dark "Kroniku / Settings & privacy" card at the top just restates the page title above it — three ways of saying "you're in Settings" before the first control. Cut it or shrink it a lot.
Feature toggles ("Attach weather snapshots") and system permission statuses ("Bluetooth: authorized") are styled identically — same card, same label-left layout. A user can't tell "I control this here" from "I'd have to leave the app to change this" at a glance. Give permission rows a visibly different, more muted treatment.
Health data appears twice: once as real toggles (Steps, Heart rate, Sleep, Mindful minutes), and again as a single read-only "HealthKit: authorized" row under a different header. Merge those.
"When labels: sunrise, sunset, weekend, holiday" reads as a run-on. Try "Attach time-of-day labels" as the toggle title with the examples as a caption underneath.
The Health section has a one-line explanation ("Choose exactly which HealthKit metrics..."); the more jargon-y toggles don't ("Enable bluetooth context enrichment," "Enable contacts resolution") — a reader can't tell what they're opting into, which cuts against the whole "you decide what Kroniku remembers" pitch.
It's a genuinely long list (14+ rows). Consider named sub-pages (Data sources, Permissions, Health, Account) instead of one scroll, and pull Export/Delete data up near the top — that's your core value prop, not a footnote below fourteen toggles.

Capture flow (Contact moment)
"Link photos" is a bold, full-width orange button — the same visual weight as a primary CTA — while "Select related memories" and "Resolve person," the same kind of optional action, are muted gray pills. That leaves two buttons competing for "most important" on screen, and neither is Save. Bring Link photos down to match the other two.
Before reaching "Who" or "What happened," a user scrolls past Cancel/Contact moment/Save, then a big "Kroniku / Capture" card, then the "Record a moment" voice option — three layers of framing for a flow whose whole pitch is "capture first, refine second."
Shared note reserves a tall empty box with no placeholder, unlike "What happened," which shows a helpful example. Add placeholder copy, or let it start compact and grow with input.
Worth deciding explicitly: is voice meant to be the primary way to log a moment, with typing as fallback? If so, don't give the manual form equal visual billing by default — collapse it behind a "type instead" toggle so voice reads as the main path.

Timeline
The card title is a truncated transcript, not a summary, cut off mid-word ("...at 8..."). This is the clearest gap between "a diary that writes itself" and what's shipping — I'd fix this before anything else on this list.
Attendees show as raw emails rather than resolved names — same underlying issue, unprocessed data surfacing directly to the user.
The shield/checkmark icon has no label, so its meaning is a guess (verified? synced? stored locally?). Whatever it means, say it in a word or two.
"Timeline" is labeled three times on one screen — bottom tab, branded header eyebrow, and section header. Pick one.
Two events both stamp "08:00 AM" as text at the top of their own card. A persistent vertical time rail with a dot per event would carry the timeline metaphor visually instead of repeating the time in every card.

One more thing worth reconnecting: the early concept work for Kroniku was built around a "day thread" timeline with dawn-to-dusk ambient gradients, and Settings already computes sunrise/sunset/weekend/holiday labels. None of that time-of-day awareness shows up visually on the Timeline itself right now — it's the same cream/white regardless of when something happened. A subtle warm tint on morning entries and cooler tones toward evening would make "context, fused" felt rather than just stated in onboarding copy.
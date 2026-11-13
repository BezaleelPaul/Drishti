# ELYTRIVA — Brand Identity

> **ELYTRIVA** — *Illuminating vision through intelligence.*

---

## 1. What the name is (and what it is not)

ELYTRIVA is a **coined brand name** created for this project. It is not an
established Latin, Greek, or Sanskrit word, and it has no verified
etymological root. We do not claim it "means" anything in a dead language.

| Element | Role in our identity (interpretive, not etymological) |
|---|---|
| **ELY** | Elevation and clarity — the two things a screening verdict must deliver. |
| **TRI** | The **three screening outcomes** the product actually returns: **GOOD / BORDERLINE / REJECT** (the quality gate's honest verdict set). |
| **VA** | Vision and advancement — the domain and the direction. |

**Suggested formal expansion (a backronym we authored):**
**E**xplainable **L**earning for **Y**ielding **T**rustworthy **R**etinal
**I**nsights and **V**ision **A**ssessment.

## 2. Why the "TRI" reading is not decoration

The name maps onto the product's actual behaviour, not onto marketing copy.
The quality gate (`src/quality/checker.py`, mirrored on-device in
`flutter_app/lib/services/ml/quality_gate.dart`) returns exactly three
verdicts, and the product never invents a fourth:

- **GOOD** — certified reliable, proceeds to grading.
- **BORDERLINE** — re-assessed for anatomical landmarks; may clear or must be
  recaptured.
- **BAD / REJECT** — never graded; recapture guidance is issued (and the
  recapture cap escalates to a human).

That is the "TRI" in ELYTRIVA: a tool whose first answer is *whether it can
answer at all*.

## 3. Palette

The brand kit's palette was already the app's palette — the rebrand was a
logo/wordmark change, not a colour rework:

| Token | Hex | Use in the app |
|---|---|---|
| Navy | `#0B132B` | App background (`ScannerHUDTheme.background`), launcher adaptive background, wordmark ground |
| Cyan | `#00B4D8` | Primary accent (`ScannerHUDTheme.primaryCyan`, `FigmaColors.primary` family) |
| Teal | `#18D6C7` | Secondary accent / success-state glow |
| Orange | `#FF9F6E` | Warning accent (quality flags, review prompts) |
| White | `#FFFFFF` | Text, reticle, high-contrast surfaces |

## 4. Assets and where they are used

Source of truth: `ELYTRIVA_Brand_Kit_Flutter/` (repo root) — SVG masters plus
raster exports. In-app copies live in `flutter_app/assets/branding/`:

| Asset | Used by |
|---|---|
| `elytriva_icon_1024.png` | `flutter_launcher_icons` → `image_path` (launcher master; build-time only) |
| `elytriva_icon_512.png` | Launcher adaptive foreground + splash brand mark (runtime asset) |
| `elytriva_logo_horizontal_no_tagline.png` | Splash wordmark (runtime asset) |

The **tagline variant** of the horizontal logo was deliberately *not* shipped:
its "AI-POWERED RETINAL SCREENING" strapline contradicts the product's
differentiation (explainable, evidence-linked, three honest outcomes), so the
splash composes the wordmark with its own line instead —
*EXPLAINABLE RETINAL SCREENING · GOOD / BORDERLINE / REJECT*.

Asset registration is an **explicit allowlist** in `flutter_app/pubspec.yaml` —
never a directory glob, so a stray file can never be shipped by accident.

## 4a. Splash composition (why it looks like one surface)

The splash renders the brand mark **over the live Flame calibration**, not as
a pasted image:

- the scanner runs in **chrome-less mode** on the splash
  (`ScannerView(showConsoleChrome: false)`) — the clinical console's 56 px
  status band and 140 px telemetry band are meant for a standalone card, not
  for a 268 px stage behind a logo (they would sit under the mark and read
  as overlapping text);
- the mark **breathes** on its own 3.2 s clock (scale ±2.8 % + a soft cyan
  glow) so it shares the same motion language as the scanner;
- the mark's tile is the same navy (`#0B132B`) as the canvas, so the tile edge
  disappears into the background and only the eye/vessel artwork reads;
- the wordmark is **width-constrained** (not height-constrained) and centred:
  the master logo is 5.6:1, so sizing by height inside a stretched column
  overflowed sideways and read as off-centre.

## 5. Usage rules

1. **One identity.** The device app, the launcher icon and the printed report
   carry the ELYTRIVA mark. The wordmark is always the bundled asset, never
   re-typed or re-styled text (a re-typed wordmark drifts from the master).
2. **Honesty is part of the brand.** ELYTRIVA never shows a grade it did not
   produce: ungradable captures are rejected, uncertain grades are routed to
   review, and the model backend is always named. A brand about *illuminating
   vision* cannot ship fabricated findings.
3. **The tagline is a promise about behaviour, not adjectives:**
   *Explainable* (criterion-linked evidence, not a black box), *Trustworthy*
   (calibrated, audited, fail-closed), *Retinal* (the actual imaging domain).
4. **No trademark claim.** The brand kit is a concept package generated for
   this project; it has not been through trademark clearance. Before any
   public release, review the vector geometry and typography against final
   brand guidelines.

## 6. Rebrand scope — what is done, what is not

**Done (device app):** launcher icon (adaptive, navy `#0B132B`), splash brand
mark + wordmark, app title, dashboard / nav rail / about / report headers,
SMS referral slip, the Android launcher label and the iOS display name — all
five UI languages (en/kn/hi/te/ta) rebranded. The earlier product names no
longer appear anywhere the operator, patient or specialist can see.

**Intentionally kept (technical, invisible to users):**
- the Dart package id `netra_ai_mobile` and the Android application id
  `in.drishtiai.netra_ai_mobile` — changing them breaks the installed app
  (and the signed release) for zero user-visible gain;
- the `--dart-define` variable names `DRISHTI_BASE_URL` / `DRISHTI_API_KEY` /
  `DRISHTI_ALLOW_HTTP_LOOPBACK` — deployment scripts pass these by name;
- internal class/file names inside the LiteRT inference path
  (`drishti_inference_engine.dart`, `drishti_analysis_controller.dart`, …) —
  they are implementation details, and renaming them would touch the
  ordinal-regression bridge for no product benefit.

**Still to rebrand (one coordinated content pass, not code):**
- `README.md` and `docs/` (evaluation reports, privacy, handoff),
- the PDF screening dossier header (`src/reporting/`),
- the Streamlit demo chrome (`demo/ui_chrome.py`),
- the SIH presentation deck.

These are judge-facing documents and published evidence; renaming them is a
content decision, and it should be done in one pass so the product name,
the docs and the deck never disagree in front of a jury.

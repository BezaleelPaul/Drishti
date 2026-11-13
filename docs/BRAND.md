# DRISHTI — Brand Identity

> **DRISHTI** — *Illuminating vision through intelligence.*

---

## 1. What the name represents

DRISHTI (Sanskrit: दृष्टि, meaning *vision*, *sight*, or *insight*) reflects the core clinical mission of the platform: delivering autonomous, explainable, and trustworthy diabetic retinopathy screening for rural and remote primary healthcare.

| Element | Role in our identity |
|---|---|
| **Autonomous** | 100% offline edge execution on commodity hardware without internet connectivity. |
| **Tri-Verdict Gate** | The **three screening outcomes** the product returns: **GOOD / BORDERLINE / REJECT** (the quality gate's honest verdict set). |
| **Clinical Integrity** | Fail-closed safety architecture preventing false confidence on degraded fundus photographs. |

## 2. Why the Tri-Verdict Gate is not decoration

The identity maps onto the product's actual clinical behaviour, not onto marketing copy.
The quality gate (`src/quality/checker.py`, mirrored on-device in mobile engines) returns exactly three verdicts, and the product never invents a fourth:

- **GOOD** — certified reliable, proceeds to grading.
- **BORDERLINE** — re-assessed for anatomical landmarks; may clear or must be recaptured.
- **BAD / REJECT** — never graded; recapture guidance is issued (and the recapture cap escalates to a human).

A tool whose first answer is *whether it can answer at all*.

## 3. Palette

| Token | Hex | Use in the app |
|---|---|---|
| Navy | `#0B132B` | App background (`ScannerHUDTheme.background`), launcher adaptive background, wordmark ground |
| Cyan | `#00B4D8` | Primary accent (`ScannerHUDTheme.primaryCyan`, `FigmaColors.primary` family) |
| Teal | `#18D6C7` | Secondary accent / success-state glow |
| Orange | `#FF9F6E` | Warning accent (quality flags, review prompts) |
| White | `#FFFFFF` | Text, reticle, high-contrast surfaces |

## 4. Assets and where they are used

Source assets live under `branding/` and `assets/branding/`:

| Asset | Used by |
|---|---|
| `drishti_icon_1024.png` | `flutter_launcher_icons` → `image_path` (launcher master; build-time only) |
| `drishti_icon_512.png` | Launcher adaptive foreground + splash brand mark (runtime asset) |
| `drishti_logo_horizontal_no_tagline.png` | Splash wordmark (runtime asset) |

The **tagline variant** of the horizontal logo was deliberately *not* shipped:
its "AI-POWERED RETINAL SCREENING" strapline contradicts the product's
differentiation (explainable, evidence-linked, three honest outcomes), so the
splash composes the wordmark with its own line instead —
*EXPLAINABLE RETINAL SCREENING · GOOD / BORDERLINE / REJECT*.

## 5. Usage rules

1. **One identity.** The device app, the launcher icon and the printed report
   carry the DRISHTI mark. The wordmark is always the bundled asset, never
   re-typed or re-styled text (a re-typed wordmark drifts from the master).
2. **Honesty is part of the brand.** DRISHTI never shows a grade it did not
   produce: ungradable captures are rejected, uncertain grades are routed to
   review, and the model backend is always named. A brand about *illuminating
   vision* cannot ship fabricated findings.
3. **The tagline is a promise about behaviour, not adjectives:**
   *Explainable* (criterion-linked evidence, not a black box), *Trustworthy*
   (calibrated, audited, fail-closed), *Retinal* (the actual imaging domain).
4. **No trademark claim.** The brand kit is a concept package generated for
   this project; review vector geometry and typography against final
   brand guidelines before commercial deployment.

## 6. Architecture & Identity Scope

**Device App & Interfaces:** launcher icon (adaptive, navy `#0B132B`), splash brand
mark + wordmark, app title, dashboard / nav rail / about / report headers,
referral slip, the Android launcher label and the iOS display name — all
UI languages rebranded.

**Technical Constants:**
- Dart package id `netra_ai_mobile` and Android application id `in.drishtiai.netra_ai_mobile`
- Deployment environment variables: `DRISHTI_BASE_URL` / `DRISHTI_API_KEY` / `DRISHTI_ALLOW_HTTP_LOOPBACK`
- LiteRT inference path: `drishti_inference_engine.dart`, `drishti_analysis_controller.dart`
- Documentation and presentation deck: unified under **DRISHTI**.

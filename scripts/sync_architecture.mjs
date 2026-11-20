#!/usr/bin/env node

/**
 * Drishti Live Architecture Diagram Sync & Screen Pop-up
 *
 * Uses the installed Archify skill to compile an interactive standalone HTML
 * architecture diagram of Drishti and automatically launch it on the user's screen.
 */

import { spawnSync, execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';

const projectRoot = path.resolve(import.meta.dirname, '..');
const archifyBin = path.join(os.homedir(), '.gemini/config/skills/archify/bin/archify.mjs');

if (!fs.existsSync(archifyBin)) {
  console.error(`Archify CLI not found at ${archifyBin}`);
  process.exit(1);
}

// 1. Resolve current version from pubspec.yaml
let version = '1.12.0';
try {
  const pubspec = fs.readFileSync(path.join(projectRoot, 'flutter_app/pubspec.yaml'), 'utf8');
  const match = pubspec.match(/version:\s*([0-9]+\.[0-9]+\.[0-9]+)/);
  if (match) version = match[1];
} catch {}

const archifyDir = path.join(projectRoot, '.archify/drishti-architecture');
fs.mkdirSync(archifyDir, { recursive: true });

const candidatePath = path.join(archifyDir, 'candidate.json');
const outputPath = path.join(archifyDir, `drishti_architecture_v${version}.html`);

// 2. Generate updated candidate model
const candidate = {
  schema_version: 1,
  diagram_type: "architecture",
  meta: {
    title: `Drishti v${version}: AI-Powered Retinal Screening & Tele-Ophthalmology System`,
    subtitle: "Clinical Workplace Ergonomics, Edge LiteRT, Foundation Models, and Multi-OS Matrix",
    output: `drishti_architecture_v${version}.html`,
    quality_profile: "showcase"
  },
  components: [
    { id: "operator", type: "external", label: "Clinical Operator", sublabel: "Technician / Doctor", pos: [40, 260], size: [130, 64] },
    { id: "login_auth", type: "security", label: "Hospital Auth & RBAC", sublabel: "Least Privilege PII Masking", pos: [220, 110], size: [160, 64], tag: "Offline PIN" },
    { id: "capture_deck", type: "frontend", label: "Capture Viewfinder", sublabel: "Hands-Free Pedal / Darkroom HUD", pos: [220, 260], size: [160, 64], tag: "Ruby & Amber" },
    { id: "triage_deck", type: "frontend", label: "Doctor Batch Triage", sublabel: "1-Key Sprint Review (1-2-3)", pos: [220, 410], size: [160, 64], tag: "Rapid Sprint" },
    { id: "local_store", type: "database", label: "Encrypted Store", sublabel: "LocalStore + SQLCipher", pos: [440, 110], size: [150, 64], tag: "Zero PII Leak" },
    { id: "litert_engine", type: "backend", label: "On-Device AI Engine", sublabel: "Flutter LiteRT / TFLite FFI", pos: [440, 260], size: [150, 64], tag: "Sub-100ms" },
    { id: "thermal_slip", type: "external", label: "Thermal Slip Generator", sublabel: "ESC/POS 58mm/80mm Slip", pos: [440, 410], size: [150, 64], tag: "Paper Handout" },
    { id: "offline_queue", type: "messagebus", label: "Offline Sync Queue", sublabel: "DrsQueue / Auto Retry", pos: [640, 180], size: [150, 64], tag: "Store-and-Forward" },
    { id: "fastapi_server", type: "backend", label: "Central Cloud API", sublabel: "FastAPI :8000 (Python 3.14)", pos: [840, 260], size: [160, 64], tag: "REST API" },
    { id: "dinov3_retfound", type: "backend", label: "Foundation Models", sublabel: "DINOv3 ViT-B/16 + RETFound", pos: [1050, 180], size: [160, 64], tag: "PyTorch ML" },
    { id: "gradcam_engine", type: "backend", label: "Explainability Engine", sublabel: "Grad-CAM Heatmaps & Calibration", pos: [1050, 340], size: [160, 64], tag: "Isotonic Reg" },
    { id: "specialist_smtp", type: "cloud", label: "Tele-Ophthalmology Uplink", sublabel: "SMTP Specialist Routing + PDF", pos: [840, 430], size: [160, 64], tag: "Urgent Referral" },
    { id: "ci_distribution", type: "cloud", label: "Multi-OS Matrix", sublabel: "GitHub Actions CI/CD", pos: [220, 560], size: [160, 64], tag: "5 Native OS" }
  ],
  boundaries: [
    { kind: "region", label: "Edge Clinical Station (Field Screening Booth)", wraps: ["login_auth", "capture_deck", "triage_deck", "local_store", "litert_engine", "thermal_slip", "offline_queue"] },
    { kind: "security-group", label: "Central Medical Cloud / Tele-Screening Platform", wraps: ["fastapi_server", "dinov3_retfound", "gradcam_engine", "specialist_smtp"] },
    { kind: "security-group", label: "CI/CD Release & Packaging Infrastructure", wraps: ["ci_distribution"] }
  ],
  connections: [
    { id: "op-to-capture", from: "operator", to: "capture_deck", label: "Pedal / HUD / Audio", variant: "emphasis" },
    { id: "auth-to-capture", from: "login_auth", to: "capture_deck", label: "Tech Role" },
    { id: "auth-to-triage", from: "login_auth", to: "triage_deck", label: "Clinician PIN" },
    { id: "capture-to-litert", from: "capture_deck", to: "litert_engine", label: "OD / OS Buffers" },
    { id: "capture-to-store", from: "capture_deck", to: "local_store", label: "Persist Record" },
    { id: "triage-to-slip", from: "triage_deck", to: "thermal_slip", label: "ESC/POS Stream" },
    { id: "store-to-queue", from: "local_store", to: "offline_queue", label: "Buffer Sync" },
    { id: "queue-to-api", from: "offline_queue", to: "fastapi_server", label: "HTTPS Uplink", variant: "dashed" },
    { id: "api-to-dinov3", from: "fastapi_server", to: "dinov3_retfound", label: "ViT Embeddings" },
    { id: "dinov3-to-gradcam", from: "dinov3_retfound", to: "gradcam_engine", label: "Feature Maps" },
    { id: "gradcam-to-api", from: "gradcam_engine", to: "fastapi_server", label: "Heatmap & Score" },
    { id: "api-to-smtp", from: "fastapi_server", to: "specialist_smtp", label: "Alert <72h", variant: "security" },
    { id: "ci-to-client", from: "ci_distribution", to: "triage_deck", label: "Native Binaries", variant: "dashed" }
  ],
  cards: [
    {
      dot: "cyan",
      title: "Edge Clinical Station",
      items: [
        "Flutter 3.50 workstation with darkroom Ruby (650nm) & Amber (590nm) night HUD",
        "Hands-free USB foot pedal capture (Space/Numpad 0) & acoustic QC audio chimes",
        "Offline role-based data abstraction (Technician vs Clinician Doctor)",
        "Doctor batch triage deck with 1-Key rapid sprint review (1=Normal, 2=Mild, 3=Refer)",
        "ESC/POS 58mm & 80mm thermal receipt generator for instant camp handouts"
      ]
    },
    {
      dot: "emerald",
      title: "Edge AI & Resilience",
      items: [
        "On-device LiteRT C++ FFI inference engine for offline real-time grading",
        "3-tier encrypted persistence: memory -> LocalStore -> SQLCipher",
        "Store-and-forward offline queue with automated network reconnection sync"
      ]
    },
    {
      dot: "violet",
      title: "Central Diagnostic & Foundation AI",
      items: [
        "FastAPI Python 3.14 REST backend with strict clinical API contracts",
        "Multimodal DINOv3 ViT-B/16 and RETFound ophthalmology foundation models",
        "Grad-CAM lesion attention maps & Isotonic probability calibration",
        "Automated specialist routing via SMTP with de-identified signed medical reports"
      ]
    },
    {
      dot: "rose",
      title: "Cross-Platform Release Matrix",
      items: [
        "GitHub Actions CI/CD matrix building native binaries across 5 operating systems",
        "Android (3 ABIs), Linux x86_64, Windows x86_64, macOS Universal, and iOS unsigned",
        "Automated SHA256 cryptographic verification checksums"
      ]
    }
  ]
};

fs.writeFileSync(candidatePath, JSON.stringify(candidate, null, 2), 'utf8');

// 3. Render standalone interactive HTML
console.log(`[archify] Compiling Drishti architecture diagram -> ${outputPath}`);
const renderResult = spawnSync(process.execPath, [archifyBin, 'render', 'architecture', candidatePath, outputPath], {
  stdio: 'inherit',
});

if (renderResult.status !== 0) {
  console.error('[archify] Rendering failed');
  process.exit(renderResult.status || 1);
}

console.log(`[archify] Architecture diagram successfully rendered: ${outputPath}`);

// 4. Pop up on user screen
const shouldOpen = process.argv.includes('--open') || !process.argv.includes('--no-open');
if (shouldOpen) {
  console.log('[archify] Launching interactive architecture diagram on screen...');
  const opener = process.platform === 'darwin' ? 'open' : (process.platform === 'win32' ? 'start' : 'xdg-open');
  try {
    spawnSync(opener, [outputPath], { stdio: 'ignore', timeout: 5000 });
    console.log(`[archify] Pop-up launched via ${opener}.`);
  } catch (e) {
    console.warn(`[archify] Could not pop up browser automatically: ${e.message}`);
  }
}

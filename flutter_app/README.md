# Netra-AI Mobile / Web (Flutter)

Figma-themed PHC screening app. Home is the Figma PHC dashboard
(`lib/screens/figma_dashboard_screen.dart`, 5 languages via the 🌐 menu);
screening flows call the FastAPI backend through `lib/services/api_service.dart`.

## Backend wiring (web)

The web bundle bakes the backend origin at build time:

```
flutter build web --dart-define=DRISHTI_BASE_URL=https://your-backend-host
```

Default (no define): `http://localhost:8000` — run `uvicorn api.main:app`
locally for judging. CI reads repo variable `DRISHTI_BASE_URL`
(Settings → Secrets and variables → Actions → Variables); unset keeps localhost.

Auth: `X-API-Key` header (`--dart-define=DRISHTI_API_KEY=...`, default
`dev-operator-key`). The doctor review queue needs a **doctor** key
(`dev-doctor-key`); with an operator key the queue shows "doctor key required"
instead of a fake empty list.

## Server CORS for the Pages demo

`api/main.py` only allows `localhost:*` origins by default. For the
`*.github.io` deployment set on the server:

```
CORS_ORIGINS="https://bezaleelpaul.github.io"
ENV=prod
DRISHTI_API_KEYS="<real-key>:operator,..."
```

Never expose dev keys on a non-loopback interface — the server refuses to
start that way by design.

## Demo rehearsal checklist

1. Backend up (`/status` 200) or rehearse the offline queue path.
2. Judge path: Dashboard → Start New Screening → capture → AI → result →
   specialist → referral → report → history → offline queue → help.
3. Airplane-mode run at least once; keep a pre-recorded video fallback.

from __future__ import annotations

import base64
import logging
from datetime import datetime, timezone

from fastapi import APIRouter, Depends

from api.auth import ApiPrincipal, require_auth
from api.database import get_db, save_screening_record
from api.schemas import OfflineSyncBatchRequest, OfflineSyncBatchResponse
from api.services.ai_bridge import AIBridge

router = APIRouter(prefix="/sync", tags=["Offline Synchronization"])

logger = logging.getLogger(__name__)


def _cleanup_orphan_screening_dir(screening_id: str) -> None:
    """Best-effort removal of a result dir whose DB row will never exist.

    Used when this worker's inference output is discarded in favor of a
    concurrent winner's receipt: without cleanup every lost race leaks an
    `SCR-*/` dir (orig + gradcam PNGs) with no referencing row.
    """
    import os as _os
    import shutil as _shutil

    from api.services.ai_bridge import _RESULTS_DIR
    _dir = _os.path.join(_RESULTS_DIR, screening_id)
    try:
        _shutil.rmtree(_dir, ignore_errors=True)
    except OSError:
        logger.debug("Could not remove orphan screening directory: %s", _dir, exc_info=True)


@router.post("", response_model=OfflineSyncBatchResponse)
def synchronize_offline_batch(payload: OfflineSyncBatchRequest, _principal: ApiPrincipal = Depends(require_auth)):
    """
    Synchronizes offline screening records stored locally during rural field camps.
    Processes queued images, persists into SQLite database, and flags doctor reviews.
    Guarantees zero data loss for offline camps.
    """
    bridge = AIBridge.get_instance()
    synced_ids: list[str] = []       # LOCAL ids: the client's dedup key.
    synced_items: list[dict] = []    # local -> server traceability map.
    failed_items = []
    seen_local_ids = set()

    # One connection up front: prefetch the patient set and any existing
    # sync receipts for this batch. This fixes per-item connections and
    # inference-before-membership (which left orphan result dirs behind for
    # unknown patients): unknown patients now fail fast with no inference,
    # and already-synced locals replay from receipts without re-inference.
    with get_db() as conn:
        cursor = conn.cursor()
        patient_ids = {item.patient_id for item in payload.screenings}
        known_patients = set()
        if patient_ids:
            q = ",".join("?" * len(patient_ids))
            cursor.execute(
                f"SELECT patient_id FROM patients WHERE patient_id IN ({q})",
                tuple(patient_ids),
            )
            known_patients = {r["patient_id"] for r in cursor.fetchall()}
        batch_local_ids = [item.local_screening_id for item in payload.screenings]
        receipts = {}
        live_screenings = set()
        if batch_local_ids:
            q = ",".join("?" * len(batch_local_ids))
            cursor.execute(
                f"SELECT local_screening_id, screening_id FROM sync_receipts WHERE local_screening_id IN ({q})",
                tuple(batch_local_ids),
            )
            receipts = {r["local_screening_id"]: r["screening_id"] for r in cursor.fetchall()}
            server_ids = [s for s in receipts.values() if not s.startswith("pending-")]
            if server_ids:
                q = ",".join("?" * len(server_ids))
                cursor.execute(
                    f"SELECT screening_id FROM screenings WHERE screening_id IN ({q})",
                    tuple(server_ids),
                )
                live_screenings = {r["screening_id"] for r in cursor.fetchall()}

    for item in payload.screenings:
        try:
            # Dedup within the batch: the same offline record posted twice
            # must not cost 2x multi-second inference + 2 server rows.
            # Idempotent replay: if the first occurrence already synced (this
            # batch or a retried one), reuse its screening id as success.
            if item.local_screening_id in seen_local_ids:
                _replay = receipts.get(item.local_screening_id)
                if _replay and not _replay.startswith("pending-"):
                    synced_ids.append(item.local_screening_id)
                    synced_items.append({
                        "local_screening_id": item.local_screening_id,
                        "screening_id": _replay,
                    })
                else:
                    failed_items.append({
                        "local_screening_id": item.local_screening_id,
                        "error": "DUPLICATE_IN_BATCH",
                    })
                continue
            seen_local_ids.add(item.local_screening_id)
            # Idempotent replay: a retried batch reuses the original server
            # row instead of re-running inference + minting duplicates.
            # Only replay FINAL receipts whose screening row still exists:
            # crash-leftover "pending-" markers and rows removed by the
            # retention purge fall through to normal processing below.
            _receipt = receipts.get(item.local_screening_id)
            if _receipt and not _receipt.startswith("pending-") and _receipt in live_screenings:
                synced_ids.append(item.local_screening_id)
                synced_items.append({
                    "local_screening_id": item.local_screening_id,
                    "screening_id": _receipt,
                })
                continue
            if item.patient_id not in known_patients:
                failed_items.append({
                    "local_screening_id": item.local_screening_id,
                    "error": f"PATIENT_NOT_REGISTERED:{item.patient_id}",
                })
                continue
            if item.eye_side not in ("Right", "Left"):
                raise ValueError("eye_side must be 'Right' or 'Left'.")
            if len(item.image_base64) > 15_000_000:
                raise ValueError("Image payload too large (max ~10MB decoded).")
            try:
                image_bytes = base64.b64decode(item.image_base64, validate=True)
            except Exception:  # noqa: BLE001 - per-item processing must continue
                raise ValueError("Invalid base64 image payload.")
            if not image_bytes or len(image_bytes) > 10 * 1024 * 1024:
                raise ValueError("Decoded image empty or exceeds 10MB.")

            # Heavy inference runs OUTSIDE the DB transaction (SQLite single-writer).
            analysis = bridge.analyze_retina(
                image_bytes=image_bytes,
                patient_id=item.patient_id,
                eye_side=item.eye_side,
                camera_profile=item.camera_profile or "Generic Fundus Camera",
            )
            # Preserve the field-capture time (server created_at is sync time).
            # Empty-string timestamps normalize to NULL (never store "").
            analysis["captured_at"] = (item.timestamp or "").strip() or None

            # Short-lived connection per save. The patient MUST already be
            # registered (offline clients sync queued patients first): silently
            # inventing "Field Patient, age 50" demographics corrupts the
            # record and loses the real vitals, and diverges from
            # POST /retinal/analyze which 404s unknown patients.
            # The receipt INSERT OR IGNORE serializes concurrent retries of
            # the same local id: the loser reuses the winner's screening_id.
            with get_db() as conn:
                cursor = conn.cursor()
                now = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
                cursor.execute(
                    "INSERT OR IGNORE INTO sync_receipts "
                    "(local_screening_id, screening_id, created_at) "
                    "VALUES (?, ?, ?)",
                    (item.local_screening_id, f"pending-{item.local_screening_id}", now),
                )
                if cursor.rowcount == 0:
                    cursor.execute(
                        "SELECT screening_id FROM sync_receipts WHERE local_screening_id = ?",
                        (item.local_screening_id,),
                    )
                    row = cursor.fetchone()
                    existing = row["screening_id"] if row else None
                    _dead_receipt = False
                    if existing and not existing.startswith("pending-"):
                        # Trust-but-verify: the receipt may outlive its row
                        # (retention purge keeps receipts by design). Re-check
                        # liveness with a fresh read, not the prefetch set.
                        cursor.execute(
                            "SELECT 1 FROM screenings WHERE screening_id = ?",
                            (existing,),
                        )
                        if cursor.fetchone():
                            synced_ids.append(item.local_screening_id)
                            synced_items.append({
                                "local_screening_id": item.local_screening_id,
                                "screening_id": existing,
                            })
                            receipts[item.local_screening_id] = existing
                            conn.commit()
                            continue
                        # Dead receipt: skip the winner-wait below (it would
                        # accept this same dead id) and re-save; finalize
                        # REPLACEs the stale receipt row.
                        _dead_receipt = True
                    if not _dead_receipt:
                        # Another worker holds a pending marker: it is mid-save.
                        # Wait (bounded) for the winner's finalize instead of
                        # minting a duplicate row + orphan result dir. Inference
                        # above is already paid; reuse beats resaving.
                        import time as _time
                        _winner = None
                        for _ in range(32):  # ~8s max; inference takes seconds
                            _time.sleep(0.25)
                            cursor.execute(
                                "SELECT screening_id FROM sync_receipts WHERE local_screening_id = ?",
                                (item.local_screening_id,),
                            )
                            _row = cursor.fetchone()
                            _sid = _row["screening_id"] if _row else None
                            if _sid and not _sid.startswith("pending-"):
                                _winner = _sid
                                break
                        if _winner is not None:
                            _cleanup_orphan_screening_dir(analysis["screening_id"])
                            synced_ids.append(item.local_screening_id)
                            synced_items.append({
                                "local_screening_id": item.local_screening_id,
                                "screening_id": _winner,
                            })
                            receipts[item.local_screening_id] = _winner
                            conn.commit()
                            continue
                # Stale pending marker (crash between reserve and finalize):
                # the INSERT OR REPLACE below atomically overwrites it — no
                # DELETE needed, which avoids a race window where another
                # worker could insert a new pending marker between DELETE
                # and REPLACE.

                # Persist screening record and doctor review into SQLite
                screening_id = save_screening_record(conn, analysis)
                cursor.execute(
                    "INSERT OR REPLACE INTO sync_receipts "
                    "(local_screening_id, screening_id, created_at) "
                    "VALUES (?, ?, ?)",
                    (item.local_screening_id, screening_id, now),
                )
                # get_db() rolls back on error but never commits on success
                # (save_screening_record commits its own writes); commit the
                # receipt row explicitly or retries replay a stale marker.
                conn.commit()
                receipts[item.local_screening_id] = screening_id
                synced_ids.append(item.local_screening_id)
                synced_items.append({
                    "local_screening_id": item.local_screening_id,
                    "screening_id": screening_id,
                })
        except ValueError as e:
            # Our own validation messages are safe to return verbatim.
            failed_items.append({
                "local_screening_id": item.local_screening_id,
                "error": str(e)[:200],
            })
        except Exception as e:  # noqa: BLE001 - return stable per-item failure code
            # Anything else (DB internals, inference stack traces) stays
            # server-side: return a stable error code instead.
            logger.warning("Offline sync item %s failed: %s", item.local_screening_id, e)
            failed_items.append({
                "local_screening_id": item.local_screening_id,
                "error": "INTERNAL_PROCESSING_FAILED",
            })

    return OfflineSyncBatchResponse(
        total_received=len(payload.screenings),
        total_synced=len(synced_ids),
        failed_items=failed_items,
        synced_screening_ids=synced_ids,
        synced_items=synced_items,
    )

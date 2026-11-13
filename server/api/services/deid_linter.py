"""Fail-closed PHI linter for de-identified sync payloads (Ticket C-4).

The /sync/v2 contract carries ONLY pseudonymized data. This linter is the
server-side enforcement arm of that contract: ANY violation rejects the
ENTIRE batch with HTTP 422 and nothing is persisted. Rejected payloads are
never written to disk (a quarantine file would itself be a PHI sink) — only
a content-free audit entry records that a rejection happened.

Defense in depth, three layers:
  1. Pydantic ``extra="forbid"`` on the request schemas (unknown field
     names are rejected before this module runs),
  2. an explicit whitelist re-check here (nested structures / dict escapes),
  3. value-level regex tripwires for Indian mobile numbers, ABHA ids and
     salutation+name patterns hidden INSIDE otherwise-allowed string fields.
"""

from __future__ import annotations

import re

#: The complete set of field names a /sync/v2 item may carry. Anything else
#: is a contract violation (fail closed on unknown fields).
ALLOWED_FIELDS: frozenset[str] = frozenset(
    {
        "pseudo_screening_id",
        "pseudonym",
        "age_band",
        "gender",
        "eye_side",
        "dr_grade",
        "dr_label",
        "probabilities",
        "confidence",
        "requires_human_review",
        "image_base64",
        "consent_version",
        "captured_at",
    }
)

#: Known PHI field names — rejected even if someone later adds them to the
#: whitelist by mistake.
PHI_FIELD_HINTS: frozenset[str] = frozenset(
    {
        "name",
        "patient_name",
        "full_name",
        "phone",
        "phone_number",
        "mobile",
        "abha",
        "abha_id",
        "aadhaar",
        "aadhar",
        "village",
        "address",
        "patient_id",
        "screening_id",
        "local_screening_id",
        "operator_name",
        "screening_centre",
    }
)

#: Indian mobile number: optional +91/91 prefix, 10 digits starting 6-9,
#: with optional space/dash separators.
_MOBILE_RE = re.compile(r"(?:\+?91[\s-]?)?[6-9]\d{4}[\s-]?\d{5}")

#: ABHA (Ayushman Bharat Health Account) number: 14 digits in 4-digit groups.
_ABHA_RE = re.compile(r"\d{2}[- ]\d{4}[- ]\d{4}[- ]\d{4}")

#: Salutation + capitalised name (catches "Dr. Raman", "Mr. Sharma" inside
#: free-text-ish allowed fields).
_SALUTATION_RE = re.compile(r"\b(?:Dr|Mr|Mrs|Ms|Miss)\.?\s+[A-Z][a-z]+")


class PHIRejectionError(Exception):
    """Raised when a payload violates the de-identified contract.

    ``violations`` carries field names / pattern ids only — never the
    offending values (echoing the value would log the PHI we just caught).
    """

    def __init__(self, violations: list[str]) -> None:
        self.violations = violations
        super().__init__("PHI_REJECTED: " + ", ".join(violations))


def lint_deidentified_item(data: dict[str, object]) -> list[str]:
    """Returns a list of violation codes for one payload item (empty = clean).

    Violation codes are field names (unknown/PHI fields) or pattern ids
    (``PATTERN:MOBILE``, ``PATTERN:ABHA``, ``PATTERN:SALUTATION``). Values
    are intentionally NOT included.
    """
    violations: list[str] = []

    for key in data:
        k = key.lower()
        if k in PHI_FIELD_HINTS:
            violations.append(f"PHI_FIELD:{key}")
        elif key not in ALLOWED_FIELDS:
            violations.append(f"UNKNOWN_FIELD:{key}")

    for key, value in data.items():
        if isinstance(value, str):
            if _MOBILE_RE.search(value):
                violations.append("PATTERN:MOBILE")
            if _ABHA_RE.search(value):
                violations.append("PATTERN:ABHA")
            if _SALUTATION_RE.search(value):
                violations.append("PATTERN:SALUTATION")
        elif isinstance(value, dict):
            # Nested structures are not part of the contract: reject with
            # the same fail-closed rule as unknown top-level fields.
            violations.append(f"NESTED_OBJECT:{key}")

    # De-duplicate while preserving order.
    seen: set[str] = set()
    ordered = [v for v in violations if not (v in seen or seen.add(v))]
    return ordered


def assert_clean(data: dict[str, object]) -> None:
    """Raises :class:`PHIRejectionError` when the item is not clean."""
    violations = lint_deidentified_item(data)
    if violations:
        raise PHIRejectionError(violations)

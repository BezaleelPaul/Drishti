"""
Hospital-Grade Clinical Screening PDF Report Generator.
Complies with Indian Tele-Ophthalmology Guidelines and ABDM standards.
"""

import io
import logging
import os
from datetime import datetime, timezone
from typing import Any

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import inch
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
from reportlab.platypus import (
    HRFlowable,
    Paragraph,
    SimpleDocTemplate,
    Spacer,
    Table,
    TableStyle,
)
from reportlab.platypus import (
    Image as RLImage,
)

_HINDI_FONT = "Helvetica-Oblique"
_DEVANAGARI_CANDIDATES = [
    "/System/Library/Fonts/Supplemental/DevanagariMT.ttc",
    "/System/Library/Fonts/Kohinoor.ttc",
    "/System/Library/Fonts/Supplemental/ITFDevanagari.ttc",
    "/System/Library/Fonts/Supplemental/Nirmala.ttf",
    "/usr/share/fonts/truetype/noto/NotoSansDevanagari-Regular.ttf",
    r"C:\Windows\Fonts\nirmala.ttf",
]
for _font_path in _DEVANAGARI_CANDIDATES:
    if os.path.exists(_font_path):
        try:
            pdfmetrics.registerFont(TTFont("DevanagariFont", _font_path))
            _HINDI_FONT = "DevanagariFont"
            break
        except Exception:
            logging.getLogger(__name__).debug(
                "Could not register Hindi font: %s", _font_path, exc_info=True
            )
            continue


def generate_clinical_screening_pdf(
    patient_data: dict[str, Any],
    screening_record: Any,
    biomarkers: dict[str, Any],
    fundus_image_path: str | None = None,
    annotated_image_path: str | None = None,
    doctor_notes: str = "Screened via Drishti Tele-Ophthalmology Triage.",
    doctor_signature_name: str = "Dr. S. Ramanathan, MD (Ophthal)",
    doctor_action: str = "Routine Annual Follow-up",
    criteria_evaluation: list[dict[str, Any]] | None = None,
    grading_policy: dict[str, Any] | None = None,
    disagreement: dict[str, Any] | None = None,
) -> bytes:
    """
    Generates an official, hospital-grade 1-page PDF screening dossier.
    Returns PDF bytes suitable for direct download or storage.
    """
    biomarkers = biomarkers or {}
    patient_data = patient_data or {}
    buffer = io.BytesIO()
    doc = SimpleDocTemplate(
        buffer,
        pagesize=letter,
        rightMargin=36,
        leftMargin=36,
        topMargin=36,
        bottomMargin=36,
    )

    styles = getSampleStyleSheet()

    # Custom styles
    title_style = ParagraphStyle(
        "DocTitle",
        parent=styles["Normal"],
        fontName="Helvetica-Bold",
        fontSize=16,
        leading=20,
        textColor=colors.HexColor("#1A365D"),
        alignment=TA_CENTER,
    )
    subtitle_style = ParagraphStyle(
        "DocSubtitle",
        parent=styles["Normal"],
        fontName="Helvetica",
        fontSize=9,
        leading=12,
        textColor=colors.HexColor("#4A5568"),
        alignment=TA_CENTER,
    )
    section_heading = ParagraphStyle(
        "SectionHeading",
        parent=styles["Normal"],
        fontName="Helvetica-Bold",
        fontSize=11,
        leading=14,
        textColor=colors.HexColor("#2B6CB0"),
        spaceAfter=4,
    )
    body_style = ParagraphStyle(
        "Body",
        parent=styles["Normal"],
        fontName="Helvetica",
        fontSize=8.5,
        leading=11,
        textColor=colors.HexColor("#2D3748"),
    )
    bold_body = ParagraphStyle(
        "BoldBody",
        parent=body_style,
        fontName="Helvetica-Bold",
    )
    hindi_note = ParagraphStyle(
        "HindiNote",
        parent=body_style,
        fontName=_HINDI_FONT,
        fontSize=8,
        leading=10,
        textColor=colors.HexColor("#742A2A"),
    )

    story = []

    # 1. Header Block
    story.append(Paragraph("DISTRICT TELE-OPHTHALMOLOGY SCREENING NETWORK", title_style))
    story.append(
        Paragraph(
            "AI-Assisted Diabetic Retinopathy Triage Dossier • ABDM / Ayushman Bharat Aligned",
            subtitle_style,
        )
    )
    story.append(Spacer(1, 8))
    story.append(
        HRFlowable(width="100%", thickness=1.5, color=colors.HexColor("#2B6CB0"), spaceAfter=8)
    )

    # 2. Patient Demographics & Upstream Risk Table
    patient_id = patient_data.get("patient_id", "N/A")
    age = patient_data.get("age", "N/A")
    gender = patient_data.get("gender", "N/A")
    _bmi_raw = patient_data.get("bmi", 0.0)
    try:
        bmi = float(_bmi_raw)
    except (TypeError, ValueError):
        bmi = float("nan")
    import math as _math

    bmi_str = (
        f"{bmi:.1f} kg/m\u00b2 ({'Elevated >=23' if bmi >= 23 else 'Normal'})"
        if _math.isfinite(bmi)
        else "N/A"
    )
    dm_status = patient_data.get("diabetes_status", "CONFIRMED_DIABETES")
    _risk_raw = patient_data.get("risk_score", 0.0)
    try:
        risk_score = float(_risk_raw)
    except (TypeError, ValueError):
        risk_score = float("nan")
    risk_str = f"{risk_score:.0f}/100" if _math.isfinite(risk_score) else "N/A"
    report_date = datetime.now(timezone.utc).strftime("%d-%b-%Y %H:%M UTC")

    demo_data = [
        [
            Paragraph("<b>Patient ID / ABHA:</b>", body_style),
            Paragraph(str(patient_id), bold_body),
            Paragraph("<b>Screening Date:</b>", body_style),
            Paragraph(report_date, body_style),
        ],
        [
            Paragraph("<b>Age / Gender:</b>", body_style),
            Paragraph(f"{age} Yrs / {gender}", body_style),
            Paragraph("<b>BMI (Asian Cutoff):</b>", body_style),
            Paragraph(bmi_str, body_style),
        ],
        [
            Paragraph("<b>Diabetes Status:</b>", body_style),
            Paragraph(str(dm_status), bold_body),
            Paragraph("<b>Stage 1 Risk Score:</b>", body_style),
            Paragraph(risk_str, bold_body),
        ],
    ]
    t_demo = Table(demo_data, colWidths=[110, 155, 110, 165])
    t_demo.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#F7FAFC")),
                ("BOX", (0, 0), (-1, -1), 0.5, colors.HexColor("#CBD5E0")),
                ("INNERGRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#E2E8F0")),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]
        )
    )
    story.append(t_demo)
    story.append(Spacer(1, 10))

    # 3. Model Findings & Quantitative Biomarkers
    story.append(
        Paragraph("CLINICAL AI SCREENING FINDINGS (DRISHTI PIPELINE)", section_heading)
    )

    q_grade = getattr(screening_record, "quality_grade", None)
    q_str = q_grade.value if q_grade else "N/A"

    dr_pred = getattr(screening_record, "dr_prediction", None)
    if dr_pred:
        dr_grade_num = dr_pred.predicted_grade.value
        dr_label = dr_pred.predicted_grade.label
        conf = dr_pred.confidence * 100
        referable = "REFERABLE DR (Urgent Care)" if dr_grade_num >= 2 else "NON-REFERABLE (Monitor)"
        dr_str = f"Grade {dr_grade_num} — {dr_label} ({referable})"
        conf_str = f"{conf:.1f}%"
    else:
        dr_str = "NOT GENERATED (Quality Gate Inhibited)"
        conf_str = "N/A"

    csme_risk = biomarkers.get("csme_risk", "LOW")
    fovea_dist = biomarkers.get("min_fovea_distance_px")
    # Never fabricate negative findings for an ungradable capture: when the
    # pipeline refused to segment (or refused to grade at all), every
    # biomarker cell must read NOT ASSESSED. The "UNGRADABLE" sentinel is one
    # signal; a missing (None) csme_risk or a missing DR prediction is another
    # (e.g. API bridge forwards None, not the sentinel).
    bio_unassessed = (csme_risk in (None, "UNGRADABLE")) or (dr_pred is None)
    if bio_unassessed:
        ma_str = "NOT ASSESSED (ungradable capture)"
        vessel_str = "NOT ASSESSED (ungradable capture)"
        csme_str = "NOT ASSESSED (ungradable capture)"
        fovea_dist_str = "NOT ASSESSED (ungradable capture)"
    else:
        try:
            ma_count = int(biomarkers.get("microaneurysm_count", 0) or 0)
        except (TypeError, ValueError):
            ma_count = 0
        try:
            vessel_density = float(biomarkers.get("vessel_density_pct", 0.0) or 0.0)
        except (TypeError, ValueError):
            vessel_density = 0.0
        ma_str = f"{ma_count} Microaneurysms detected"
        vessel_str = f"{vessel_density:.1f}% retinal area"
        csme_str = f"{csme_risk}"
        fovea_dist_str = "N/A (no lesions)" if fovea_dist is None else f"{fovea_dist}px"

    findings_data = [
        [
            Paragraph("<b>Image Quality:</b>", body_style),
            Paragraph(f"<b>{q_str}</b>", bold_body),
            Paragraph("<b>DR Severity:</b>", body_style),
            Paragraph(f"<b>{dr_str}</b>", bold_body),
        ],
        [
            Paragraph("<b>Model Confidence:</b>", body_style),
            Paragraph(conf_str, body_style),
            Paragraph("<b>CSME / Macular Risk:</b>", body_style),
            Paragraph(f"<b>{csme_str}</b> (Fovea Prox: {fovea_dist_str})", bold_body),
        ],
        [
            Paragraph("<b>Candidate Lesions:</b>", body_style),
            Paragraph(ma_str, body_style),
            Paragraph("<b>Vessel Density:</b>", body_style),
            Paragraph(vessel_str, body_style),
        ],
    ]
    t_findings = Table(findings_data, colWidths=[110, 155, 110, 165])
    t_findings.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#EDF2F7")),
                ("BOX", (0, 0), (-1, -1), 0.5, colors.HexColor("#CBD5E0")),
                ("INNERGRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#E2E8F0")),
                ("TOPPADDING", (0, 0), (-1, -1), 3),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
            ]
        )
    )
    story.append(t_findings)
    story.append(Spacer(1, 10))

    # 3b. Evidence-Linked Criteria Evaluation (schema_version 1.0 payloads)
    if criteria_evaluation:
        crit_rows = [
            [
                Paragraph("<b>Criterion (ICDRS subset)</b>", bold_body),
                Paragraph("<b>Status</b>", bold_body),
                Paragraph("<b>Supporting lesion candidates</b>", bold_body),
            ]
        ]
        for c in criteria_evaluation:
            cid = str(c.get("criterion_id", ""))
            status = str(c.get("status", ""))
            supporting = c.get("supporting_evidence_ids") or []
            crit_rows.append(
                [
                    Paragraph(cid, body_style),
                    Paragraph(status, body_style),
                    Paragraph(
                        ", ".join(str(e) for e in supporting) if supporting else "—",
                        body_style,
                    ),
                ]
            )
        t_crit = Table(crit_rows, colWidths=[190, 120, 230])
        t_crit.setStyle(
            TableStyle(
                [
                    ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#F7FAFC")),
                    ("BOX", (0, 0), (-1, -1), 0.5, colors.HexColor("#CBD5E0")),
                    ("INNERGRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#E2E8F0")),
                    ("TOPPADDING", (0, 0), (-1, -1), 3),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 3),
                ]
            )
        )
        story.append(Paragraph("Grading Criteria Evidence", section_heading))
        story.append(t_crit)
        policy = grading_policy or {}
        if policy:
            story.append(
                Paragraph(
                    f"Criteria policy: {policy.get('policy_id', 'n/a')} v{policy.get('policy_version', 'n/a')} "
                    f"({policy.get('framework', '')}). Upper ICDRS levels (3–4) cannot be excluded: "
                    "venous beading and neovascularisation have no detector in this system; "
                    "candidate detections are not confirmed lesions.",
                    body_style,
                )
            )
        if disagreement:
            story.append(
                Paragraph(
                    f"CNN-vs-evidence reconciliation: {disagreement.get('summary', disagreement.get('status', 'n/a'))}",
                    hindi_note,
                )
            )
        story.append(Spacer(1, 10))

    # 4. Images Row (Original vs Annotated/Grad-CAM)
    img_cells = []
    if fundus_image_path and os.path.exists(fundus_image_path):
        img_cells.append(
            [
                RLImage(fundus_image_path, width=2.6 * inch, height=2.0 * inch),
                Paragraph(
                    "<b>Original Retinal Capture</b><br/>Pre-screened by Model 1 Quality Gate",
                    subtitle_style,
                ),
            ]
        )
    if annotated_image_path and os.path.exists(annotated_image_path):
        img_cells.append(
            [
                RLImage(annotated_image_path, width=2.6 * inch, height=2.0 * inch),
                Paragraph(
                    "<b>Anatomical Landmarks & Lesions</b><br/>OD (Yellow), Fovea (Blue), MAs (Red)",
                    subtitle_style,
                ),
            ]
        )

    if len(img_cells) == 2:
        img_table_data = [
            [img_cells[0][0], img_cells[1][0]],
            [img_cells[0][1], img_cells[1][1]],
        ]
        t_imgs = Table(img_table_data, colWidths=[270, 270])
        t_imgs.setStyle(
            TableStyle(
                [
                    ("ALIGN", (0, 0), (-1, -1), "CENTER"),
                    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                    ("TOPPADDING", (0, 0), (-1, -1), 2),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
                ]
            )
        )
        story.append(t_imgs)
        story.append(Spacer(1, 10))
    elif len(img_cells) == 1:
        img_table_data = [
            [img_cells[0][0]],
            [img_cells[0][1]],
        ]
        t_imgs = Table(img_table_data, colWidths=[540])
        t_imgs.setStyle(
            TableStyle(
                [
                    ("ALIGN", (0, 0), (-1, -1), "CENTER"),
                    ("VALIGN", (0, 0), (-1, -1), "MIDDLE"),
                    ("TOPPADDING", (0, 0), (-1, -1), 2),
                    ("BOTTOMPADDING", (0, 0), (-1, -1), 2),
                ]
            )
        )
        story.append(t_imgs)
        story.append(Spacer(1, 10))

    # 5. Doctor Review & Clinical Orders Section
    story.append(Paragraph("OPHTHALMIC TELE-CONSULTATION & SIGN-OFF", section_heading))
    doctor_table_data = [
        [
            Paragraph("<b>Physician Action:</b>", body_style),
            Paragraph(f"<b>{doctor_action}</b>", bold_body),
        ],
        [
            Paragraph("<b>Clinical Notes:</b>", body_style),
            Paragraph(doctor_notes, body_style),
        ],
        [
            Paragraph("<b>Signed By:</b>", body_style),
            Paragraph(f"<b>{doctor_signature_name}</b> (Verified Tele-Ophthalmologist)", bold_body),
        ],
    ]
    t_doc = Table(doctor_table_data, colWidths=[120, 420])
    t_doc.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#FEFCBF")),
                ("BOX", (0, 0), (-1, -1), 0.5, colors.HexColor("#D69E2E")),
                ("INNERGRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#ECC94B")),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]
        )
    )
    story.append(t_doc)
    story.append(Spacer(1, 10))

    # 6. Bilingual Patient Guidance Note (English & Hindi)
    story.append(Paragraph("PATIENT GUIDANCE / रोगी परामर्श", section_heading))
    if dr_pred and dr_pred.predicted_grade.value >= 2:
        eng_advice = "URGENT: Signs of diabetic eye changes detected. Please visit the District Hospital Eye Department within 2 weeks for dilated slit-lamp examination and treatment."
        hin_advice = "महत्वपूर्ण सूचना: आँखों के पर्दे पर मधुमेह का प्रभाव देखा गया है। कृपया 2 सप्ताह के भीतर जिला अस्पताल के नेत्र रोग विशेषज्ञ से विस्तृत जाँच कराएं।"
    elif dr_pred and dr_pred.predicted_grade.value == 1:
        eng_advice = "MILD: Early diabetic retinal changes noted. Strict glycemic and blood pressure control advised. Repeat retinal screening in 6 months."
        hin_advice = "प्रारंभिक लक्षण: रक्त शर्करा (शुगर) और बीपी को नियंत्रित रखें। 6 महीने बाद दोबारा आँखों की जांच करवाएं।"
    elif dr_pred and dr_pred.predicted_grade.value == 0:
        eng_advice = "NORMAL: No diabetic retinopathy lesions detected today. Maintain healthy diet and routine screening in 12 months."
        hin_advice = "सामान्य: वर्तमान में आँखों में कोई गंभीर खराबी नहीं है। 1 वर्ष बाद नियमित पुनः जाँच कराएं।"
    else:
        eng_advice = "RECAPTURE REQUIRED: Image clarity was insufficient for reliable diagnosis. Please attend the next camp or visit the PHC for a dilated scan."
        hin_advice = (
            "पुनः जाँच आवश्यक: फोटो स्पष्ट न होने के कारण सटीक जांच संभव नहीं हुई। कृपया पुनः फोटो खिंचवाएं।"
        )

    guidance_table = [
        [Paragraph(f"<b>English:</b> {eng_advice}", body_style)],
        [Paragraph(f"<b>हिंदी:</b> {hin_advice}", hindi_note)],
    ]
    t_guide = Table(guidance_table, colWidths=[540])
    t_guide.setStyle(
        TableStyle(
            [
                ("BACKGROUND", (0, 0), (-1, -1), colors.HexColor("#EDFDFD")),
                ("BOX", (0, 0), (-1, -1), 0.5, colors.HexColor("#81E6D9")),
                ("INNERGRID", (0, 0), (-1, -1), 0.5, colors.HexColor("#B2F5EA")),
                ("TOPPADDING", (0, 0), (-1, -1), 4),
                ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
            ]
        )
    )
    story.append(t_guide)
    story.append(Spacer(1, 8))

    # Footer Disclaimer
    disclaimer = (
        "CONFIDENTIAL MEDICAL REPORT — Generated by Drishti Tele-Screening Pipeline. "
        "This AI system is a decision-support triage aid and does not replace a clinical examination by an ophthalmologist."
    )
    story.append(
        Paragraph(
            disclaimer,
            ParagraphStyle(
                "Disc",
                parent=styles["Normal"],
                fontSize=6.5,
                leading=8,
                textColor=colors.gray,
                alignment=TA_CENTER,
            ),
        )
    )

    doc.build(story)
    pdf_bytes = buffer.getvalue()
    buffer.close()
    return pdf_bytes

"""
Routing Pipeline and Decision Flow Module.
"""
from src.pipeline.confidence import ConfidenceConfig, ConfidenceEvaluator
from src.pipeline.schema import (
    ConfidenceAssessment,
    DRClassificationResult,
    DRGrade,
    GradCAMResult,
    HumanReviewType,
    QualityAssessmentResult,
    QualityGrade,
    QualityMetrics,
    ReassessmentOutcome,
    ScreeningRecord,
)

__all__ = [
    "ConfidenceAssessment",
    "ConfidenceConfig",
    "ConfidenceEvaluator",
    "DRClassificationResult",
    "DRGrade",
    "EyeCapture",
    "EyeLaterality",
    "GradCAMResult",
    "HumanReviewType",
    "PatientScreeningSession",
    "PatientSessionResult",
    "QualityAssessmentResult",
    "QualityGrade",
    "QualityMetrics",
    "ReassessmentOutcome",
    "RetinalField",
    "ScreeningPipelineRouter",
    "ScreeningRecord",
]


def __getattr__(name):
    if name == "ScreeningPipelineRouter":
        from src.pipeline.router import ScreeningPipelineRouter
        return ScreeningPipelineRouter
    if name in (
        "PatientScreeningSession",
        "PatientSessionResult",
        "EyeCapture",
        "EyeLaterality",
        "RetinalField",
    ):
        import src.pipeline.patient_session as ps
        return getattr(ps, name)
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")

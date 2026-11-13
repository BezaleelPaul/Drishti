from __future__ import annotations

from fastapi import APIRouter, Depends

from api.auth import ApiPrincipal, require_auth
from api.schemas import DiabetesRiskRequest, DiabetesRiskResponse
from api.services.ai_bridge import AIBridge

router = APIRouter(prefix="/diabetes-risk", tags=["Diabetes Risk Screening"])


@router.post("", response_model=DiabetesRiskResponse)
def evaluate_diabetes_risk(payload: DiabetesRiskRequest, _principal: ApiPrincipal = Depends(require_auth)):
    """
    Upstream Clinical Risk Assessment (Layer 1 & 2).
    Distinguishes risk prediction from definitive medical diagnosis.
    Recommends laboratory testing and retinal screening when elevated risk is identified.
    """
    bridge = AIBridge.get_instance()
    result = bridge.evaluate_diabetes_risk(payload.model_dump())
    return DiabetesRiskResponse(**result)
